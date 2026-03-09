#!/usr/bin/env bash
# deploy/scripts/setup-launchd.sh
# Run once to install TRS as persistent macOS services.
# After this, everything survives reboots, crashes, and network glitches.
#
# Usage:  bash ~/trs/deploy/scripts/setup-launchd.sh

set -e
TRS_DIR="$HOME/trs"
LAUNCHD="$HOME/Library/LaunchAgents"
SCRIPTS_DIR="$TRS_DIR/deploy/scripts"

echo "=== TRS launchd setup ==="

# ── 1. Create log directory ───────────────────────────────────────────────────
mkdir -p "$TRS_DIR/logs"
echo "[1/5] Log directory: $TRS_DIR/logs"

# ── 2. Build relay binary ─────────────────────────────────────────────────────
echo "[2/5] Building relay binary..."
cd "$TRS_DIR/relay"
go build -o "$TRS_DIR/trs-relay" .
echo "      Built: $TRS_DIR/trs-relay"

# ── 3. Make scripts executable ───────────────────────────────────────────────
chmod +x "$SCRIPTS_DIR/start-mt4.sh"
echo "[3/5] Scripts marked executable"

# ── 4. Install launchd plists ─────────────────────────────────────────────────
echo "[4/5] Installing LaunchAgents..."

cp "$TRS_DIR/deploy/launchd/com.trs.relay.plist" "$LAUNCHD/"
cp "$TRS_DIR/deploy/launchd/com.trs.mt4.plist"   "$LAUNCHD/"

# Unload first (ignore errors if not loaded)
launchctl unload "$LAUNCHD/com.trs.relay.plist" 2>/dev/null || true
launchctl unload "$LAUNCHD/com.trs.mt4.plist"   2>/dev/null || true

launchctl load -w "$LAUNCHD/com.trs.relay.plist"
launchctl load -w "$LAUNCHD/com.trs.mt4.plist"

echo "      Loaded: com.trs.relay, com.trs.mt4"

# ── 5. Mosquitto via brew services ────────────────────────────────────────────
echo "[5/5] Ensuring Mosquitto is running as a service..."
cp "$TRS_DIR/mosquitto-native.conf" /opt/homebrew/etc/mosquitto/mosquitto.conf
brew services restart mosquitto
echo "      Mosquitto restarted"

echo ""
echo "=== Done. Checking status... ==="
brew services list | grep mosquitto
launchctl list | grep com.trs

echo ""
echo "Logs:"
echo "  Relay : $TRS_DIR/logs/relay.log"
echo "  MT4   : $TRS_DIR/logs/mt4.log"
echo "  MQTT  : brew services log mosquitto  (or: log show --predicate 'process == \"mosquitto\"' --last 1h)"
