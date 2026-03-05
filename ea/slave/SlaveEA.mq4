#property strict
#property copyright "TRS Slave EA MT4"
#property version   "1.00"

#define MQTT_HOST   "172.16.21.2"
#define MQTT_PORT   1883
#define ACCOUNT_ID  "vm_mt4"
#define MAGIC       20240101

#import "MQTTClient.dll"
   int  MQTT_Connect(string host, int port, string clientId);
   int  MQTT_Subscribe(int handle, string topic);
   int  MQTT_Receive(int handle, uchar& buf[], int bufSize);
   void MQTT_Disconnect(int handle);
#import

int      g_handle   = -1;
string   g_topic    = "trading/vm_slaves/" + ACCOUNT_ID;
long     g_lastTicket = 0;

#pragma pack(1)
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
#pragma pack()

void OnInit()
{
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt4_" + ACCOUNT_ID);
   if (g_handle < 0) {
      Print("TRS Slave: MQTT connect failed handle=", g_handle);
      ExpertRemove();
      return;
   }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) {
      Print("TRS Slave: subscribe failed");
      ExpertRemove();
      return;
   }
   EventSetMillisecondTimer(1);
   Print("TRS Slave MT4 started, topic=", g_topic);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer()
{
   uchar buf[128];
   int   received = MQTT_Receive(g_handle, buf, 128);
   if (received <= 0) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) {
      Print("TRS Slave: unpack failed, bytes=", received);
      return;
   }

   if (p.ticket == g_lastTicket) return;
   g_lastTicket = p.ticket;

   string sym = CharArrayToString(p.symbol, 0, -1, CP_ACP);
   StringTrimRight(sym);

   int    cmd     = p.order_type;
   double lots    = p.volume;
   double price   = 0;
   double sl      = p.sl;
   double tp      = p.tp;
   int    slippage = 3;

   if (cmd == OP_BUY) {
      price = MarketInfo(sym, MODE_ASK);
   } else if (cmd == OP_SELL) {
      price = MarketInfo(sym, MODE_BID);
   } else {
      price = p.price;
   }

   int ticket = OrderSend(sym, cmd, lots, price, slippage, sl, tp, "TRS", MAGIC, 0, clrNONE);
   if (ticket < 0) {
      PrintFormat("TRS Slave: OrderSend failed err=%d sym=%s cmd=%d lots=%.2f", GetLastError(), sym, cmd, lots);
   } else {
      PrintFormat("TRS Slave: order placed ticket=%d sym=%s cmd=%d lots=%.2f", ticket, sym, cmd, lots);
   }
}

bool UnpackPayload(const uchar& buf[], int size, VMTradePayload& p)
{
   if (size < 64) return false;
   int offset = 0;

   p.ticket = 0;
   for (int i = 0; i < 8; i++)
      p.ticket |= ((long)buf[offset + i]) << (i * 8);
   offset += 8;

   for (int i = 0; i < 12; i++)
      p.symbol[i] = buf[offset + i];
   offset += 12;

   p.order_type = 0;
   for (int i = 0; i < 4; i++)
      p.order_type |= ((int)buf[offset + i]) << (i * 8);
   offset += 4;

   p.volume = ReadDouble(buf, offset); offset += 8;
   p.price  = ReadDouble(buf, offset); offset += 8;
   p.sl     = ReadDouble(buf, offset); offset += 8;
   p.tp     = ReadDouble(buf, offset); offset += 8;

   p.magic = 0;
   for (int i = 0; i < 4; i++)
      p.magic |= ((int)buf[offset + i]) << (i * 8);

   return true;
}

double ReadDouble(const uchar& buf[], int offset)
{
   uchar raw[8];
   for (int i = 0; i < 8; i++) raw[i] = buf[offset + i];
   double result;
   RtlMoveMemory(result, raw[0], 8);
   return result;
}
