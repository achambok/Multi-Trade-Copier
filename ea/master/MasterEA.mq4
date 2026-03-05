#property strict
#property copyright "TRS Master EA"
#property version   "1.00"

#import "mt4_bridge.dll"
   int bridge_init();
   void bridge_shutdown();
   int send_trade_event(
      long   ticket,
      uchar& symbol[],
      int    order_type,
      double volume,
      double price,
      double sl,
      double tp,
      int    magic,
      int    pad
   );
#import

struct TradeState {
   long   ticket;
   int    order_type;
   double volume;
   double price;
   double sl;
   double tp;
   int    magic;
};

TradeState g_snapshot[];
int        g_snapshot_count = 0;

void OnInit()
{
   if (bridge_init() != 0) {
      Print("TRS: bridge_init failed");
      ExpertRemove();
      return;
   }
   EventSetMillisecondTimer(10);
   SnapshotOrders();
   Print("TRS: Master EA started");
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   bridge_shutdown();
}

void OnTrade()
{
   ScanAndPublish();
}

void OnTimer()
{
   ScanAndPublish();
}

void ScanAndPublish()
{
   int total = OrdersTotal();
   for (int i = 0; i < total; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      long   ticket     = OrderTicket();
      int    otype      = OrderType();
      double volume     = OrderLots();
      double price      = OrderOpenPrice();
      double sl         = OrderStopLoss();
      double tp         = OrderTakeProfit();
      int    magic      = OrderMagicNumber();
      string sym        = OrderSymbol();

      if (!IsChangedOrNew(ticket, otype, volume, price, sl, tp, magic)) continue;

      uchar symbol_arr[12];
      ArrayInitialize(symbol_arr, 0);
      StringToCharArray(sym, symbol_arr, 0, MathMin(StringLen(sym), 11));

      int res = send_trade_event(ticket, symbol_arr, otype, volume, price, sl, tp, magic, 0);
      if (res == 0) {
         UpdateSnapshot(ticket, otype, volume, price, sl, tp, magic);
         PrintFormat("TRS: published ticket=%d sym=%s type=%d lots=%.2f", ticket, sym, otype, volume);
      } else {
         PrintFormat("TRS: publish error %d for ticket=%d", res, ticket);
      }
   }

   PruneClosedTickets();
}

bool IsChangedOrNew(long ticket, int otype, double volume, double price, double sl, double tp, int magic)
{
   for (int i = 0; i < g_snapshot_count; i++) {
      if (g_snapshot[i].ticket == ticket) {
         if (g_snapshot[i].order_type == otype &&
             MathAbs(g_snapshot[i].volume - volume) < 0.00001 &&
             MathAbs(g_snapshot[i].price  - price)  < 0.00001 &&
             MathAbs(g_snapshot[i].sl     - sl)      < 0.00001 &&
             MathAbs(g_snapshot[i].tp     - tp)      < 0.00001)
            return false;
         return true;
      }
   }
   return true;
}

void UpdateSnapshot(long ticket, int otype, double volume, double price, double sl, double tp, int magic)
{
   for (int i = 0; i < g_snapshot_count; i++) {
      if (g_snapshot[i].ticket == ticket) {
         g_snapshot[i].order_type = otype;
         g_snapshot[i].volume     = volume;
         g_snapshot[i].price      = price;
         g_snapshot[i].sl         = sl;
         g_snapshot[i].tp         = tp;
         g_snapshot[i].magic      = magic;
         return;
      }
   }
   ArrayResize(g_snapshot, g_snapshot_count + 1);
   g_snapshot[g_snapshot_count].ticket     = ticket;
   g_snapshot[g_snapshot_count].order_type = otype;
   g_snapshot[g_snapshot_count].volume     = volume;
   g_snapshot[g_snapshot_count].price      = price;
   g_snapshot[g_snapshot_count].sl         = sl;
   g_snapshot[g_snapshot_count].tp         = tp;
   g_snapshot[g_snapshot_count].magic      = magic;
   g_snapshot_count++;
}

void PruneClosedTickets()
{
   int total = OrdersTotal();
   for (int s = g_snapshot_count - 1; s >= 0; s--) {
      bool found = false;
      for (int i = 0; i < total; i++) {
         if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if (OrderTicket() == g_snapshot[s].ticket) { found = true; break; }
      }
      if (!found) {
         for (int j = s; j < g_snapshot_count - 1; j++)
            g_snapshot[j] = g_snapshot[j + 1];
         g_snapshot_count--;
         ArrayResize(g_snapshot, g_snapshot_count);
      }
   }
}

void SnapshotOrders()
{
   g_snapshot_count = 0;
   ArrayResize(g_snapshot, 0);
   int total = OrdersTotal();
   for (int i = 0; i < total; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      UpdateSnapshot(OrderTicket(), OrderType(), OrderLots(), OrderOpenPrice(),
                     OrderStopLoss(), OrderTakeProfit(), OrderMagicNumber());
   }
}
