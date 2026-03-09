# TRS — Trade Replication System

A high-performance trade copier built on a **Mac Mini M4** that replicates trades from a license-locked Master MT4 (running under Wine/macOS) to MT4/MT5 slaves in a Windows VM and cloud trading API platforms simultaneously.

---

## Architecture

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  Wine (macOS)                                                            │
 │  Master MT4  ──OnTrade/OnTimer──►  MasterEA.mq4                         │
 │                                        │                                 │
 │                                  mt4_bridge.dll  (32-bit Rust, no_std)   │
 │                                        │                                 │
 └────────────────────────────────────────┼─────────────────────────────────┘
                                          │ MQTT publish  (QoS 1)
                                          ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  Docker (macOS localhost)                                                │
 │  Mosquitto MQTT  0.0.0.0:1883                                            │
 └──────────────────────────────────────────────────────────────────────────┘
                                          │
                               ┌──────────┤──────────┐
                               ▼                     ▼
 ┌────────────────────────────────┐      ┌─────────────────────────────────┐
 │  Go Relay (macOS native)       │      │  Windows 11 ARM VM (Fusion)     │
 │                                │      │                                 │
 │  Risk Engine (equity scaling)  │      │  SlaveEA.mq4  ─► OrderSend()   │
 │  Symbol Mapper (JSON config)   │      │  SlaveEA.mq5  ─► OrderSend()   │
 │  Goroutine per slave           │      │                                 │
 │                                │      │  MQTTClient.dll (32-bit)        │
 │  ► TradeLocker   REST+JWT      │      │  Connects to 172.16.21.1:1883   │
 │  ► MatchTrader   REST+STOMP    │      └─────────────────────────────────┘
 │  ► Tradovate     REST          │
 │  ► VM Slave      MQTT re-pub   │
 └────────────────────────────────┘
```

### Network paths

| Leg | Path | Target latency |
|-----|------|----------------|
| Master → MQTT | `localhost:1883` | < 1 ms |
| Go Relay → VM Slave | `localhost:1883` → `172.16.21.1:1883` | < 5 ms |
| Go Relay → Cloud APIs | HTTPS | < 40 ms |

---

## Repository Layout

```
trs/
├── bridge/                   # Rust 32-bit DLL (Wine-compatible, no_std)
│   ├── Cargo.toml
│   ├── .cargo/config.toml    # i686-pc-windows-gnu target + zigbuild
│   └── src/lib.rs
├── mqtt_client_dll/          # Rust 32-bit MQTT DLL for VM slave EAs
│   ├── Cargo.toml
│   └── src/lib.rs
├── relay/                    # Go orchestration relay
│   ├── go.mod
│   ├── main.go
│   ├── engine/
│   │   ├── payload.go        # Binary deserialization of trade payloads
│   │   └── risk.go           # Risk/lot sizing engine
│   └── adapters/
│       ├── tradelocker.go
│       ├── matchtrade.go
│       ├── tradovate.go
│       └── vm_slave.go
├── ea/
│   ├── master/
│   │   └── MasterEA.mq4      # Master EA with magic-filter + manual trade support
│   └── slave/
│       ├── SlaveEA.mq4       # MT4 slave (Windows VM)
│       └── SlaveEA.mq5       # MT5 slave (Windows VM)
├── config/
│   └── relay_config.json     # All slave accounts + risk settings
├── relay/config/
│   └── symbols.json          # Symbol translation map
└── docker/
    └── docker-compose.yml    # Mosquitto broker
```

---

## Components

### A — Rust Bridge DLL (`bridge/`)

A 32-bit Windows DLL (`mt4_bridge.dll`) that the Master MT4 EA calls to publish trade events to the local MQTT broker.

**Key design decisions:**
- Built as `#![no_std]` to avoid Universal CRT dependencies (`api-ms-win-crt-*.dll`) that are absent in Wine.
- Uses raw WinSock2 (`ws2_32.dll`) + `kernel32.dll` only — both present in Wine's default prefix.
- Cross-compiled on macOS using `cargo-zigbuild` targeting `i686-pc-windows-gnu`.
- Implements a minimal MQTT 3.1.1 CONNECT + PUBLISH sequence directly over TCP — no external crate needed.

