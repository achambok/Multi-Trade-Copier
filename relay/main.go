package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"

	"trs/relay/adapters"
	"trs/relay/engine"
)

type SlaveConfig struct {
	ID           string  `json:"id"`
	Type         string  `json:"type"`
	BaseURL      string  `json:"base_url"`
	AccountID    string  `json:"account_id"`
	Email        string  `json:"email"`
	Password     string  `json:"password"`
	ServerID     string  `json:"server_id"`
	APIKey       string  `json:"api_key"`
	STOMPAddr    string  `json:"stomp_addr"`
	Username     string  `json:"username"`
	DeviceID     string  `json:"device_id"`
	AppID        string  `json:"app_id"`
	AppVersion   string  `json:"app_version"`
	SymbolSuffix string  `json:"symbol_suffix"`
	Equity       float64 `json:"equity"`
	// Risk engine fields
	// risk_mode: "proportional" | "percent" | "fixed_lot" | "fixed_dollars"
	// risk_value: percentage for percent mode, lots for fixed_lot, USD for fixed_dollars
	// contract_size: units per lot (100000 for forex, 100 for XAUUSD, 1000 for US30)
	RiskMode        string            `json:"risk_mode"`
	RiskValue       float64           `json:"risk_value"`
	ContractSize    float64           `json:"contract_size"`
	// SymbolOverrides maps base symbol names to broker-specific names for this slave only.
	// Example: {"XAUUSD": "GOLD"} for brokers that list gold as GOLD not XAUUSD.
	SymbolOverrides map[string]string `json:"symbol_overrides"`
}

type RelayConfig struct {
	MQTTBroker         string        `json:"mqtt_broker"`
	MasterTopic        string        `json:"master_topic"`
	MasterEquity       float64       `json:"master_equity"`
	SymbolMapPath      string        `json:"symbol_map_path"`
	// MasterSymbolSuffix is the suffix your master broker appends to symbols
	// (e.g. "m" if master trades "EURUSDm"). The relay strips it before mapping
	// so downstream slaves receive the clean base symbol + their own suffix.
	MasterSymbolSuffix string        `json:"master_symbol_suffix"`
	Slaves             []SlaveConfig `json:"slaves"`
}

type Relay struct {
	cfg        RelayConfig
	cfgMu      sync.RWMutex // protects cfg.MasterEquity + slaveCfgs risk fields
	symbolMap  map[string]map[string]string
	slaves     []adapters.SlaveAdapter
	slaveCfgs  []SlaveConfig
	mqttClient mqtt.Client
}

func loadConfig(path string) (RelayConfig, error) {
	var cfg RelayConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	return cfg, json.Unmarshal(data, &cfg)
}

func loadSymbolMap(path string) (map[string]map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m map[string]map[string]string
	return m, json.Unmarshal(data, &m)
}

// normalizeSymbol strips the master broker's suffix (e.g. "m") from a symbol
// to produce the clean base symbol used for downstream mapping.
func normalizeSymbol(sym, masterSuffix string) string {
	if masterSuffix != "" && strings.HasSuffix(sym, masterSuffix) {
		return sym[:len(sym)-len(masterSuffix)]
	}
	return sym
}

// mapSymbol looks up the base symbol in the symbol map for the given adapter.
// Falls back to the base symbol itself when no explicit mapping exists.
func mapSymbol(symbolMap map[string]map[string]string, baseSymbol, adapterType string) string {
	if entry, ok := symbolMap[baseSymbol]; ok {
		if mapped, ok := entry[adapterType]; ok {
			return mapped
		}
	}
	return baseSymbol
}

func buildSlaves(cfgs []SlaveConfig, mqttBroker string) []adapters.SlaveAdapter {
	var slaves []adapters.SlaveAdapter
	for _, sc := range cfgs {
		switch sc.Type {
		case "tradelocker":
			slaves = append(slaves, adapters.NewTradeLockerAdapter(
				sc.BaseURL, sc.AccountID, sc.Email, sc.Password, sc.ServerID,
			))
		case "matchtrade":
			slaves = append(slaves, adapters.NewMatchTraderAdapter(
				sc.BaseURL, sc.AccountID, sc.APIKey, sc.STOMPAddr,
			))
		case "tradovate":
			slaves = append(slaves, adapters.NewTradovateAdapter(
				sc.BaseURL, sc.AccountID, sc.APIKey,
				sc.Username, sc.Password, sc.DeviceID, sc.AppID, sc.AppVersion,
			))
		case "vm_slave":
			slaves = append(slaves, adapters.NewVMSlaveAdapter(
				sc.AccountID, mqttBroker, sc.Equity, sc.SymbolSuffix, sc.SymbolOverrides,
			))
		default:
			log.Printf("unknown slave type: %s (id=%s) — skipped", sc.Type, sc.ID)
		}
	}
	return slaves
}

