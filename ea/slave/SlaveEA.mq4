#property strict
#property copyright "TRS Slave EA MT4"
#property version   "1.00"

// Use .1 based on your successful telnet test
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

// Required for safe binary unpacking of doubles/longs
#import "kernel32.dll"
   void RtlMoveMemory(double &dest, uchar &src[], int length);
   void RtlMoveMemory(long &dest, uchar &src[], int length);
   void RtlMoveMemory(int &dest, uchar &src[], int length);
#import

int      g_handle   = -1;
string   g_topic    = "trading/vm_slaves/" + ACCOUNT_ID;
long     g_lastTicket = 0;

// Struct must match your Rust memory layout exactly
struct VMTradePayload {
   long   ticket;      // 8 bytes
   uchar  symbol[12];  // 12 bytes
   int    order_type;  // 4 bytes
   double volume;      // 8 bytes
   double price;       // 8 bytes
   double sl;          // 8 bytes
   double tp;          // 8 bytes
   int    magic;       // 4 bytes
   int    pad;         // 4 bytes (for 8-byte alignment)
};

int OnInit()
{
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt4_" + ACCOUNT_ID);
   if (g_handle < 0) {
      Print("TRS Slave: MQTT connect failed to ", MQTT_HOST);
      return(INIT_FAILED);
   }
   
   if (MQTT_Subscribe(g_handle, g_topic) < 0) {
      Print("TRS Slave: subscribe failed for ", g_topic);
      MQTT_Disconnect(g_handle);
      return(INIT_FAILED);
   }
   
   // 10ms is usually the sweet spot for MT4 timer stability
   EventSetMillisecondTimer(10);
   Print("TRS Slave MT4 online, topic=", g_topic);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer()
{
   uchar buf[128];
   ArrayInitialize(buf, 0);
   
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received <= 0) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) {
      Print("TRS Slave: unpack failed, bytes=", received);
      return;
   }

   // Idempotency: skip if already processed
   if (p.ticket == g_lastTicket) return;
   g_lastTicket = p.ticket;

   string sym = CharArrayToString(p.symbol, 0, -1, CP_ACP);
   StringTrimRight(sym);

   int    cmd      = p.order_type;
   double lots     = p.volume;
   double sl       = p.sl;
   double tp       = p.tp;
   int    slippage = 3;
   double price    = 0;

   // Handle Market vs Pending price logic
   if (cmd == OP_BUY) {
      price = MarketInfo(sym, MODE_ASK);
   } else if (cmd == OP_SELL) {
      price = MarketInfo(sym, MODE_BID);
   } else {
      price = p.price;
   }

   if (price <= 0) {
      Print("TRS Slave: Invalid price for ", sym);
      return;
   }

   int ticket = OrderSend(sym, cmd, lots, price, slippage, sl, tp, "TRS", MAGIC, 0, clrNONE);
   if (ticket < 0) {
      PrintFormat("TRS Slave: OrderSend Error %d | sym=%s cmd=%d", GetLastError(), sym, cmd);
   } else {
      PrintFormat("TRS Slave: Success! Ticket=%d sym=%s vol=%.2f", ticket, sym, lots);
   }
}

bool UnpackPayload(const uchar& buf[], int size, VMTradePayload& p)
{
   if (size < 60) return false;
   int offset = 0;
   uchar tmp8[8], tmp4[4];

   // Ticket
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.ticket, tmp8, 8); offset += 8;

   // Symbol
   for(int i=0; i<12; i++) p.symbol[i] = buf[offset+i]; offset += 12;

   // Order Type
   ArrayCopy(tmp4, buf, 0, offset, 4); RtlMoveMemory(p.order_type, tmp4, 4); offset += 4;

   // Doubles
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.volume, tmp8, 8); offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.price, tmp8, 8);  offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.sl, tmp8, 8);     offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.tp, tmp8, 8);     offset += 8;

   // Magic
   ArrayCopy(tmp4, buf, 0, offset, 4); RtlMoveMemory(p.magic, tmp4, 4);

   return true;
}