**Exported functions:**
```c
int  bridge_init();        // Connect to localhost:1883 — returns 0 on success
void bridge_shutdown();    // Close socket
int  send_trade_event(     // Publish 64-byte packed struct — returns 0 on success
    long   ticket,
    uchar  symbol[12],
    int    order_type,
    double volume,
    double price,
    double sl,
    double tp,
    int    magic,
    int    pad
);
```

**Build:**
```bash
cd bridge
cargo zigbuild --target i686-pc-windows-gnu --release
# Output: target/i686-pc-windows-gnu/release/mt4_bridge.dll
```

**Deploy:**
```
~/Library/Application Support/net.metaquotes.wine.metatrader4/
  drive_c/Program Files (x86)/MetaTrader 4/MQL4/Libraries/mt4_bridge.dll
```

---

### B — Go Relay (`relay/`)

The central logic engine. Subscribes to `trading/master`, applies the risk engine, maps symbols, and fans out to all configured slave adapters concurrently.

**Starting the relay:**
```bash
cd relay
go run . ../config/relay_config.json
```

**Payload format** (64 bytes, little-endian):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | ticket (int64) |
| 8 | 12 | symbol (null-padded ASCII) |
| 20 | 4 | order_type (int32: 0=BUY, 1=SELL) |
| 24 | 8 | volume (float64) |
| 32 | 8 | price (float64) |
| 40 | 8 | sl (float64) |
| 48 | 8 | tp (float64) |
| 56 | 4 | magic (int32) |
| 60 | 4 | pad (int32) |

---

### C — Master EA (`ea/master/MasterEA.mq4`)

Runs on the Master MT4 (Wine). Monitors trades from specific EAs and optionally manual trades, then calls the Rust bridge DLL to publish each event.

**Inputs:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Magic1` | `11223388` | THERANTO V3 magic number |
| `Magic2` | `202` | Gold Scalping magic number |
| `Magic3-5` | `-1` | Extra EA magic slots (set -1 to disable) |
| `CopyManualTrades` | `true` | Also copy trades with magic=0 |

**Behaviour:**
- `OnTrade()` fires immediately on any order event.
- `OnTimer()` (10ms) acts as a fail-safe heartbeat.
- Each order is snapshotted: ticket + type + lots + price + SL + TP. Only publishes if any field has changed.
- SL/TP changes on existing orders are detected and re-published, triggering `OrderModify()` on slaves.

---

### D — VM Slave EAs (`ea/slave/`)

Running inside Windows 11 ARM VM (VMware Fusion). Subscribe to their own MQTT topic and execute trades.

**SlaveEA.mq4** — MT4:
- Topic: `trading/vm_slaves/vm_mt4`
- Executes `OrderSend()` on new trades.
- Tracks master↔slave ticket mapping; calls `OrderModify()` when SL/TP change.

**SlaveEA.mq5** — MT5:
- Topic: `trading/vm_slaves/vm_mt5`
- Uses synchronous `OrderSend()` with filling mode fallback: tries `ORDER_FILLING_IOC` → `ORDER_FILLING_FOK` → `ORDER_FILLING_RETURN` (broker compatibility).
- `OnTradeTransaction()` confirms fills and updates internal deal ticket map.
- Symbol suffix (e.g., `m` for `AUDCADm`) is appended by the relay, not the EA.

**Dependencies:**
- `MQTTClient.dll` — 32-bit Rust MQTT client DLL (built from `mqtt_client_dll/`).
  - Copy to `MT4/MQL4/Libraries/` and `MT5/MQL5/Libraries/`.

---

## Risk Engine

Configured per-slave via `risk_mode` and `risk_value` in `relay_config.json`.

| Mode | `risk_value` meaning | Formula |
|------|---------------------|---------|
| `proportional` *(default)* | unused | `masterLot × (slaveEquity / masterEquity)` |
| `percent` | % of equity to risk | `masterLot × (slaveEquity × pct) / (masterEquity × pct)` |
| `fixed_lot` | lot size | always `risk_value` lots |
| `fixed_dollars` | $ amount to risk | `masterLot × riskDollars / masterEquity` |

**Example — fixed 0.05 lots per trade for vm_mt4:**
```json
{
  "id": "vm_mt4",
  "type": "vm_slave",
  "account_id": "vm_mt4",
  "equity": 5000,
  "risk_mode": "fixed_lot",
  "risk_value": 0.05
}
```

**Example — risk 2% of equity:**
```json
{
  "risk_mode": "percent",
  "risk_value": 2.0
}
```

---

## Symbol Mapping

Edit `relay/config/symbols.json` to translate master symbols to platform-specific names:

```json
{
  "XAUUSD": {
    "tradelocker": "GOLD",
    "matchtrade":  "XAUUSD",
    "tradovate":   "XAUUSD",
    "vm_slave":    "XAUUSD"
  },
  "BTCUSD": {
    "tradelocker": "BTCUSD",
    "matchtrade":  "BTCUSD",
    "tradovate":   "BTCUSD",
    "vm_slave":    "BTCUSD"
  }
}
```

For VM slave symbol suffixes (e.g., broker appends `m`), set `symbol_suffix` on the slave config:
```json
{ "id": "vm_mt5", "type": "vm_slave", "symbol_suffix": "m" }
```

---

## Setup Guide

### 1. Prerequisites

```bash
# macOS
brew install go mosquitto cargo-zigbuild
rustup target add i686-pc-windows-gnu
```

### 2. Start MQTT Broker (native Homebrew — no Docker required)

```bash
# Write config
cp mosquitto-native.conf /opt/homebrew/etc/mosquitto/mosquitto.conf

