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

const tradovateAPISubscriptionProductName = "Market Data Subscription"
const tradovateMinBalance = 1000.0

type TradovateAdapter struct {
	BaseURL   string
	AccountID string
	APIKey    string
	Username  string
	Password  string
	DeviceID  string
	AppID     string
	AppVersion string

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
	client      *http.Client
}

func NewTradovateAdapter(baseURL, accountID, apiKey, username, password, deviceID, appID, appVersion string) *TradovateAdapter {
	return &TradovateAdapter{
		BaseURL:    baseURL,
		AccountID:  accountID,
		APIKey:     apiKey,
		Username:   username,
		Password:   password,
		DeviceID:   deviceID,
		AppID:      appID,
		AppVersion: appVersion,
		client:     &http.Client{Timeout: 5 * time.Second},
	}
}

func (a *TradovateAdapter) Name() string {
	return fmt.Sprintf("tradovate:%s", a.AccountID)
}

func (a *TradovateAdapter) ensureToken() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.accessToken != "" && time.Now().Before(a.tokenExpiry) {
		return nil
	}
	body, _ := json.Marshal(map[string]string{
		"name":       a.Username,
		"password":   a.Password,
		"appId":      a.AppID,
		"appVersion": a.AppVersion,
		"cid":        a.APIKey,
		"deviceId":   a.DeviceID,
	})
	resp, err := a.client.Post(a.BaseURL+"/auth/accesstokenrequest", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("tradovate auth: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var result struct {
		AccessToken string `json:"accessToken"`
		ExpirationTime string `json:"expirationTime"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || result.AccessToken == "" {
		return fmt.Errorf("tradovate auth failed: %s", raw)
	}
	a.accessToken = result.AccessToken
	a.tokenExpiry = time.Now().Add(80 * time.Minute)
	return nil
}

func (a *TradovateAdapter) GetEquity() (float64, error) {
	if err := a.ensureToken(); err != nil {
		return 0, err
	}
	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/cashbalance/getcashbalancesnapshot?accountId=%s", a.BaseURL, a.AccountID), nil)
	req.Header.Set("Authorization", "Bearer "+a.accessToken)
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var result struct {
		RealizedPnL float64 `json:"realizedPnL"`
		UnrealizedPnL float64 `json:"unrealizedPnL"`
		CashBalance float64 `json:"cashBalance"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return 0, err
	}
	return result.CashBalance + result.UnrealizedPnL, nil
}

func (a *TradovateAdapter) checkPrerequisites() error {
	if err := a.ensureToken(); err != nil {
		return err
	}

	balReq, _ := http.NewRequest("GET", fmt.Sprintf("%s/account/list", a.BaseURL), nil)
	balReq.Header.Set("Authorization", "Bearer "+a.accessToken)
	balResp, err := a.client.Do(balReq)
	if err != nil {
		return fmt.Errorf("tradovate account list: %w", err)
	}
	defer balResp.Body.Close()
	balRaw, _ := io.ReadAll(balResp.Body)

	var accounts []struct {
		ID            int     `json:"id"`
		MarginBalance float64 `json:"marginBalance"`
	}
	if err := json.Unmarshal(balRaw, &accounts); err != nil {
		return fmt.Errorf("tradovate account parse: %w", err)
	}
	balanceOK := false
	for _, acc := range accounts {
		if fmt.Sprintf("%d", acc.ID) == a.AccountID && acc.MarginBalance >= tradovateMinBalance {
			balanceOK = true
			break
		}
	}
	if !balanceOK {
		return fmt.Errorf("tradovate: account %s balance below $%.0f minimum", a.AccountID, tradovateMinBalance)
	}

	pluginReq, _ := http.NewRequest("GET", fmt.Sprintf("%s/userPlugin/list", a.BaseURL), nil)
	pluginReq.Header.Set("Authorization", "Bearer "+a.accessToken)
	pluginResp, err := a.client.Do(pluginReq)
	if err != nil {
		return fmt.Errorf("tradovate plugin list: %w", err)
	}
	defer pluginResp.Body.Close()
	pluginRaw, _ := io.ReadAll(pluginResp.Body)

	var plugins []struct {
		Active      bool   `json:"active"`
		ProductName string `json:"productName"`
	}
	if err := json.Unmarshal(pluginRaw, &plugins); err != nil {
		return fmt.Errorf("tradovate plugin parse: %w", err)
	}
	for _, pl := range plugins {
		if pl.Active && pl.ProductName == tradovateAPISubscriptionProductName {
			return nil
		}
	}
	return fmt.Errorf("tradovate: active API subscription not found (requires '%s')", tradovateAPISubscriptionProductName)
}

func (a *TradovateAdapter) PlaceOrder(p *engine.TradePayload, scaledLot float64, mappedSymbol string) error {
	if err := a.checkPrerequisites(); err != nil {
		return fmt.Errorf("tradovate pre-flight: %w", err)
	}

	action := "Buy"
	if p.OrderType == 1 {
		action = "Sell"
	}

	body, _ := json.Marshal(map[string]interface{}{
		"accountSpec":  a.AccountID,
		"accountId":    a.AccountID,
		"action":       action,
		"symbol":       mappedSymbol,
		"orderQty":     int(scaledLot),
		"orderType":    "Market",
		"isAutomated":  true,
	})

	req, _ := http.NewRequest("POST", a.BaseURL+"/order/placeorder", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+a.accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("tradovate placeOrder: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		return fmt.Errorf("tradovate placeOrder status %d: %s", resp.StatusCode, raw)
	}
	return nil
}
