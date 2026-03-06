#property copyright "TRS Slave EA MT5"
#property version   "1.40"

#define MQTT_HOST   "172.16.21.1"
#define MQTT_PORT   1883
#define ACCOUNT_ID  "vm_mt5"
#define MAGIC       20240101

#import "MQTTClient.dll"
   int  MQTT_Connect(string host, int port, string clientId);
   int  MQTT_Subscribe(int handle, string topic);
   int  MQTT_Receive(int handle, uchar& buf[], int bufSize);
   void MQTT_Disconnect(int handle);
#import

#import "kernel32.dll"
   void RtlMoveMemory(double& dest, const uchar& src[], int count);
   void RtlMoveMemory(long&   dest, const uchar& src[], int count);
#import

int    g_handle    = -1;
string g_topic     = "trading/vm_slaves/" + ACCOUNT_ID;
int    g_retryTick = 0;   // counts timer ticks for retry backoff

// ── Master→Slave position map ─────────────────────────────────────────────────
struct TicketMap {
   long   masterTicket;
   ulong  dealTicket;    // actual MT5 deal/position ticket
   double sl;
   double tp;
};
TicketMap g_map[];
int       g_mapCount = 0;

// ── Pending order queue (retry if symbol price not yet ready) ─────────────────
struct PendingOrder {
   long   masterTicket;
   string symbol;
   int    orderType;
   double volume;
   double sl;
   double tp;
   int    retries;
};
PendingOrder g_pending[];
int          g_pendingCount = 0;

// ── Raw payload struct ────────────────────────────────────────────────────────
struct VMTradePayload {
   long   ticket;
   uchar  symbol[12];
   int    order_type;
   double volume;
   double price;
   double sl;
   double tp;
   int    magic;
   int    pad;
};

//─────────────────────────────────────────────────────────────────────────────

