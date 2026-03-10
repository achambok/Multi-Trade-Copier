#property copyright "TRS Slave EA MT5"
#property version   "1.60"

#define MQTT_HOST   "172.16.21.1"
#define MQTT_PORT   1883
#define MAGIC       20240101

// Set this to match the slave "account_id" in relay_config.json.
// XM MT5 example      : vm_mt5_xm
// Exness MT5 example  : vm_mt5_exness
input string AccountID = "vm_mt5_xm";

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
string g_topic     = "";

// ── Master→Slave position/order map ──────────────────────────────────────────
struct TicketMap {
   long   masterTicket;
   ulong  slaveTicket;   // position ticket (market) or order ticket (pending)
   int    order_type;    // original MT4 type (0-5)
   double price;         // trigger price for pending orders
   double sl;
   double tp;
   bool   isPending;
};
TicketMap g_map[];
int       g_mapCount = 0;

// ── Pending/retry queue (market orders waiting for prices) ────────────────────
struct PendingOrder {
   long   masterTicket;
   string symbol;
   int    orderType;
   double volume;
   double price;
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
   g_topic  = "trading/vm_slaves/" + AccountID;
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt5_" + AccountID);
   if (g_handle < 0) { Print("TRS Slave MT5: MQTT connect failed"); ExpertRemove(); return; }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) { Print("TRS Slave MT5: Subscribe failed"); ExpertRemove(); return; }
   EventSetMillisecondTimer(100);
   Print("TRS Slave MT5: ONLINE v1.60. Topic: ", g_topic);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer() {
   RetryPending();

   uchar buf[128];
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received < 64) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) return;

   int symLen = 0;
   while (symLen < 12 && p.symbol[symLen] != 0) symLen++;
   string sym = CharArrayToString(p.symbol, 0, symLen, CP_ACP);
   if (StringLen(sym) == 0) { Print("TRS Slave MT5: Empty symbol, skipping"); return; }

   PrintFormat("TRS Slave MT5: Recv ticket=%d sym='%s' type=%d vol=%.2f sl=%.5f tp=%.5f",
               p.ticket, sym, p.order_type, p.volume, p.sl, p.tp);

   // ── Close/Cancel signal ───────────────────────────────────────────────────
   if (p.order_type == 10) {
      HandleClose(p.ticket);
      return;
   }

   // ── Existing ticket — modify ──────────────────────────────────────────────
   int mapIdx = FindMap(p.ticket);
   if (mapIdx >= 0) {
      HandleModify(mapIdx, p);
      return;
   }

   // ── New order ─────────────────────────────────────────────────────────────
   bool isPend = (p.order_type >= 2 && p.order_type <= 5);
   if (isPend) {
      PlacePendingOrder(p.ticket, sym, p.order_type, p.volume, p.price, p.sl, p.tp);
   } else if (p.order_type == 0 || p.order_type == 1) {
      EnqueueOrder(p.ticket, sym, p.order_type, p.volume, p.price, p.sl, p.tp);
      ProcessPending(g_pendingCount - 1);
   } else {
      PrintFormat("TRS Slave MT5: Unknown order_type=%d, skipping", p.order_type);
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res) {
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      PrintFormat("TRS Slave MT5: Deal deal=%d order=%d position=%d sym=%s vol=%.2f price=%.5f",
                  trans.deal, trans.order, trans.position, trans.symbol, trans.volume, trans.price);
      for (int i = 0; i < g_mapCount; i++) {
         if (g_map[i].slaveTicket == (ulong)trans.order && !g_map[i].isPending) {
            g_map[i].slaveTicket = trans.position;
            PrintFormat("TRS Slave MT5: Map updated master=%d → position=%d", g_map[i].masterTicket, trans.position);
            break;
         }
      }
   }
   // Pending order filled — reclassify as market position
   if (trans.type == TRADE_TRANSACTION_ORDER_UPDATE) {
      if (trans.order_state == ORDER_STATE_FILLED) {
         for (int i = 0; i < g_mapCount; i++) {
            if (g_map[i].slaveTicket == trans.order && g_map[i].isPending) {
               g_map[i].isPending   = false;
               // position ticket comes via DEAL_ADD above; set to order for now
               g_map[i].slaveTicket = trans.order;
               PrintFormat("TRS Slave MT5: Pending order=%d filled → now tracking as position", trans.order);
               break;
            }
         }
      }
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Pending order placement (limit/stop)

void PlacePendingOrder(long masterTkt, string sym, int orderType, double vol,
                       double price, double sl, double tp) {
   sym = ResolveSymbol(sym);
   if (StringLen(sym) == 0) return;

   if (!SymbolSelect(sym, true)) return;

   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if (minLot > 0 && vol < minLot)  vol = minLot;
   if (maxLot > 0 && vol > maxLot)  vol = maxLot;
   if (lotStep > 0) vol = MathRound(vol / lotStep) * lotStep;
   vol = NormalizeDouble(vol, 2);

   ENUM_ORDER_TYPE mt5Type;
   if      (orderType == 2) mt5Type = ORDER_TYPE_BUY_LIMIT;
   else if (orderType == 3) mt5Type = ORDER_TYPE_SELL_LIMIT;
   else if (orderType == 4) mt5Type = ORDER_TYPE_BUY_STOP;
   else if (orderType == 5) mt5Type = ORDER_TYPE_SELL_STOP;
   else return;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_PENDING;
   req.symbol   = sym;
   req.volume   = vol;
   req.type     = mt5Type;
   req.price    = price;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = MAGIC;
   req.comment  = "TRS";

   ResetLastError();
   if (OrderSend(req, res)) {
      PrintFormat("TRS Slave MT5: Pending placed order=%d sym=%s type=%d price=%.5f vol=%.2f",
                  res.order, sym, orderType, price, vol);
      AddMap(masterTkt, res.order, orderType, price, sl, tp, true);
   } else {
      PrintFormat("TRS Slave MT5: Pending order failed err=%d retcode=%d sym=%s type=%d price=%.5f",
                  GetLastError(), res.retcode, sym, orderType, price);
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Modify handler (market position or pending order)

void HandleModify(int mapIdx, VMTradePayload& p) {
   bool slChanged    = MathAbs(g_map[mapIdx].sl    - p.sl)    > 0.000001;
   bool tpChanged    = MathAbs(g_map[mapIdx].tp    - p.tp)    > 0.000001;
   bool priceChanged = g_map[mapIdx].isPending && (MathAbs(g_map[mapIdx].price - p.price) > 0.000001);
   if (!slChanged && !tpChanged && !priceChanged) return;

   ulong tkt = g_map[mapIdx].slaveTicket;

   if (g_map[mapIdx].isPending) {
      // Modify pending order price/SL/TP
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_MODIFY;
      req.order  = tkt;
      req.price  = p.price;
      req.sl     = p.sl;
      req.tp     = p.tp;
      ResetLastError();
      if (!OrderSend(req, res))
         PrintFormat("TRS Slave MT5: Pending Modify Error=%d retcode=%d order=%d", GetLastError(), res.retcode, tkt);
      else {
         PrintFormat("TRS Slave MT5: Pending Modified order=%d price=%.5f sl=%.5f tp=%.5f", tkt, p.price, p.sl, p.tp);
         g_map[mapIdx].price = p.price;
         g_map[mapIdx].sl    = p.sl;
         g_map[mapIdx].tp    = p.tp;
      }
   } else {
      // Modify market position SL/TP
      if (!PositionSelectByTicket(tkt)) {
         PrintFormat("TRS Slave MT5: PositionSelectByTicket failed pos=%d err=%d", tkt, GetLastError());
         return;
      }
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = PositionGetString(POSITION_SYMBOL);
      req.position = tkt;
      req.sl       = p.sl;
      req.tp       = p.tp;
      ResetLastError();
      if (!OrderSend(req, res))
         PrintFormat("TRS Slave MT5: Modify Error=%d retcode=%d pos=%d", GetLastError(), res.retcode, tkt);
      else {
         PrintFormat("TRS Slave MT5: Modified pos=%d sl=%.5f tp=%.5f", tkt, p.sl, p.tp);
         g_map[mapIdx].sl = p.sl;
         g_map[mapIdx].tp = p.tp;
      }
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Close/Cancel handler

void HandleClose(long masterTicket) {
   int mapIdx = FindMap(masterTicket);
   if (mapIdx < 0) {
      PrintFormat("TRS Slave MT5: CLOSE ticket=%d — no local mapping, ignoring", masterTicket);
      return;
   }

   ulong tkt = g_map[mapIdx].slaveTicket;

   if (g_map[mapIdx].isPending) {
      // Cancel pending order
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = tkt;
      ResetLastError();
      if (!OrderSend(req, res))
         PrintFormat("TRS Slave MT5: Cancel pending Error=%d retcode=%d order=%d", GetLastError(), res.retcode, tkt);
      else
         PrintFormat("TRS Slave MT5: Cancelled pending order=%d", tkt);
      RemoveMap(mapIdx);
      return;
   }

   // Close market position
   if (!PositionSelectByTicket(tkt)) {
      PrintFormat("TRS Slave MT5: CLOSE — PositionSelectByTicket failed pos=%d err=%d", tkt, GetLastError());
      RemoveMap(mapIdx);
      return;
   }

   string sym  = PositionGetString(POSITION_SYMBOL);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = sym;
   req.volume   = vol;
   req.position = tkt;
   req.comment  = "TRS Close";
   req.magic    = MAGIC;

   if (ptype == POSITION_TYPE_BUY) {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(sym, SYMBOL_BID);
   } else {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(sym, SYMBOL_ASK);
   }

   ENUM_ORDER_TYPE_FILLING fills[3];
   fills[0] = ORDER_FILLING_IOC;
   fills[1] = ORDER_FILLING_FOK;
   fills[2] = ORDER_FILLING_RETURN;

   for (int f = 0; f < 3; f++) {
      req.type_filling = fills[f];
      ResetLastError();
      if (OrderSend(req, res)) {
         PrintFormat("TRS Slave MT5: Closed pos=%d sym=%s vol=%.2f filling=%d", tkt, sym, vol, f);
         RemoveMap(mapIdx);
         return;
      }
      PrintFormat("TRS Slave MT5: Close filling=%d err=%d retcode=%d", f, GetLastError(), res.retcode);
      if (res.retcode != 10030) break;
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Market order retry queue

void EnqueueOrder(long masterTkt, string sym, int oType, double vol,
                  double price, double sl, double tp) {
   ArrayResize(g_pending, g_pendingCount + 1);
   g_pending[g_pendingCount].masterTicket = masterTkt;
   g_pending[g_pendingCount].symbol       = sym;
   g_pending[g_pendingCount].orderType    = oType;
   g_pending[g_pendingCount].volume       = vol;
   g_pending[g_pendingCount].price        = price;
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

   if (g_pending[idx].retries > 50) {
      PrintFormat("TRS Slave MT5: Giving up on sym=%s after 50 retries", g_pending[idx].symbol);
      RemovePending(idx);
      return;
   }
   g_pending[idx].retries++;

   if (FindMap(g_pending[idx].masterTicket) >= 0) { RemovePending(idx); return; }

   string sym = g_pending[idx].symbol;
   sym = ResolveSymbol(sym);
   if (StringLen(sym) == 0) {
      if (g_pending[idx].retries >= 3) RemovePending(idx);
      return;
   }
   g_pending[idx].symbol = sym;

   if (!SymbolSelect(sym, true)) return;

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if (ask <= 0 || bid <= 0) {
      if (g_pending[idx].retries == 1)
         PrintFormat("TRS Slave MT5: Waiting for price '%s'...", sym);
      return;
   }

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
         AddMap(g_pending[idx].masterTicket, res.order, g_pending[idx].orderType,
                reqPrice, g_pending[idx].sl, g_pending[idx].tp, false);
         RemovePending(idx);
         return;
      }
      PrintFormat("TRS Slave MT5: OrderSend filling=%d err=%d retcode=%d '%s'",
                  f, GetLastError(), res.retcode, res.comment);
      if (res.retcode != 10030) break;
   }
}

//─────────────────────────────────────────────────────────────────────────────
// Map helpers

int FindMap(long masterTkt) {
   for (int i = 0; i < g_mapCount; i++)
      if (g_map[i].masterTicket == masterTkt) return i;
   return -1;
}

void AddMap(long masterTkt, ulong slaveTkt, int orderType, double price,
            double sl, double tp, bool isPending) {
   ArrayResize(g_map, g_mapCount + 1);
   g_map[g_mapCount].masterTicket = masterTkt;
   g_map[g_mapCount].slaveTicket  = slaveTkt;
   g_map[g_mapCount].order_type   = orderType;
   g_map[g_mapCount].price        = price;
   g_map[g_mapCount].sl           = sl;
   g_map[g_mapCount].tp           = tp;
   g_map[g_mapCount].isPending    = isPending;
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

// ResolveSymbol tries the received symbol and common broker suffix variants.
string ResolveSymbol(string sym) {
   string strips[6], adds[6];
   strips[0]="m"; strips[1]=".pro"; strips[2]=".ecn";
   strips[3]=".r"; strips[4]=".raw"; strips[5]=".cf";
   adds[0]  ="m"; adds[1]  =".pro"; adds[2]  =".ecn";
   adds[3]  =".r"; adds[4] =".raw"; adds[5]  =".cf";

   if (SymbolSelect(sym, true) && SymbolInfoDouble(sym, SYMBOL_ASK) > 0) return sym;

   string base = sym;
   for (int i = 0; i < 6; i++) {
      int slen  = StringLen(sym);
      int sflen = StringLen(strips[i]);
      if (slen > sflen && StringSubstr(sym, slen - sflen) == strips[i]) {
         base = StringSubstr(sym, 0, slen - sflen);
         break;
      }
   }

   if (base != sym && SymbolSelect(base, true) && SymbolInfoDouble(base, SYMBOL_ASK) > 0) {
      PrintFormat("TRS Slave MT5: Resolved '%s' → '%s'", sym, base);
      return base;
   }

   for (int i = 0; i < 6; i++) {
      string c = base + adds[i];
      if (SymbolSelect(c, true) && SymbolInfoDouble(c, SYMBOL_ASK) > 0) {
         PrintFormat("TRS Slave MT5: Resolved '%s' → '%s'", sym, c);
         return c;
      }
   }

   PrintFormat("TRS Slave MT5: Cannot resolve symbol '%s' — not found on this broker", sym);
   return "";
}
