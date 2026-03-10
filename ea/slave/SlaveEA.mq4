#property strict
#property copyright "TRS Slave EA MT4"
#property version   "1.30"

#define MQTT_HOST   "172.16.21.1"
#define MQTT_PORT   1883
#define MAGIC       20240101

// Set this to match the slave "account_id" in relay_config.json
// e.g. vm_mt4_icmarkets
input string AccountID = "vm_mt4_icmarkets";

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
string g_topic  = "";

// ── Master→Slave ticket map ───────────────────────────────────────────────────
struct TicketMap {
   long   masterTicket;
   int    slaveTicket;
   int    order_type;   // original MT4 order type (0-5)
   double price;        // open/trigger price (for pending orders)
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
   g_topic  = "trading/vm_slaves/" + AccountID;
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt4_" + AccountID);
   if (g_handle < 0) { Print("TRS Slave MT4: MQTT connect failed"); ExpertRemove(); return; }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) { Print("TRS Slave MT4: Subscribe failed"); ExpertRemove(); return; }
   EventSetMillisecondTimer(50);
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
      int slaveTkt  = g_map[mapIdx].slaveTicket;
      int origType  = g_map[mapIdx].order_type;
      bool isPending = (origType >= 2 && origType <= 5);

      // ── Close/Delete signal ───────────────────────────────────────────────
      if (p.order_type == 10) {
         if (!OrderSelect(slaveTkt, SELECT_BY_TICKET)) {
            PrintFormat("TRS Slave MT4: Close/Delete — OrderSelect failed ticket=%d err=%d", slaveTkt, GetLastError());
            RemoveMap(mapIdx);
            return;
         }
         if (isPending) {
            if (!OrderDelete(slaveTkt, clrNONE))
               PrintFormat("TRS Slave MT4: OrderDelete Error %d | ticket=%d", GetLastError(), slaveTkt);
            else
               PrintFormat("TRS Slave MT4: Deleted pending ticket=%d sym=%s", slaveTkt, OrderSymbol());
         } else {
            double closePrice = (OrderType() == OP_BUY)
                                ? MarketInfo(OrderSymbol(), MODE_BID)
                                : MarketInfo(OrderSymbol(), MODE_ASK);
            if (!OrderClose(slaveTkt, OrderLots(), closePrice, 3, clrNONE))
               PrintFormat("TRS Slave MT4: OrderClose Error %d | ticket=%d", GetLastError(), slaveTkt);
            else
               PrintFormat("TRS Slave MT4: Closed ticket=%d sym=%s", slaveTkt, OrderSymbol());
         }
         RemoveMap(mapIdx);
         return;
      }

      // ── Modify: SL/TP and/or trigger price ───────────────────────────────
      bool slChanged    = MathAbs(g_map[mapIdx].sl    - p.sl)    > 0.000001;
      bool tpChanged    = MathAbs(g_map[mapIdx].tp    - p.tp)    > 0.000001;
      bool priceChanged = isPending && (MathAbs(g_map[mapIdx].price - p.price) > 0.000001);
      if (!slChanged && !tpChanged && !priceChanged) return;

      if (!OrderSelect(slaveTkt, SELECT_BY_TICKET)) {
         PrintFormat("TRS Slave MT4: Modify — OrderSelect failed ticket=%d err=%d", slaveTkt, GetLastError());
         return;
      }
      double modPrice = isPending ? p.price : OrderOpenPrice();
      // Normalize to broker tick size
      double tickSize = MarketInfo(OrderSymbol(), MODE_TICKSIZE);
      int    digits   = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
      if (tickSize > 0) {
         modPrice = NormalizeDouble(MathRound(modPrice / tickSize) * tickSize, digits);
         if (p.sl > 0) p.sl = NormalizeDouble(MathRound(p.sl / tickSize) * tickSize, digits);
         if (p.tp > 0) p.tp = NormalizeDouble(MathRound(p.tp / tickSize) * tickSize, digits);
      }
      if (!OrderModify(slaveTkt, modPrice, p.sl, p.tp, 0, clrNONE)) {
         PrintFormat("TRS Slave MT4: OrderModify Error %d | ticket=%d price=%.5f sl=%.5f tp=%.5f",
                     GetLastError(), slaveTkt, modPrice, p.sl, p.tp);
      } else {
         PrintFormat("TRS Slave MT4: Modified ticket=%d price=%.5f sl=%.5f tp=%.5f", slaveTkt, modPrice, p.sl, p.tp);
         g_map[mapIdx].price = modPrice;
         g_map[mapIdx].sl    = p.sl;
         g_map[mapIdx].tp    = p.tp;
      }
      return;
   }

   // ── Close/Delete signal with no mapping ──────────────────────────────────
   if (p.order_type == 10) {
      PrintFormat("TRS Slave MT4: CLOSE signal ticket=%d — no local mapping, ignoring", p.ticket);
      return;
   }

   // ── New order ─────────────────────────────────────────────────────────────
   sym = ResolveSymbol(sym);
   if (StringLen(sym) == 0) return;
   RefreshRates();

   double price = 0;
   bool isPending = (p.order_type >= 2 && p.order_type <= 5);
   if (isPending) {
      price = p.price;
   } else if (p.order_type == OP_BUY) {
      price = MarketInfo(sym, MODE_ASK);
   } else if (p.order_type == OP_SELL) {
      price = MarketInfo(sym, MODE_BID);
   } else {
      PrintFormat("TRS Slave MT4: Unknown order_type=%d, skipping", p.order_type);
      return;
   }

   if (price <= 0) { PrintFormat("TRS Slave MT4: No price for '%s'", sym); return; }

   // Normalize price, SL, TP to broker tick size to avoid ERR_INVALID_PRICE (4107)
   double tickSize = MarketInfo(sym, MODE_TICKSIZE);
   int    digits   = (int)MarketInfo(sym, MODE_DIGITS);
   if (tickSize > 0) {
      price = NormalizeDouble(MathRound(price / tickSize) * tickSize, digits);
      if (p.sl > 0) p.sl = NormalizeDouble(MathRound(p.sl / tickSize) * tickSize, digits);
      if (p.tp > 0) p.tp = NormalizeDouble(MathRound(p.tp / tickSize) * tickSize, digits);
   }

   int ticket = OrderSend(sym, p.order_type, p.volume, price, 3, p.sl, p.tp, "TRS", MAGIC, 0, clrNONE);
   if (ticket < 0) {
      PrintFormat("TRS Slave MT4: OrderSend Error %d | sym=%s cmd=%d lots=%.2f price=%.5f",
                  GetLastError(), sym, p.order_type, p.volume, price);
   } else {
      if (isPending)
         PrintFormat("TRS Slave MT4: Pending ticket=%d sym=%s cmd=%d lots=%.2f price=%.5f",
                     ticket, sym, p.order_type, p.volume, price);
      else
         PrintFormat("TRS Slave MT4: Filled ticket=%d sym=%s cmd=%d lots=%.2f price=%.5f",
                     ticket, sym, p.order_type, p.volume, price);
      AddMap(p.ticket, ticket, p.order_type, price, p.sl, p.tp);
   }
}