func (r *Relay) handleMessage(_ mqtt.Client, msg mqtt.Message) {
	recvAt := time.Now()

	payload, err := engine.DeserializePayload(msg.Payload())
	if err != nil {
		log.Printf("deserialize error: %v", err)
		return
	}

	r.cfgMu.RLock()
	masterEquity := r.cfg.MasterEquity
	slaveCfgs := append([]SlaveConfig(nil), r.slaveCfgs...) // snapshot
	r.cfgMu.RUnlock()

	masterSymbol := payload.SymbolString()
	baseSymbol := normalizeSymbol(masterSymbol, r.cfg.MasterSymbolSuffix)
	log.Printf("[master] ticket=%d sym=%s (base=%s) type=%s vol=%.2f price=%.5f",
		payload.Ticket, masterSymbol, baseSymbol,
		engine.OrderTypeName(payload.OrderType), payload.Volume, payload.Price)

	var wg sync.WaitGroup
	for i, slave := range r.slaves {
		wg.Add(1)
		go func(s adapters.SlaveAdapter, sc SlaveConfig) {
			defer wg.Done()
			start := time.Now()

			equity, err := s.GetEquity()
			if err != nil {
				log.Printf("[%s] GetEquity error: %v", s.Name(), err)
				equity = masterEquity
			}

			contractSize := sc.ContractSize
			if contractSize <= 0 {
				contractSize = 100000 // default: standard forex lot
			}
			scaledLot := engine.ComputeLot(payload.Volume, masterEquity, equity,
				payload.Price, payload.SL, sc.RiskMode, sc.RiskValue, contractSize)

			adapterType := slaveAdapterType(s)
			mappedSymbol := mapSymbol(r.symbolMap, baseSymbol, adapterType)

			if err := s.PlaceOrder(payload, scaledLot, mappedSymbol); err != nil {
				log.Printf("[%s] PlaceOrder error: %v", s.Name(), err)
				return
			}

			elapsed := time.Since(start)
			totalElapsed := time.Since(recvAt)
			log.Printf("[%s] OK ticket=%d sym=%s lot=%.2f mode=%s elapsed=%s total=%s",
				s.Name(), payload.Ticket, mappedSymbol, scaledLot, sc.RiskMode, elapsed, totalElapsed)
		}(slave, slaveCfgs[i])
	}
	wg.Wait()
}

// handleConfig receives a JSON message from trading/config (published by MasterEA)
// and hot-reloads master equity + default risk mode/value for all slaves.
//
// JSON format (published by MasterEA):
//
//	{"master_equity":10000,"risk_mode":"proportional","risk_value":0}
func (r *Relay) handleConfig(_ mqtt.Client, msg mqtt.Message) {
	var update struct {
		MasterEquity float64 `json:"master_equity"`
		RiskMode     string  `json:"risk_mode"`
		RiskValue    float64 `json:"risk_value"`
	}
	if err := json.Unmarshal(msg.Payload(), &update); err != nil {
		log.Printf("[config] parse error: %v — payload: %s", err, msg.Payload())
		return
	}

	r.cfgMu.Lock()
	defer r.cfgMu.Unlock()

	if update.MasterEquity > 0 {
		r.cfg.MasterEquity = update.MasterEquity
	}
	if update.RiskMode != "" {
		for i := range r.slaveCfgs {
			r.slaveCfgs[i].RiskMode  = update.RiskMode
			r.slaveCfgs[i].RiskValue = update.RiskValue
		}
	}
	log.Printf("[config] applied — master_equity=%.2f risk_mode=%s risk_value=%.4f",
		r.cfg.MasterEquity, update.RiskMode, update.RiskValue)
}

func slaveAdapterType(s adapters.SlaveAdapter) string {
	switch s.(type) {
	case *adapters.TradeLockerAdapter:
		return "tradelocker"
	case *adapters.MatchTraderAdapter:
		return "matchtrade"
	case *adapters.TradovateAdapter:
		return "tradovate"
	case *adapters.VMSlaveAdapter:
		return "vm_slave"
	}
	return "unknown"
}

func main() {
	cfgPath := "config/relay_config.json"
	if len(os.Args) > 1 {
		cfgPath = os.Args[1]
	}

	cfg, err := loadConfig(cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	symMap, err := loadSymbolMap(cfg.SymbolMapPath)
	if err != nil {
		log.Fatalf("load symbol map: %v", err)
	}

	slaves := buildSlaves(cfg.Slaves, cfg.MQTTBroker)
	if len(slaves) == 0 {
		log.Fatal("no valid slave adapters configured")
	}
	log.Printf("loaded %d slave adapters", len(slaves))

	r := &Relay{
		cfg:       cfg,
		symbolMap: symMap,
		slaves:    slaves,
		slaveCfgs: cfg.Slaves,
	}

	opts := mqtt.NewClientOptions().
		AddBroker(cfg.MQTTBroker).
		SetClientID("trs_relay").
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetryInterval(2 * time.Second).
		SetOnConnectHandler(func(c mqtt.Client) {
			log.Printf("relay connected to MQTT broker %s", cfg.MQTTBroker)
			if token := c.Subscribe(cfg.MasterTopic, 1, r.handleMessage); token.Wait() && token.Error() != nil {
				log.Fatalf("subscribe error: %v", token.Error())
			}
			log.Printf("subscribed to %s", cfg.MasterTopic)
			if token := c.Subscribe("trading/config", 1, r.handleConfig); token.Wait() && token.Error() != nil {
				log.Printf("warning: could not subscribe to trading/config: %v", token.Error())
			} else {
				log.Printf("subscribed to trading/config (hot-reload)")
			}
		}).
		SetConnectionLostHandler(func(_ mqtt.Client, err error) {
			log.Printf("relay MQTT connection lost: %v", err)
		})

	client := mqtt.NewClient(opts)
	if token := client.Connect(); token.Wait() && token.Error() != nil {
		log.Fatalf("relay connect: %v", token.Error())
	}
	r.mqttClient = client

	fmt.Printf("TRS Relay running. Master equity=%.2f. Waiting for trades on %s\n",
		cfg.MasterEquity, cfg.MasterTopic)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	log.Println("shutting down relay...")
	client.Disconnect(500)
}
