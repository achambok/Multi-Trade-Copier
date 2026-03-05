package adapters

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
	"trs/relay/engine"
)

type TradeLockerAdapter struct {
	BaseURL   string
	AccountID string
	Email     string
	Password  string
	ServerID  string

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
	client      *http.Client
}

func NewTradeLockerAdapter(baseURL, accountID, email, password, serverID string) *TradeLockerAdapter {
	return &TradeLockerAdapter{
		BaseURL:   baseURL,
		AccountID: accountID,
		Email:     email,
		Password:  password,
		ServerID:  serverID,
		client:    &http.Client{Timeout: 5 * time.Second},
	}
}

func (a *TradeLockerAdapter) Name() string {
	return fmt.Sprintf("tradelocker:%s", a.AccountID)
}

func (a *TradeLockerAdapter) ensureToken() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.accessToken != "" && time.Now().Before(a.tokenExpiry) {
		return nil
	}
	body, _ := json.Marshal(map[string]string{
		"email":    a.Email,
		"password": a.Password,
		"server":   a.ServerID,
	})
	resp, err := a.client.Post(a.BaseURL+"/auth/jwt/token", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("tradelocker auth: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return fmt.Errorf("tradelocker auth status %d: %s", resp.StatusCode, raw)
	}
	var result struct {
		AccessToken string `json:"accessToken"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return fmt.Errorf("tradelocker auth decode: %w", err)
	}
	a.accessToken = result.AccessToken
	a.tokenExpiry = time.Now().Add(23 * time.Hour)
	return nil
}

func (a *TradeLockerAdapter) GetEquity() (float64, error) {
	if err := a.ensureToken(); err != nil {
		return 0, err
	}
	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/trade/accounts/%s", a.BaseURL, a.AccountID), nil)
	req.Header.Set("Authorization", "Bearer "+a.accessToken)
	req.Header.Set("accNum", a.AccountID)
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 {
		a.mu.Lock()
		a.accessToken = ""
		a.mu.Unlock()
		return 0, fmt.Errorf("tradelocker equity: unauthorized, will retry")
	}
	raw, _ := io.ReadAll(resp.Body)
	var result struct {
		D struct {
			Equity float64 `json:"equity"`
		} `json:"d"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return 0, err
	}
	return result.D.Equity, nil
}

func (a *TradeLockerAdapter) PlaceOrder(p *engine.TradePayload, scaledLot float64, mappedSymbol string) error {
	if err := a.ensureToken(); err != nil {
		return err
	}

	side := "buy"
	if p.OrderType == 1 {
		side = "sell"
	}

	orderBody, _ := json.Marshal(map[string]interface{}{
		"instrument": mappedSymbol,
		"side":       side,
		"type":       "market",
		"qty":        scaledLot,
	})

	url := fmt.Sprintf("%s/trade/accounts/%s/orders", a.BaseURL, a.AccountID)
	req, _ := http.NewRequest("POST", url, bytes.NewReader(orderBody))
	req.Header.Set("Authorization", "Bearer "+a.accessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("accNum", a.AccountID)

	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("tradelocker order: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)

	if resp.StatusCode == 401 {
		a.mu.Lock()
		a.accessToken = ""
		a.mu.Unlock()
		return fmt.Errorf("tradelocker order: unauthorized")
	}
	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		return fmt.Errorf("tradelocker order status %d: %s", resp.StatusCode, raw)
	}
	return nil
}
