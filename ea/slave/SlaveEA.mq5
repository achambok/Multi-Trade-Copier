#property copyright "TRS Slave EA MT5"
#property version   "1.00"
#property strict

// Based on your telnet test, 172.16.21.1 is the Mac Host reachable from the VM
#define MQTT_HOST   "172.16.21.1" 
#define MQTT_PORT   1883
#define ACCOUNT_ID  "vm_mt5"
#define MAGIC       20240101

// Import from your Rust DLL
#import "MQTTClient.dll"
   int  MQTT_Connect(string host, int port, string clientId);
   int  MQTT_Subscribe(int handle, string topic);
   int  MQTT_Receive(int handle, uchar& buf[], int bufSize);
   void MQTT_Disconnect(int handle);
#import

// Kernel32 import for safe memory copying (casting uchar[] to double)
#import "kernel32.dll"
   void RtlMoveMemory(double &dest, uchar &src[], int length);
   void RtlMoveMemory(long &dest, uchar &src[], int length);
   void RtlMoveMemory(int &dest, uchar &src[], int length);
#import

int    g_handle     = -1;
string g_topic      = "trading/vm_slaves/" + ACCOUNT_ID;
long   g_lastTicket = 0;

struct VMTradePayload {
   long   ticket;      // 8 bytes
   uchar  symbol[12];  // 12 bytes
   int    order_type;  // 4 bytes
   double volume;      // 8 bytes
   double price;       // 8 bytes
   double sl;          // 8 bytes
   double tp;          // 8 bytes
   int    magic;       // 4 bytes
   int    pad;         // 4 bytes (Alignment)
};

int OnInit()
{
   // Connect using the verified Host IP
   g_handle = MQTT_Connect(MQTT_HOST, MQTT_PORT, "slave_mt5_" + ACCOUNT_ID);
   
   if (g_handle < 0) {
      Print("TRS Slave MT5: MQTT connect failed to ", MQTT_HOST);
      return(INIT_FAILED);
   }
   
   if (MQTT_Subscribe(g_handle, g_topic) < 0) {
      Print("TRS Slave MT5: subscribe failed to ", g_topic);
      MQTT_Disconnect(g_handle);
      return(INIT_FAILED);
   }
   
   // High frequency polling for low latency trade execution
   EventSetMillisecondTimer(10); 
   Print("TRS Slave MT5: ONLINE. Listening on: ", g_topic);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if (g_handle >= 0) MQTT_Disconnect(g_handle);
   Print("TRS Slave MT5: Offline.");
}

void OnTimer()
{
   uchar buf[128];
   ArrayInitialize(buf, 0);
   
   // Poll the Rust DLL for new messages
   int received = MQTT_Receive(g_handle, buf, 128);
   if (received <= 0) return;

   VMTradePayload p;
   if (!UnpackPayload(buf, received, p)) {
      Print("TRS Slave MT5: unpack failed, bytes=", received);
      return;
   }

   // Idempotency check: don't process the same ticket twice
   if (p.ticket == g_lastTicket) return;
   g_lastTicket = p.ticket;

   // Convert symbol uchar array to MQL string
   string sym = CharArrayToString(p.symbol, 0, -1, CP_ACP);
   StringTrimRight(sym);

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = sym;
   request.volume       = p.volume;
   request.magic        = MAGIC;
   request.comment      = "TRS Slave";
   request.type_filling = ORDER_FILLING_IOC;

   // Map integer types to MQL5 enums
   switch (p.order_type) {
      case 0: request.type = ORDER_TYPE_BUY;  request.price = SymbolInfoDouble(sym, SYMBOL_ASK); break;
      case 1: request.type = ORDER_TYPE_SELL; request.price = SymbolInfoDouble(sym, SYMBOL_BID); break;
      default:
         Print("TRS Slave MT5: Unsupported order type ", p.order_type);
         return;
   }

   request.sl = p.sl;
   request.tp = p.tp;

   if (!OrderSendAsync(request, result)) {
      PrintFormat("TRS Slave MT5: Order Error: %d", GetLastError());
   } else {
      PrintFormat("TRS Slave MT5: Executing Ticket %d | %s %0.2f", p.ticket, sym, p.volume);
   }
}

// Fixed Unpacker using RtlMoveMemory for binary safety
bool UnpackPayload(const uchar& buf[], int size, VMTradePayload& p)
{
   if (size < 60) return false; // Minimum size for the struct fields
   
   int offset = 0;
   uchar tmp8[8];
   uchar tmp4[4];

   // Ticket (Long)
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.ticket, tmp8, 8); offset += 8;
   
   // Symbol (Fixed 12 bytes)
   for(int i=0; i<12; i++) p.symbol[i] = buf[offset+i]; offset += 12;
   
   // Order Type (Int)
   ArrayCopy(tmp4, buf, 0, offset, 4); RtlMoveMemory(p.order_type, tmp4, 4); offset += 4;
   
   // Doubles (Volume, Price, SL, TP)
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.volume, tmp8, 8); offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.price, tmp8, 8);  offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.sl, tmp8, 8);     offset += 8;
   ArrayCopy(tmp8, buf, 0, offset, 8); RtlMoveMemory(p.tp, tmp8, 8);     offset += 8;
   
   // Magic (Int)
   ArrayCopy(tmp4, buf, 0, offset, 4); RtlMoveMemory(p.magic, tmp4, 4);
   
   return true;
}