#property strict
#property copyright "TRS Master EA"
#property version   "1.40"

// ── EA filter inputs ──────────────────────────────────────────────────────────
// List every magic number whose trades should be copied.
// Set any unused slot to -1.  Magic 0 = standard manual trades.
input int  Magic1          = 11223388;  // THERANTO V3
input int  Magic2          = 202;       // Gold Scalping
input int  Magic3          = -1;        // spare slot
input int  Magic4          = -1;        // spare slot
input int  Magic5          = -1;        // spare slot

// Set true to ALSO copy manually-placed trades (magic = 0).
// Manual trades that carry a non-zero magic already handled by the slots above.
input bool CopyManualTrades = true;

// ── Risk / lot-sizing inputs ──────────────────────────────────────────────────
// MasterEquity : your master account equity used as the scaling denominator.
//   0 = auto (uses AccountEquity() live — recommended).
input double MasterEquity  = 0;

// RiskMode controls how slave lot sizes are calculated:
//   proportional  — slaveLot = masterLot × (slaveEquity / masterEquity)  [default]
//   percent       — slave risks RiskValue% of its equity per trade
//   fixed_lot     — every trade uses exactly RiskValue lots
//   fixed_dollars — every trade risks exactly RiskValue USD
input string RiskMode      = "proportional";

// RiskValue meaning depends on RiskMode (ignored for proportional).
//   percent       → e.g. 1.0  = 1% of slave equity
//   fixed_lot     → e.g. 0.10 = 0.10 lots always
//   fixed_dollars → e.g. 50   = risk $50 per trade
input double RiskValue     = 0;

// PublishConfig: flip to true (then back to false) to force-resend risk
// settings to the relay without restarting the EA.
input bool   PublishConfig = false;