# Start as a background service (auto-restarts on login)
brew services start mosquitto

# Verify
brew services list | grep mosquitto
mosquitto_pub -h 127.0.0.1 -t test -m hello
```

> Docker is no longer used. `docker/docker-compose.yml` is kept for reference only.

### 3. Build the Bridge DLL

```bash
cd bridge
cargo zigbuild --target i686-pc-windows-gnu --release
cp target/i686-pc-windows-gnu/release/mt4_bridge.dll \
   ~/Library/Application\ Support/net.metaquotes.wine.metatrader4/drive_c/Program\ Files\ \(x86\)/MetaTrader\ 4/MQL4/Libraries/
```

### 4. Build the MQTT Client DLL (for VM Slaves)

```bash
cd mqtt_client_dll
cargo zigbuild --target i686-pc-windows-gnu --release
# Copy MQTTClient.dll to the Windows VM:
# MT4: C:\Program Files (x86)\MetaTrader 4\MQL4\Libraries\
# MT5: C:\Program Files\MetaTrader 5\MQL5\Libraries\
```

### 5. Compile Master EA

1. Open MetaEditor in Wine MT4.
2. Open `ea/master/MasterEA.mq4`.
3. Compile → `MasterEA.ex4` is generated.
4. Attach to any chart. Configure `Magic1`, `Magic2`, and `CopyManualTrades` in EA inputs.

### 6. Configure the Relay

Edit `config/relay_config.json`:
- Set `master_equity` to the master account balance.
- Fill in credentials for TradeLocker / MatchTrader / Tradovate (or disable by removing from the slaves array).
- Set `equity` for each VM slave (used by proportional risk mode).
- Set `risk_mode` and `risk_value` per slave as needed.

### 7. Start the Relay

```bash
cd relay
go run . ../config/relay_config.json
```

### 8. Deploy Slave EAs on Windows VM

1. Copy `MQTTClient.dll` to both MT4 and MT5 library folders.
2. Copy `SlaveEA.mq4` → compile in MT4 MetaEditor → attach to any chart.
3. Copy `SlaveEA.mq5` → compile in MT5 MetaEditor → attach to any chart.
4. Verify connection: `Test-NetConnection 172.16.21.1 -Port 1883` should succeed.

---

## Configuration Reference

```json
{
  "mqtt_broker":    "tcp://localhost:1883",
  "master_topic":   "trading/master",
  "master_equity":  10000,
  "symbol_map_path": "config/symbols.json",
  "slaves": [
    {
      "id":           "vm_mt4",
      "type":         "vm_slave",
      "account_id":   "vm_mt4",
      "equity":       5000,
      "risk_mode":    "proportional",
      "risk_value":   0
    },
    {
      "id":           "vm_mt5",
      "type":         "vm_slave",
      "account_id":   "vm_mt5",
      "symbol_suffix": "m",
      "equity":       5000,
      "risk_mode":    "proportional",
      "risk_value":   0
    },
    {
      "id":         "tl_acc1",
      "type":       "tradelocker",
      "base_url":   "https://demo.tradelocker.com/backend-service",
      "account_id": "...",
      "email":      "...",
      "password":   "...",
      "server_id":  "...",
      "risk_mode":  "proportional",
      "risk_value": 0
    }
  ]
}
```

---

## Monitoring & Debugging

**Watch all MQTT traffic:**
```bash
mosquitto_sub -h 127.0.0.1 -t "trading/#" -v
```

**Relay log output:**
```
[master] ticket=283069192 sym=BTCEUR type=BUY vol=0.11 price=...
[vm_slave:vm_mt4] OK ticket=283069192 sym=BTCEUR lot=0.06 mode=proportional elapsed=0.5ms total=0.8ms
```

**Master EA confirms per-source:**
```
TRS: [THERANTO V3] published ticket=283072895 sym=AUDCAD type=1 lots=0.11 sl=0.00000 tp=0.00000
TRS: [MANUAL] published ticket=283079001 sym=EURUSD type=0 lots=0.10 sl=0.00000 tp=0.00000
```

**Slave MT5 filling mode diagnosis:**
```
TRS Slave MT5: OrderSend filling=0 Error=... retcode=10030  ← IOC rejected, trying FOK
TRS Slave MT5: Sent sym=AUDCADm type=1 vol=0.06 price=... filling=2  ← RETURN worked
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot load mt4_bridge.dll [126]` | DLL has CRT dependencies Wine can't resolve | Rebuild with `#![no_std]` + zigbuild (already done) |
| `TRS: bridge_init failed` | Mosquitto not running | `docker compose up -d` or start native Mosquitto |
| Slave receives nothing | Relay not running | `cd relay && go run . ../config/relay_config.json` |
| `Invalid price for BTCEUR` | Symbol not in broker's Market Watch | `SymbolSelect(sym, true)` already added |
| MT5 `retcode=10030` | Broker rejects IOC fill | EA now tries IOC→FOK→RETURN automatically |
| Two relay processes (`EOF` loop) | Duplicate `client_id` → broker kicks old one | Kill all `go run` processes, start one instance |
| VM can't reach port 1883 | Wrong gateway IP | Run `ipconfig` in VM, use the Default Gateway IP (e.g., `172.16.21.1`) |
| SL/TP not copied | Snapshot didn't detect change | MasterEA compares all fields; re-check `g_snapshot` update logic |

