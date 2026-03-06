#property copyright "TRS Slave EA MT5"
#property version   "1.10"

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

// ── Master→Slave position ticket map ─────────────────────────────────────────
struct TicketMap {
   long   masterTicket;
   ulong  dealTicket;
   double sl;
   double tp;
};
TicketMap g_map[];
int       g_mapCount = 0;

// ── Payload struct ────────────────────────────────────────────────────────────
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
   EventSetMillisecondTimer(1);
   Print("TRS Slave MT5: ONLINE. Listening on: ", g_topic);
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

   string sym = CharArrayToString(p.symbol, 0, -1, CP_ACP);
   StringTrimRight(sym);

   // ── Existing position — modify SL/TP if changed ───────────────────────────
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

      if (!OrderSendAsync(req, res)) {
         PrintFormat("TRS Slave MT5: Modify Error %d | deal=%d sl=%.5f tp=%.5f",
                     GetLastError(), g_map[mapIdx].dealTicket, p.sl, p.tp);
      } else {
         PrintFormat("TRS Slave MT5: Modified deal=%d sl=%.5f tp=%.5f",
                     g_map[mapIdx].dealTicket, p.sl, p.tp);
         g_map[mapIdx].sl = p.sl;
         g_map[mapIdx].tp = p.tp;
      }
      return;
   }

   // ── New trade ─────────────────────────────────────────────────────────────
   if (!SymbolSelect(sym, true)) {
      PrintFormat("TRS Slave MT5: SymbolSelect failed for '%s'", sym);
      return;
   }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.volume       = p.volume;
   req.sl           = p.sl;
   req.tp           = p.tp;
   req.magic        = MAGIC;
   req.comment      = "TRS";
   req.type_filling = ORDER_FILLING_IOC;

   if (p.order_type == 0) {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(sym, SYMBOL_ASK);
   } else if (p.order_type == 1) {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(sym, SYMBOL_BID);
   } else {
      PrintFormat("TRS Slave MT5: Unsupported order type %d", p.order_type);
      return;
   }

   if (req.price <= 0) { PrintFormat("TRS Slave MT5: No price for '%s'", sym); return; }

   if (!OrderSendAsync(req, res)) {
      PrintFormat("TRS Slave MT5: OrderSendAsync Error %d | sym=%s type=%d vol=%.2f",
                  GetLastError(), sym, p.order_type, p.volume);
   } else {
      PrintFormat("TRS Slave MT5: Sent sym=%s type=%d vol=%.2f price=%.5f",
                  sym, p.order_type, p.volume, req.price);
      // deal ticket stored in OnTradeTransaction
   }

   // Store master ticket with placeholder deal; updated in OnTradeTransaction
   AddMap(p.ticket, res.order, p.sl, p.tp);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res) {
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      PrintFormat("TRS Slave MT5: Fill confirmed deal=%d order=%d sym=%s vol=%.2f price=%.5f",
                  trans.deal, trans.order, trans.symbol, trans.volume, trans.price);
      // Update the map entry from order → actual deal ticket
      for (int i = 0; i < g_mapCount; i++) {
         if (g_map[i].dealTicket == trans.order) {
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
