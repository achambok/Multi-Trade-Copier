#property copyright "TRS Slave EA MT5"
#property version   "1.00"

#define MQTT_HOST   "172.16.21.2"
#define MQTT_PORT   1883
#define ACCOUNT_ID  "vm_mt5"
#define MAGIC       20240101

#import "MQTTClient.dll"
   int  MQTT_Connect(string host, int port, string clientId);
   int  MQTT_Subscribe(int handle, string topic);
   int  MQTT_Receive(int handle, uchar& buf[], int bufSize);
   void MQTT_Disconnect(int handle);
#import

int    g_handle   = -1;
string g_topic    = "trading/vm_slaves/" + ACCOUNT_ID;
long   g_lastTicket = 0;

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

void OnInit()
{
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt5_" + ACCOUNT_ID);
   if (g_handle < 0) {
      Print("TRS Slave MT5: MQTT connect failed");
      ExpertRemove();
      return;
   }
   if (MQTT_Subscribe(g_handle, g_topic) < 0) {
      Print("TRS Slave MT5: subscribe failed");
      ExpertRemove();
      return;
   }
   EventSetMillisecondTimer(1);
   Print("TRS Slave MT5 started, topic=", g_topic);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
}

void OnTimer()
{
   uchar buf[128];
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received <= 0) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) {
      Print("TRS Slave MT5: unpack failed, bytes=", received);
      return;
   }

   if (p.ticket == g_lastTicket) return;
   g_lastTicket = p.ticket;

   string sym = CharArrayToString(p.symbol, 0, -1, CP_ACP);
   StringTrimRight(sym);

   ENUM_ORDER_TYPE orderType;
   switch (p.order_type) {
      case 0: orderType = ORDER_TYPE_BUY;        break;
      case 1: orderType = ORDER_TYPE_SELL;       break;
      case 2: orderType = ORDER_TYPE_BUY_LIMIT;  break;
      case 3: orderType = ORDER_TYPE_SELL_LIMIT; break;
      case 4: orderType = ORDER_TYPE_BUY_STOP;   break;
      case 5: orderType = ORDER_TYPE_SELL_STOP;  break;
      default:
         PrintFormat("TRS Slave MT5: unknown order type %d", p.order_type);
         return;
   }

   double price = 0;
   if (orderType == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(sym, SYMBOL_ASK);
   else if (orderType == ORDER_TYPE_SELL)
      price = SymbolInfoDouble(sym, SYMBOL_BID);
   else
      price = p.price;

   MqlTradeRequest  request  = {};
   MqlTradeResult   result   = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = sym;
   request.volume    = p.volume;
   request.type      = orderType;
   request.price     = price;
   request.sl        = p.sl;
   request.tp        = p.tp;
   request.magic     = MAGIC;
   request.comment   = "TRS";
   request.type_filling = ORDER_FILLING_IOC;

   if (!OrderSendAsync(request, result)) {
      PrintFormat("TRS Slave MT5: OrderSendAsync failed retcode=%d err=%d sym=%s",
                  result.retcode, GetLastError(), sym);
   } else {
      PrintFormat("TRS Slave MT5: async order sent order=%d sym=%s vol=%.2f",
                  result.order, sym, p.volume);
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      PrintFormat("TRS Slave MT5: fill confirmed deal=%d order=%d sym=%s vol=%.2f price=%.5f",
                  trans.deal, trans.order, trans.symbol, trans.volume, trans.price);
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
