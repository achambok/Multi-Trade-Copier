package adapters

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
	"trs/relay/engine"

	"github.com/go-stomp/stomp/v3"
)

type MatchTraderAdapter struct {
	BaseURL    string
	AccountID  string
	APIKey     string
	STOMPAddr  string

	client *http.Client

	mu         sync.Mutex
	stompConn  *stomp.Conn
	fillsCh    chan string
}

func NewMatchTraderAdapter(baseURL, accountID, apiKey, stompAddr string) *MatchTraderAdapter {
	a := &MatchTraderAdapter{
		BaseURL:   baseURL,
		AccountID: accountID,
		APIKey:    apiKey,
		STOMPAddr: stompAddr,
		client:    &http.Client{Timeout: 5 * time.Second},
		fillsCh:   make(chan string, 64),
	}
	go a.stompSubscribeLoop()
	return a
}

func (a *MatchTraderAdapter) Name() string {
	return fmt.Sprintf("matchtrade:%s", a.AccountID)
}

func (a *MatchTraderAdapter) stompSubscribeLoop() {
	for {
		if err := a.connectStomp(); err != nil {
			log.Printf("matchtrade stomp connect error: %v — retrying in 60s", err)
			time.Sleep(60 * time.Second)
			continue
		}
		a.mu.Lock()
		conn := a.stompConn
		a.mu.Unlock()

		sub, err := conn.Subscribe(fmt.Sprintf("/topic/fills/%s", a.AccountID), stomp.AckAuto)
		if err != nil {
			log.Printf("matchtrade stomp subscribe error: %v", err)
			time.Sleep(3 * time.Second)
			continue
		}
		for msg := range sub.C {
			if msg.Err != nil {
				break
			}
			a.fillsCh <- string(msg.Body)
			log.Printf("matchtrade fill [%s]: %s", a.AccountID, string(msg.Body))
		}
		time.Sleep(1 * time.Second)
	}
}

func (a *MatchTraderAdapter) connectStomp() error {
	conn, err := net.DialTimeout("tcp", a.STOMPAddr, 5*time.Second)
	if err != nil {
		return err
	}
	sc, err := stomp.Connect(conn,
		stomp.ConnOpt.Header("login", a.APIKey),
		stomp.ConnOpt.Header("account", a.AccountID),
	)
	if err != nil {
		return err
	}
	a.mu.Lock()
	a.stompConn = sc
	a.mu.Unlock()
	return nil
}

func (a *MatchTraderAdapter) GetEquity() (float64, error) {
	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/accounts/%s", a.BaseURL, a.AccountID), nil)
	req.Header.Set("X-API-KEY", a.APIKey)
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var result struct {
		Equity float64 `json:"equity"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return 0, err
	}
	return result.Equity, nil
}

func (a *MatchTraderAdapter) PlaceOrder(p *engine.TradePayload, scaledLot float64, mappedSymbol string) error {
	side := "BUY"
	if p.OrderType == 1 {
		side = "SELL"
	}
	body, _ := json.Marshal(map[string]interface{}{
		"accountId": a.AccountID,
		"symbol":    mappedSymbol,
		"side":      side,
		"orderType": "MARKET",
		"quantity":  scaledLot,
	})
	req, _ := http.NewRequest("POST", a.BaseURL+"/order", bytes.NewReader(body))
	req.Header.Set("X-API-KEY", a.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("matchtrade order: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		return fmt.Errorf("matchtrade order status %d: %s", resp.StatusCode, raw)
	}
	return nil
}