void OnInit() {
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt5_" + ACCOUNT_ID);
   if (g_handle < 0) { Print("TRS Slave MT5: MQTT connect failed"); ExpertRemove(); return; }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) { Print("TRS Slave MT5: Subscribe failed"); ExpertRemove(); return; }
   EventSetMillisecondTimer(100);
   Print("TRS Slave MT5: ONLINE v1.40. Topic: ", g_topic);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer() {
   // 1. Retry any pending orders whose prices weren't ready yet
   RetryPending();

   // 2. Poll for new MQTT messages
   uchar buf[128];
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received < 64) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) return;

   // Extract symbol — stop at first null byte
   int symLen = 0;
   while (symLen < 12 && p.symbol[symLen] != 0) symLen++;
   string sym = CharArrayToString(p.symbol, 0, symLen, CP_ACP);

   if (StringLen(sym) == 0) { Print("TRS Slave MT5: Empty symbol, skipping"); return; }

   PrintFormat("TRS Slave MT5: Recv ticket=%d sym='%s' type=%d vol=%.2f sl=%.5f tp=%.5f",
               p.ticket, sym, p.order_type, p.volume, p.sl, p.tp);

   // ── Close signal ─────────────────────────────────────────────────────────
   if (p.order_type == 10) {
      HandleClose(p.ticket);
      return;
   }

   // ── Existing ticket — SL/TP modify ────────────────────────────────────────
   int mapIdx = FindMap(p.ticket);
   if (mapIdx >= 0) {
      bool slChanged = MathAbs(g_map[mapIdx].sl - p.sl) > 0.000001;
      bool tpChanged = MathAbs(g_map[mapIdx].tp - p.tp) > 0.000001;
      if (!slChanged && !tpChanged) return;

      if (!PositionSelectByTicket(g_map[mapIdx].dealTicket)) {
         PrintFormat("TRS Slave MT5: PositionSelectByTicket failed deal=%d err=%d",
                     g_map[mapIdx].dealTicket, GetLastError());
         return;
      }
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = PositionGetString(POSITION_SYMBOL);
      req.position = g_map[mapIdx].dealTicket;
      req.sl       = p.sl;
      req.tp       = p.tp;
      ResetLastError();
      if (!OrderSend(req, res))
         PrintFormat("TRS Slave MT5: Modify Error=%d retcode=%d deal=%d", GetLastError(), res.retcode, g_map[mapIdx].dealTicket);
      else {
         PrintFormat("TRS Slave MT5: Modified deal=%d sl=%.5f tp=%.5f", g_map[mapIdx].dealTicket, p.sl, p.tp);
         g_map[mapIdx].sl = p.sl;
         g_map[mapIdx].tp = p.tp;
      }
      return;
   }

   // ── New trade — enqueue immediately ───────────────────────────────────────
   if (p.order_type != 0 && p.order_type != 1) {
      PrintFormat("TRS Slave MT5: Unknown order_type=%d, skipping", p.order_type);
      return;
   }
   EnqueueOrder(p.ticket, sym, p.order_type, p.volume, p.sl, p.tp);
   // Attempt immediately — if prices not ready it stays in queue for RetryPending
   ProcessPending(g_pendingCount - 1);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res) {
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      PrintFormat("TRS Slave MT5: Deal deal=%d order=%d position=%d sym=%s vol=%.2f price=%.5f",
                  trans.deal, trans.order, trans.position, trans.symbol, trans.volume, trans.price);
      // Store the POSITION ticket (not deal ticket) — PositionSelectByTicket requires it
      for (int i = 0; i < g_mapCount; i++) {
         if (g_map[i].dealTicket == (ulong)trans.order) {
            g_map[i].dealTicket = trans.position;
            PrintFormat("TRS Slave MT5: Map updated master=%d → position=%d", g_map[i].masterTicket, trans.position);
            break;
         }
      }
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Close handler

void HandleClose(long masterTicket) {
   int mapIdx = FindMap(masterTicket);
   if (mapIdx < 0) {
      PrintFormat("TRS Slave MT5: CLOSE ticket=%d — no local mapping, ignoring", masterTicket);
      return;
   }

   ulong dealTkt = g_map[mapIdx].dealTicket;
   if (!PositionSelectByTicket(dealTkt)) {
      PrintFormat("TRS Slave MT5: CLOSE — PositionSelectByTicket failed deal=%d err=%d", dealTkt, GetLastError());
      RemoveMap(mapIdx);
      return;
   }

   string sym     = PositionGetString(POSITION_SYMBOL);
   double vol     = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = sym;
   req.volume   = vol;
   req.position = dealTkt;
   req.comment  = "TRS Close";
   req.magic    = MAGIC;

   if (ptype == POSITION_TYPE_BUY) {
      req.type  = ORDER_TYPE_SELL;
      req.price = bid;
   } else {
      req.type  = ORDER_TYPE_BUY;
      req.price = ask;
   }

   // Try all filling modes
   ENUM_ORDER_TYPE_FILLING fills[3];
   fills[0] = ORDER_FILLING_IOC;
   fills[1] = ORDER_FILLING_FOK;
   fills[2] = ORDER_FILLING_RETURN;

   for (int f = 0; f < 3; f++) {
      req.type_filling = fills[f];
      ResetLastError();
      if (OrderSend(req, res)) {
         PrintFormat("TRS Slave MT5: Closed deal=%d sym=%s vol=%.2f filling=%d", dealTkt, sym, vol, f);
         RemoveMap(mapIdx);
         return;
      }
      PrintFormat("TRS Slave MT5: Close filling=%d err=%d retcode=%d", f, GetLastError(), res.retcode);
      if (res.retcode != 10030) break;
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Pending queue

void EnqueueOrder(long masterTkt, string sym, int oType, double vol, double sl, double tp) {
   ArrayResize(g_pending, g_pendingCount + 1);
   g_pending[g_pendingCount].masterTicket = masterTkt;
   g_pending[g_pendingCount].symbol       = sym;
   g_pending[g_pendingCount].orderType    = oType;
   g_pending[g_pendingCount].volume       = vol;
   g_pending[g_pendingCount].sl           = sl;
   g_pending[g_pendingCount].tp           = tp;
   g_pending[g_pendingCount].retries      = 0;
   g_pendingCount++;
}

void RemovePending(int idx) {
   for (int j = idx; j < g_pendingCount - 1; j++) g_pending[j] = g_pending[j + 1];
   g_pendingCount--;
   ArrayResize(g_pending, g_pendingCount);
}

void RetryPending() {
   for (int i = g_pendingCount - 1; i >= 0; i--)
      ProcessPending(i);
}

void ProcessPending(int idx) {
   if (idx < 0 || idx >= g_pendingCount) return;

   // Give up after 50 retries (~5 seconds at 100ms timer)
   if (g_pending[idx].retries > 50) {
      PrintFormat("TRS Slave MT5: Giving up on sym=%s after 50 retries", g_pending[idx].symbol);
      RemovePending(idx);
      return;
   }
   g_pending[idx].retries++;

   // Already mapped (duplicate message)
   if (FindMap(g_pending[idx].masterTicket) >= 0) { RemovePending(idx); return; }

   string sym = g_pending[idx].symbol;
   if (!SymbolSelect(sym, true)) {
      PrintFormat("TRS Slave MT5: SymbolSelect failed '%s' retry=%d err=%d", sym, g_pending[idx].retries, GetLastError());
      return;
   }

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   if (ask <= 0 || bid <= 0) {
      if (g_pending[idx].retries == 1)
         PrintFormat("TRS Slave MT5: Waiting for price '%s'...", sym);
      return;  // try again next tick
   }

   // Clamp to broker lot limits
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vol = g_pending[idx].volume;
   if (minLot > 0 && vol < minLot)  vol = minLot;
   if (maxLot > 0 && vol > maxLot)  vol = maxLot;
   if (lotStep > 0) vol = MathRound(vol / lotStep) * lotStep;
   vol = NormalizeDouble(vol, 2);

   ENUM_ORDER_TYPE orderType;
   double          reqPrice;
   if (g_pending[idx].orderType == 0) { orderType = ORDER_TYPE_BUY;  reqPrice = ask; }
   else                               { orderType = ORDER_TYPE_SELL; reqPrice = bid; }

   PrintFormat("TRS Slave MT5: Placing %s sym=%s vol=%.2f ask=%.5f bid=%.5f sl=%.5f tp=%.5f",
               (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               sym, vol, ask, bid, g_pending[idx].sl, g_pending[idx].tp);

   ENUM_ORDER_TYPE_FILLING fills[3];
   fills[0] = ORDER_FILLING_IOC;
   fills[1] = ORDER_FILLING_FOK;
   fills[2] = ORDER_FILLING_RETURN;

   for (int f = 0; f < 3; f++) {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = sym;
      req.volume       = vol;
      req.type         = orderType;
      req.price        = reqPrice;
      req.sl           = g_pending[idx].sl;
      req.tp           = g_pending[idx].tp;
      req.magic        = MAGIC;
      req.comment      = "TRS";
      req.type_filling = fills[f];

      ResetLastError();
      if (OrderSend(req, res)) {
         PrintFormat("TRS Slave MT5: OK sym=%s vol=%.2f price=%.5f filling=%d order=%d deal=%d",
                     sym, vol, reqPrice, f, res.order, res.deal);
         AddMap(g_pending[idx].masterTicket, res.order, g_pending[idx].sl, g_pending[idx].tp);
         RemovePending(idx);
         return;
      }
      PrintFormat("TRS Slave MT5: OrderSend filling=%d err=%d retcode=%d '%s'",
                  f, GetLastError(), res.retcode, res.comment);
      if (res.retcode != 10030) break;
   }
   // Failed this attempt — stays in queue for next retry
}

//─────────────────────────────────────────────────────────────────────────────
// Map helpers

int FindMap(long masterTkt) {
   for (int i = 0; i < g_mapCount; i++)
      if (g_map[i].masterTicket == masterTkt) return i;
   return -1;
}

void AddMap(long masterTkt, ulong orderOrDeal, double sl, double tp) {
   ArrayResize(g_map, g_mapCount + 1);
   g_map[g_mapCount].masterTicket = masterTkt;
   g_map[g_mapCount].dealTicket   = orderOrDeal;
   g_map[g_mapCount].sl           = sl;
   g_map[g_mapCount].tp           = tp;
   g_mapCount++;
}

void RemoveMap(int idx) {
   for (int j = idx; j < g_mapCount - 1; j++) g_map[j] = g_map[j + 1];
   g_mapCount--;
   ArrayResize(g_map, g_mapCount);
}

//─────────────────────────────────────────────────────────────────────────────
// Payload deserialization

bool UnpackPayload(const uchar& buf[], int size, VMTradePayload& p) {
   if (size < 64) return false;
   uchar tmp8[8];
   ArrayCopy(tmp8, buf, 0, 0, 8);
   RtlMoveMemory(p.ticket, tmp8, 8);
   for (int i = 0; i < 12; i++) p.symbol[i] = buf[8 + i];
   p.order_type = (int)buf[20] | ((int)buf[21] << 8) | ((int)buf[22] << 16) | ((int)buf[23] << 24);
   p.volume = ReadDouble(buf, 24);
   p.price  = ReadDouble(buf, 32);
   p.sl     = ReadDouble(buf, 40);
   p.tp     = ReadDouble(buf, 48);
   p.magic  = (int)buf[56] | ((int)buf[57] << 8) | ((int)buf[58] << 16) | ((int)buf[59] << 24);
   return true;
}

double ReadDouble(const uchar& buf[], int offset) {
   uchar tmp[8];
   ArrayCopy(tmp, buf, 0, offset, 8);
   double result;
   RtlMoveMemory(result, tmp, 8);
   return result;
}