// ── Ticket map helpers ────────────────────────────────────────────────────────

int FindMap(long masterTkt) {
   for (int i = 0; i < g_mapCount; i++)
      if (g_map[i].masterTicket == masterTkt) return i;
   return -1;
}

void AddMap(long masterTkt, int slaveTkt, int orderType, double price, double sl, double tp) {
   ArrayResize(g_map, g_mapCount + 1);
   g_map[g_mapCount].masterTicket = masterTkt;
   g_map[g_mapCount].slaveTicket  = slaveTkt;
   g_map[g_mapCount].order_type   = orderType;
   g_map[g_mapCount].price        = price;
   g_map[g_mapCount].sl           = sl;
   g_map[g_mapCount].tp           = tp;
   g_mapCount++;
}

void RemoveMap(int idx) {
   for (int j = idx; j < g_mapCount - 1; j++) g_map[j] = g_map[j + 1];
   g_mapCount--;
   ArrayResize(g_map, g_mapCount);
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

// ResolveSymbol tries the received symbol and common broker suffix variants.
// Returns the first symbol that exists on this broker, or "" on failure.
string ResolveSymbol(string sym) {
   string stripSuffixes[6];
   stripSuffixes[0] = "m";
   stripSuffixes[1] = ".pro";
   stripSuffixes[2] = ".ecn";
   stripSuffixes[3] = ".r";
   stripSuffixes[4] = ".raw";
   stripSuffixes[5] = ".cf";

   string addSuffixes[6];
   addSuffixes[0] = "m";
   addSuffixes[1] = ".pro";
   addSuffixes[2] = ".ecn";
   addSuffixes[3] = ".r";
   addSuffixes[4] = ".raw";
   addSuffixes[5] = ".cf";

   if (SymbolSelect(sym, true) && MarketInfo(sym, MODE_ASK) > 0) return sym;

   string base = sym;
   for (int i = 0; i < 6; i++) {
      int slen = StringLen(sym);
      int sflen = StringLen(stripSuffixes[i]);
      if (slen > sflen && StringSubstr(sym, slen - sflen) == stripSuffixes[i]) {
         base = StringSubstr(sym, 0, slen - sflen);
         break;
      }
   }

   if (base != sym && SymbolSelect(base, true) && MarketInfo(base, MODE_ASK) > 0) {
      PrintFormat("TRS Slave MT4: Resolved '%s' → '%s'", sym, base);
      return base;
   }

   for (int i = 0; i < 6; i++) {
      string candidate = base + addSuffixes[i];
      if (SymbolSelect(candidate, true) && MarketInfo(candidate, MODE_ASK) > 0) {
         PrintFormat("TRS Slave MT4: Resolved '%s' → '%s'", sym, candidate);
         return candidate;
      }
   }

   PrintFormat("TRS Slave MT4: Cannot resolve symbol '%s' — not found on this broker", sym);
   return "";
}
