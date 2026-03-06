#property strict
#property copyright "TRS Slave EA MT4"
#property version   "1.10"

#define MQTT_HOST   "172.16.21.1"
#define MQTT_PORT   1883
#define ACCOUNT_ID  "vm_mt4"
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

// ── Master→Slave ticket map ───────────────────────────────────────────────────
struct TicketMap {
   long   masterTicket;
   int    slaveTicket;
   double sl;
   double tp;
};
TicketMap g_map[];
int       g_mapCount = 0;

// ── Payload struct (matches Go relay binary.LittleEndian layout) ──────────────
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
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt4_" + ACCOUNT_ID);
   if (g_handle < 0) { Print("TRS Slave MT4: MQTT connect failed"); ExpertRemove(); return; }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) { Print("TRS Slave MT4: Subscribe failed"); ExpertRemove(); return; }
   EventSetMillisecondTimer(1);
   Print("TRS Slave MT4 online, topic=", g_topic);
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

   // ── Find existing slave ticket for this master ticket ─────────────────────
   int mapIdx = FindMap(p.ticket);

   if (mapIdx >= 0) {
      // Known ticket — check if SL/TP changed and modify
      bool slChanged = MathAbs(g_map[mapIdx].sl - p.sl) > 0.000001;
      bool tpChanged = MathAbs(g_map[mapIdx].tp - p.tp) > 0.000001;
      if (!slChanged && !tpChanged) return; // nothing changed

      int slaveTkt = g_map[mapIdx].slaveTicket;
      if (!OrderSelect(slaveTkt, SELECT_BY_TICKET)) {
         PrintFormat("TRS Slave MT4: Modify — OrderSelect failed ticket=%d err=%d", slaveTkt, GetLastError());
         return;
      }
      double newPrice = OrderOpenPrice();
      if (!OrderModify(slaveTkt, newPrice, p.sl, p.tp, 0, clrNONE)) {
         PrintFormat("TRS Slave MT4: OrderModify Error %d | ticket=%d sl=%.5f tp=%.5f",
                     GetLastError(), slaveTkt, p.sl, p.tp);
      } else {
         PrintFormat("TRS Slave MT4: Modified ticket=%d sl=%.5f tp=%.5f", slaveTkt, p.sl, p.tp);
         g_map[mapIdx].sl = p.sl;
         g_map[mapIdx].tp = p.tp;
      }
      return;
   }

   // ── New ticket — open order ───────────────────────────────────────────────
   if (!SymbolSelect(sym, true)) {
      PrintFormat("TRS Slave MT4: SymbolSelect failed for '%s'", sym);
      return;
   }
   RefreshRates();

   double price = 0;
   if      (p.order_type == OP_BUY)  price = MarketInfo(sym, MODE_ASK);
   else if (p.order_type == OP_SELL) price = MarketInfo(sym, MODE_BID);
   else                               price = p.price;

   if (price <= 0) { PrintFormat("TRS Slave MT4: No price for '%s'", sym); return; }

   int ticket = OrderSend(sym, p.order_type, p.volume, price, 3, p.sl, p.tp, "TRS", MAGIC, 0, clrNONE);
   if (ticket < 0) {
      PrintFormat("TRS Slave MT4: OrderSend Error %d | sym=%s cmd=%d lots=%.2f",
                  GetLastError(), sym, p.order_type, p.volume);
   } else {
      PrintFormat("TRS Slave MT4: Filled ticket=%d sym=%s cmd=%d lots=%.2f price=%.5f",
                  ticket, sym, p.order_type, p.volume, price);
      AddMap(p.ticket, ticket, p.sl, p.tp);
   }
}

// ── Ticket map helpers ────────────────────────────────────────────────────────

int FindMap(long masterTkt) {
   for (int i = 0; i < g_mapCount; i++)
      if (g_map[i].masterTicket == masterTkt) return i;
   return -1;
}

void AddMap(long masterTkt, int slaveTkt, double sl, double tp) {
   ArrayResize(g_map, g_mapCount + 1);
   g_map[g_mapCount].masterTicket = masterTkt;
   g_map[g_mapCount].slaveTicket  = slaveTkt;
   g_map[g_mapCount].sl           = sl;
   g_map[g_mapCount].tp           = tp;
   g_mapCount++;
}

// ── Payload deserialization ───────────────────────────────────────────────────

bool UnpackPayload(const uchar& buf[], int size, VMTradePayload& p) {
   if (size < 64) return false;
   uchar tmp8[8];

   // ticket (int64, 8 bytes)
   ArrayCopy(tmp8, buf, 0, 0, 8);
   RtlMoveMemory(p.ticket, tmp8, 8);

   // symbol (12 bytes)
   for (int i = 0; i < 12; i++) p.symbol[i] = buf[8 + i];

   // order_type (int32 LE, 4 bytes)
   p.order_type = (int)buf[20] | ((int)buf[21] << 8) | ((int)buf[22] << 16) | ((int)buf[23] << 24);

   // doubles: volume, price, sl, tp
   p.volume = ReadDouble(buf, 24);
   p.price  = ReadDouble(buf, 32);
   p.sl     = ReadDouble(buf, 40);
   p.tp     = ReadDouble(buf, 48);

   // magic (int32 LE)
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
