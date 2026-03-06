package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
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
	// risk_value: lot size, percentage, or dollar amount depending on mode
	RiskMode  string  `json:"risk_mode"`
	RiskValue float64 `json:"risk_value"`
}

type RelayConfig struct {
	MQTTBroker    string        `json:"mqtt_broker"`
	MasterTopic   string        `json:"master_topic"`
	MasterEquity  float64       `json:"master_equity"`
	SymbolMapPath string        `json:"symbol_map_path"`
	Slaves        []SlaveConfig `json:"slaves"`
}

type Relay struct {
	cfg        RelayConfig
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

func mapSymbol(symbolMap map[string]map[string]string, masterSymbol, adapterType string) string {
	if entry, ok := symbolMap[masterSymbol]; ok {
		if mapped, ok := entry[adapterType]; ok {
			return mapped
		}
	}
	return masterSymbol
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
				sc.AccountID, mqttBroker, sc.Equity, sc.SymbolSuffix,
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

	masterSymbol := payload.SymbolString()
	log.Printf("[master] ticket=%d sym=%s type=%s vol=%.2f price=%.5f",
		payload.Ticket, masterSymbol,
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
				equity = r.cfg.MasterEquity
			}

			scaledLot := engine.ComputeLot(payload.Volume, r.cfg.MasterEquity, equity, sc.RiskMode, sc.RiskValue)

			adapterType := slaveAdapterType(s)
			mappedSymbol := mapSymbol(r.symbolMap, masterSymbol, adapterType)

			if err := s.PlaceOrder(payload, scaledLot, mappedSymbol); err != nil {
				log.Printf("[%s] PlaceOrder error: %v", s.Name(), err)
				return
			}

			elapsed := time.Since(start)
			totalElapsed := time.Since(recvAt)
			log.Printf("[%s] OK ticket=%d sym=%s lot=%.2f mode=%s elapsed=%s total=%s",
				s.Name(), payload.Ticket, mappedSymbol, scaledLot, sc.RiskMode, elapsed, totalElapsed)
		}(slave, r.slaveCfgs[i])
	}
	wg.Wait()
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