#import "mt4_bridge.dll"
   int  bridge_init();
   void bridge_shutdown();
   int  send_trade_event(
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
   int  send_config_event(uchar& json[], int json_len);
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
int        g_snapshot_count  = 0;
int        g_magic_filter[];
int        g_filter_count    = 0;
bool       g_lastPublishCfg  = false;   // tracks PublishConfig toggle state

// ─────────────────────────────────────────────────────────────────────────────

void OnInit()
{
   if (bridge_init() != 0) {
      Print("TRS: bridge_init failed — is Mosquitto running?");
      ExpertRemove();
      return;
   }

   // Build filter array from inputs (skip -1 sentinels)
   int inputs[5];
   inputs[0] = Magic1;
   inputs[1] = Magic2;
   inputs[2] = Magic3;
   inputs[3] = Magic4;
   inputs[4] = Magic5;
   g_filter_count = 0;
   ArrayResize(g_magic_filter, 0);
   for (int i = 0; i < 5; i++) {
      if (inputs[i] >= 0) {
         ArrayResize(g_magic_filter, g_filter_count + 1);
         g_magic_filter[g_filter_count++] = inputs[i];
      }
   }

   EventSetMillisecondTimer(10);
   SnapshotOrders();
   PublishRiskConfig();

   string filterStr = "";
   for (int i = 0; i < g_filter_count; i++)
      filterStr += (i > 0 ? ", " : "") + IntegerToString(g_magic_filter[i]);
   PrintFormat("TRS: Master EA v1.40 started | EA magic filters: [%s] | CopyManual: %s | RiskMode: %s | RiskValue: %.4f",
               filterStr, CopyManualTrades ? "ON" : "OFF", RiskMode, RiskValue);
}

void OnDeinit(const int reason) { EventKillTimer(); bridge_shutdown(); }
void OnTrade()                  { ScanAndPublish(); }
void OnTimer() {
   // Detect PublishConfig toggle (flip true → triggers resend)
   if (PublishConfig && !g_lastPublishCfg) {
      PublishRiskConfig();
      Print("TRS: Risk config republished");
   }
   g_lastPublishCfg = PublishConfig;
   ScanAndPublish();
}

// ── Publish risk config to relay via trading/config ───────────────────────────
void PublishRiskConfig()
{
   double equity = (MasterEquity > 0) ? MasterEquity : AccountEquity();
   string json = StringFormat(
      "{\"master_equity\":%.2f,\"risk_mode\":\"%s\",\"risk_value\":%.4f}",
      equity, RiskMode, RiskValue
   );
   uchar arr[];
   int len = StringToCharArray(json, arr, 0, StringLen(json));
   int res = send_config_event(arr, len);
   if (res == 0)
      PrintFormat("TRS: Config published → equity=%.2f mode=%s value=%.4f", equity, RiskMode, RiskValue);
   else
      PrintFormat("TRS: Config publish failed (err=%d)", res);
}

// ─────────────────────────────────────────────────────────────────────────────

bool IsMagicWatched(int magic)
{
   // Magic 0 = manual trade
   if (magic == 0) return CopyManualTrades;

   for (int i = 0; i < g_filter_count; i++)
      if (g_magic_filter[i] == magic) return true;

   return false;
}

string SourceLabel(int magic)
{
   if (magic == 0)          return "MANUAL";
   if (magic == 11223388)   return "THERANTO V3";
   if (magic == 202)        return "Gold Scalping";
   return "EA#" + IntegerToString(magic);
}

void ScanAndPublish()
{
   int total = OrdersTotal();
   for (int i = 0; i < total; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;

      int magic = OrderMagicNumber();
      if (!IsMagicWatched(magic)) continue;

      long   ticket = OrderTicket();
      int    otype  = OrderType();
      double volume = OrderLots();
      double price  = OrderOpenPrice();
      double sl     = OrderStopLoss();
      double tp     = OrderTakeProfit();
      string sym    = OrderSymbol();

      if (!IsChangedOrNew(ticket, otype, volume, price, sl, tp, magic)) continue;

      uchar sym_arr[12];
      ArrayInitialize(sym_arr, 0);
      StringToCharArray(sym, sym_arr, 0, MathMin(StringLen(sym), 11));

      int res = send_trade_event(ticket, sym_arr, otype, volume, price, sl, tp, magic, 0);
      if (res == 0) {
         UpdateSnapshot(ticket, otype, volume, price, sl, tp, magic);
         PrintFormat("TRS: [%s] published ticket=%d sym=%s type=%d lots=%.2f sl=%.5f tp=%.5f",
                     SourceLabel(magic), ticket, sym, otype, volume, sl, tp);
      } else {
         PrintFormat("TRS: publish error %d for ticket=%d — reconnecting next tick", res, ticket);
      }
   }

   PruneClosedTickets();
}

// ─────────────────────────────────────────────────────────────────────────────

bool IsChangedOrNew(long ticket, int otype, double volume, double price,
                    double sl, double tp, int magic)
{
   for (int i = 0; i < g_snapshot_count; i++) {
      if (g_snapshot[i].ticket != ticket) continue;
      if (g_snapshot[i].order_type == otype                   &&
          MathAbs(g_snapshot[i].volume - volume) < 0.00001    &&
          MathAbs(g_snapshot[i].price  - price)  < 0.00001    &&
          MathAbs(g_snapshot[i].sl     - sl)     < 0.000001   &&
          MathAbs(g_snapshot[i].tp     - tp)     < 0.000001)
         return false;
      return true;
   }
   return true;
}

void UpdateSnapshot(long ticket, int otype, double volume, double price,
                    double sl, double tp, int magic)
{
   for (int i = 0; i < g_snapshot_count; i++) {
      if (g_snapshot[i].ticket != ticket) continue;
      g_snapshot[i].order_type = otype;
      g_snapshot[i].volume     = volume;
      g_snapshot[i].price      = price;
      g_snapshot[i].sl         = sl;
      g_snapshot[i].tp         = tp;
      g_snapshot[i].magic      = magic;
      return;
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

// order_type sentinel used for close signals (above all MT4 OP_ values 0-5)
#define OP_CLOSE 10

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
         // Publish close signal before removing from snapshot
         uchar sym_arr[12];
         ArrayInitialize(sym_arr, 0);
         string sym = "";
         if (OrderSelect((int)g_snapshot[s].ticket, SELECT_BY_TICKET, MODE_HISTORY))
            sym = OrderSymbol();
         StringToCharArray(sym, sym_arr, 0, MathMin(StringLen(sym), 11));

         int res = send_trade_event(g_snapshot[s].ticket, sym_arr, OP_CLOSE,
                                    g_snapshot[s].volume, g_snapshot[s].price,
                                    0, 0, g_snapshot[s].magic, 0);
         if (res == 0)
            PrintFormat("TRS: [%s] CLOSE published ticket=%d sym=%s",
                        SourceLabel(g_snapshot[s].magic), g_snapshot[s].ticket, sym);
         else
            PrintFormat("TRS: CLOSE publish error %d ticket=%d", res, g_snapshot[s].ticket);

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
      int magic = OrderMagicNumber();
      if (!IsMagicWatched(magic)) continue;
      UpdateSnapshot(OrderTicket(), OrderType(), OrderLots(), OrderOpenPrice(),
                     OrderStopLoss(), OrderTakeProfit(), magic);
   }
}
