#!/usr/bin/env bash
# start-mt4.sh
# Launched by launchd (com.trs.mt4). Waits for MetaTrader 4 to exit so
# launchd can track the process and restart on crash.

APP="/Applications/MetaTrader 4.app"
LOG="/Users/blackrossay/trs/logs/mt4.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') [MT4] Starting MetaTrader 4..." >> "$LOG"

# Launch MT4 and wait for it — keeps this shell alive so launchd tracks it
open -W -a "$APP"

echo "$(date '+%Y-%m-%d %H:%M:%S') [MT4] MetaTrader 4 exited." >> "$LOG"
