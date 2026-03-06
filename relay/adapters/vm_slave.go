package adapters

import (
	"encoding/binary"
	"bytes"
	"fmt"
	"log"
	"sync"
	"time"
	"trs/relay/engine"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

type VMSlaveAdapter struct {
	AccountID    string
	BrokerURL    string
	EquityValue  float64
	SymbolSuffix string // e.g. "m" for brokers that append a suffix to all symbols

	mu     sync.RWMutex
	client mqtt.Client
}

func NewVMSlaveAdapter(accountID, brokerURL string, equity float64, symbolSuffix string) *VMSlaveAdapter {
	a := &VMSlaveAdapter{
		AccountID:    accountID,
		BrokerURL:    brokerURL,
		EquityValue:  equity,
		SymbolSuffix: symbolSuffix,
	}
	go a.connect()
	return a
}

func (a *VMSlaveAdapter) connect() {
	opts := mqtt.NewClientOptions().
		AddBroker(a.BrokerURL).
		SetClientID("relay_vm_pub_" + a.AccountID).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(2 * time.Second)

	client := mqtt.NewClient(opts)
	for {
		if token := client.Connect(); token.Wait() && token.Error() != nil {
			log.Printf("vm_slave[%s] connect error: %v — retrying", a.AccountID, token.Error())
			time.Sleep(2 * time.Second)
			continue
		}
		break
	}
	a.mu.Lock()
	a.client = client
	a.mu.Unlock()
}

func (a *VMSlaveAdapter) Name() string {
	return fmt.Sprintf("vm_slave:%s", a.AccountID)
}

func (a *VMSlaveAdapter) GetEquity() (float64, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.EquityValue, nil
}

func (a *VMSlaveAdapter) SetEquity(v float64) {
	a.mu.Lock()
	a.EquityValue = v
	a.mu.Unlock()
}

type VMTradePayload struct {
	Ticket    int64
	Symbol    [12]byte
	OrderType int32
	Volume    float64
	Price     float64
	SL        float64
	TP        float64
	Magic     int32
	Pad       int32
}

func (a *VMSlaveAdapter) PlaceOrder(p *engine.TradePayload, scaledLot float64, mappedSymbol string) error {
	a.mu.RLock()
	client := a.client
	a.mu.RUnlock()

	if client == nil || !client.IsConnected() {
		return fmt.Errorf("vm_slave[%s]: MQTT client not connected", a.AccountID)
	}

	var sym [12]byte
	finalSymbol := mappedSymbol + a.SymbolSuffix
	copy(sym[:], []byte(finalSymbol))

	vp := VMTradePayload{
		Ticket:    p.Ticket,
		Symbol:    sym,
		OrderType: p.OrderType,
		Volume:    scaledLot,
		Price:     p.Price,
		SL:        p.SL,
		TP:        p.TP,
		Magic:     p.Magic,
	}

	buf := new(bytes.Buffer)
	if err := binary.Write(buf, binary.LittleEndian, vp); err != nil {
		return fmt.Errorf("vm_slave serialize: %w", err)
	}

	topic := fmt.Sprintf("trading/vm_slaves/%s", a.AccountID)
	token := client.Publish(topic, 1, false, buf.Bytes())
	token.Wait()
	if err := token.Error(); err != nil {
		return fmt.Errorf("vm_slave[%s] publish: %w", a.AccountID, err)
	}
	return nil
}