---

## Latency Measurements

Typical observed latencies on Mac Mini M4:

| Path | Observed |
|------|----------|
| Master → MQTT publish | ~0.1ms |
| MQTT → Go relay | ~0.2ms |
| Go relay → VM slave MQTT | ~0.5ms |
| VM slave MQTT → OrderSend fill | ~2–5ms |
| Go relay → TradeLocker REST | ~15–30ms |

---

## Single Chart Slave Setup

The slave EA does **not** need to run on the same chart as the traded pair. It subscribes to an MQTT topic and handles **any symbol** that comes through. When a trade arrives for `EURUSDm`, `AUDCADm`, or `XAUUSDm`, the EA calls `SymbolSelect(sym, true)` which adds that symbol to Market Watch dynamically — regardless of which chart the EA is attached to.

**Recommended setup:**
- **Master** — 3 charts (`EURUSD`, `AUDCAD`, `XAUUSD`) each with their respective source EA (THERANTO V3, Gold Scalping, etc.)
- **MT4 Slave** — 1 chart, any symbol — handles all pairs automatically
- **MT5 Slave** — 1 chart, any symbol — handles all pairs automatically

> The only reason to run on multiple charts is redundancy in case one EA instance crashes. For normal operation, one instance per terminal is sufficient.

---

## Performance Recommendation

For best latency and execution quality, deploy this solution on a **VPS (Virtual Private Server)** located close to your brokers' execution servers and ECN/dealing desks.

Running on a local Mac Mini introduces variable latency from your home ISP. A cloud VPS co-located near the broker's data centre (e.g., LD4 London, NY4 New York, TY3 Tokyo) can reduce round-trip latency from 40–120ms down to 1–5ms for API-based slaves.

**Recommended providers:** AWS, Vultr, Contabo, ForexVPS — choose a region matching your broker's server location.

---

## License

MIT

---

## Author

**Ashley Chamboko** ([@achambok](https://github.com/achambok)) — *2026-03-06*

If this project helped you, consider buying me a coffee ☕

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-achambok-yellow?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/achambok)
