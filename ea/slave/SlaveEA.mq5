#property copyright "TRS Slave EA MT5"
#property version   "1.30"

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

int    g_handle = -1;
string g_topic  = "trading/vm_slaves/" + ACCOUNT_ID;

struct TicketMap {
   long   masterTicket;
   ulong  dealTicket;
   double sl;
   double tp;
};
TicketMap g_map[];
int       g_mapCount = 0;

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

void OnInit() {
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt5_" + ACCOUNT_ID);
   if (g_handle < 0) { Print("TRS Slave MT5: MQTT connect failed"); ExpertRemove(); return; }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) { Print("TRS Slave MT5: Subscribe failed"); ExpertRemove(); return; }
   EventSetMillisecondTimer(50);
   Print("TRS Slave MT5: ONLINE v1.30. Listening on: ", g_topic);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer() {
   uchar buf[128];
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received < 64) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) return;

   // Extract symbol — stop at first null byte, not at array end
   int symLen = 0;
   while (symLen < 12 && p.symbol[symLen] != 0) symLen++;
   string sym = CharArrayToString(p.symbol, 0, symLen, CP_ACP);

   if (StringLen(sym) == 0) {
      Print("TRS Slave MT5: Empty symbol — skipping");
      return;
   }

   PrintFormat("TRS Slave MT5: Recv ticket=%d sym='%s' type=%d vol=%.2f sl=%.5f tp=%.5f",
               p.ticket, sym, p.order_type, p.volume, p.sl, p.tp);

   // ── Existing position — modify SL/TP if changed ──────────────────────────
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
      if (!OrderSend(req, res)) {
         PrintFormat("TRS Slave MT5: Modify Error=%d retcode=%d | deal=%d sl=%.5f tp=%.5f",
                     GetLastError(), res.retcode, g_map[mapIdx].dealTicket, p.sl, p.tp);
      } else {
         PrintFormat("TRS Slave MT5: Modified deal=%d sl=%.5f tp=%.5f", g_map[mapIdx].dealTicket, p.sl, p.tp);
         g_map[mapIdx].sl = p.sl;
         g_map[mapIdx].tp = p.tp;
      }
      return;
   }

   // ── New trade ─────────────────────────────────────────────────────────────
   if (!SymbolSelect(sym, true)) {
      PrintFormat("TRS Slave MT5: SymbolSelect failed for '%s' err=%d", sym, GetLastError());
      return;
   }

   // Wait up to 500ms for price to populate after SymbolSelect
   double ask = 0, bid = 0;
   for (int attempt = 0; attempt < 10; attempt++) {
      ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if (ask > 0 && bid > 0) break;
      Sleep(50);
   }

   PrintFormat("TRS Slave MT5: Prices sym='%s' ask=%.5f bid=%.5f", sym, ask, bid);

   if (ask <= 0 || bid <= 0) {
      PrintFormat("TRS Slave MT5: No price for '%s' after 500ms — aborting", sym);
      return;
   }

   ENUM_ORDER_TYPE orderType;
   double          reqPrice;
   if (p.order_type == 0) {
      orderType = ORDER_TYPE_BUY;
      reqPrice  = ask;
   } else if (p.order_type == 1) {
      orderType = ORDER_TYPE_SELL;
      reqPrice  = bid;
   } else {
      PrintFormat("TRS Slave MT5: Unsupported order type %d", p.order_type);
      return;
   }

   // Clamp volume to broker's min/max lot
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vol = p.volume;
   if (minLot > 0 && vol < minLot) vol = minLot;
   if (maxLot > 0 && vol > maxLot) vol = maxLot;
   if (lotStep > 0) vol = MathRound(vol / lotStep) * lotStep;
   vol = NormalizeDouble(vol, 2);

   PrintFormat("TRS Slave MT5: Placing %s %s vol=%.2f (orig=%.2f) price=%.5f sl=%.5f tp=%.5f",
               (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), sym, vol, p.volume, reqPrice, p.sl, p.tp);

   // Try filling modes: IOC → FOK → RETURN
   ENUM_ORDER_TYPE_FILLING fills[3];
   fills[0] = ORDER_FILLING_IOC;
   fills[1] = ORDER_FILLING_FOK;
   fills[2] = ORDER_FILLING_RETURN;
   bool sent = false;

   for (int f = 0; f < 3; f++) {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = sym;
      req.volume       = vol;
      req.type         = orderType;
      req.price        = reqPrice;
      req.sl           = p.sl;
      req.tp           = p.tp;
      req.magic        = MAGIC;
      req.comment      = "TRS";
      req.type_filling = fills[f];

      ResetLastError();
      if (OrderSend(req, res)) {
         PrintFormat("TRS Slave MT5: OK sym=%s type=%d vol=%.2f price=%.5f filling=%d order=%d deal=%d",
                     sym, p.order_type, vol, reqPrice, f, res.order, res.deal);
         AddMap(p.ticket, res.order, p.sl, p.tp);
         sent = true;
         break;
      }

      PrintFormat("TRS Slave MT5: OrderSend filling=%d failed: err=%d retcode=%d '%s'",
                  f, GetLastError(), res.retcode, res.comment);

      if (res.retcode != 10030) break; // 10030=invalid fill → try next; anything else bail out
   }

   if (!sent)
      PrintFormat("TRS Slave MT5: All fills failed sym=%s vol=%.2f", sym, vol);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res) {
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      PrintFormat("TRS Slave MT5: Deal confirmed deal=%d order=%d sym=%s vol=%.2f price=%.5f",
                  trans.deal, trans.order, trans.symbol, trans.volume, trans.price);
      for (int i = 0; i < g_mapCount; i++) {
         if (g_map[i].dealTicket == (ulong)trans.order) {
            g_map[i].dealTicket = trans.deal;
            break;
         }
      }
   }
}

// ── Map helpers ───────────────────────────────────────────────────────────────

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

// ── Payload deserialization ───────────────────────────────────────────────────

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

   p.magic = (int)buf[56] | ((int)buf[57] << 8) | ((int)buf[58] << 16) | ((int)buf[59] << 24);
   return true;
}

double ReadDouble(const uchar& buf[], int offset) {
   uchar tmp[8];
   ArrayCopy(tmp, buf, 0, offset, 8);
   double result;
   RtlMoveMemory(result, tmp, 8);
   return result;
}
