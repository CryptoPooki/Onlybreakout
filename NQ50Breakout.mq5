//+------------------------------------------------------------------+
//| NQ50Breakout.mq5                                                 |
//| 50-bar breakout, long and short, exit at the next bar open.     |
//|                                                                  |
//| Market:    NASDAQ index (US100, NQ, or the broker's symbol)     |
//| Session:   24 hours, no clock filter                             |
//| Long:      buy stop at the highest high of the last 50 bars      |
//| Short:     sell stop at the lowest low of the last 50 bars       |
//| Exit:      close at the next signal bar's open                  |
//| Stop loss: 1000 account currency per trade                      |
//| Cap:       2 entries per day                                     |
//|                                                                  |
//| The channel uses the last 50 closed bars of the signal timeframe.|
//| The forming bar is not included. A gap through a level fills    |
//| at the market.                                                   |
//| A fill cancels the opposite stop. The cash stop can close the   |
//| trade before the next bar. A stopped-out trade is not re-entered |
//| until the following bar.                                         |
//|                                                                  |
//| Test on the signal timeframe or lower (M1 is fine). Use         |
//| 1-minute OHLC or real ticks so stops can fill inside the bar.   |
//+------------------------------------------------------------------+
#property copyright "Onlybreakout"
#property version   "1.01"
#property description "50-bar breakout. Buy stop at the channel high, sell stop at the channel low."
#property description "Exit at the next bar open. Stop is 1000 account currency. Max 2 entries per day."

#include <Trade/Trade.mqh>

input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M30; // Signal timeframe
input int    InpLookback           = 50;      // Closed bars in the channel
input double InpStopLossMoney      = 1000.0;  // Stop loss per trade, account currency
input int    InpMaxEntriesPerDay   = 2;       // Max entries per day
input int    InpDayResetHour       = 0;       // Day starts at this hour, server time

input group "=== Trade ==="
input double InpLots               = 1.0;     // Volume, lots
input ulong  InpMagic              = 50302026;
input int    InpSlippageTicks      = 10;      // Max slippage, ticks
input bool   InpRemoveStopsOnRemove = true;   // Delete resting stops when the EA is removed

CTrade            g_trade;
ENUM_TIMEFRAMES   g_tf = PERIOD_M30;
datetime g_ordersBar       = 0;
datetime g_seenBar         = 0;
datetime g_capLoggedDay    = 0;
string   g_lastLog         = "";
bool     g_loggedRisk      = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLookback < 2 || InpStopLossMoney <= 0.0 || InpMaxEntriesPerDay < 1 || InpLots <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpDayResetHour < 0 || InpDayResetHour > 23)
      return INIT_PARAMETERS_INCORRECT;
   g_tf = (InpTimeframe == PERIOD_CURRENT) ? Period() : InpTimeframe;
   if(PeriodSeconds(g_tf) <= 0)
   {
      Print("Signal timeframe is not a candle period.");
      return INIT_PARAMETERS_INCORRECT;
   }
   // The tester builds the signal bars from the chart period. A higher chart cannot.
   if(PeriodSeconds(Period()) > PeriodSeconds(g_tf))
   {
      Print("Signal timeframe is ", EnumToString(g_tf),
            ". Run the test on ", EnumToString(g_tf),
            " or a lower timeframe. Current period is ", EnumToString(Period()), ".");
      return INIT_FAILED;
   }
   if(Period() != g_tf)
      Print("Chart is ", EnumToString(Period()), ". Entries and exits follow ", EnumToString(g_tf), " bars.");

   g_ordersBar = 0;
   g_seenBar = 0;
   g_capLoggedDay = 0;
   g_lastLog = "";
   g_loggedRisk = false;
   ConfigureTrade();

   Print("NQ50Breakout on ", _Symbol,
         ". Channel ", InpLookback,
         " ", EnumToString(g_tf), " bars, stop ", DoubleToString(InpStopLossMoney, 2),
         " account currency, max ", InpMaxEntriesPerDay,
         " entries/day, day resets at ", IntegerToString(InpDayResetHour),
         ":00 server time. 24-hour session.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   ObjectDelete(0, "NQ50_High");
   ObjectDelete(0, "NQ50_Low");
   if(InpRemoveStopsOnRemove)
      DeleteOurPendings();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   // One position at a time: the opposite breakout stop is cancelled as soon as this one fills.
   DeleteOurPendings();
}

//+------------------------------------------------------------------+
void OnTick()
{
   const datetime bar = iTime(_Symbol, g_tf, 0);
   if(bar <= 0)
      return;

   if(bar != g_seenBar)
   {
      g_seenBar = bar;
      g_lastLog = "";
   }

   ConfigureTrade();
   CloseIfHeldFromPriorBar(bar);

   if(HasOurPosition())
   {
      DeleteOurPendings();
      EnsurePositionStop();
      if(PositionOpenedThisBar(bar))
         g_ordersBar = bar;
      UpdateComment(bar);
      return;
   }

   if(EntriesToday() >= InpMaxEntriesPerDay)
   {
      DeleteOurPendings();
      g_ordersBar = bar;
      if(g_capLoggedDay != DayStart(TimeCurrent()))
      {
         g_capLoggedDay = DayStart(TimeCurrent());
         Print("NQ50 entry cap reached (", InpMaxEntriesPerDay, "). No new entries until the next day.");
      }
      UpdateComment(bar);
      return;
   }

   // Orders for this bar are already working, or this bar already took its entry.
   // A stop-out does not open a replacement until the next bar.
   if(g_ordersBar == bar)
   {
      UpdateComment(bar);
      return;
   }

   bool retry = true;
   RefreshBreakoutOrders(retry);
   if(!retry)
      g_ordersBar = bar;

   UpdateComment(bar);
}

//+------------------------------------------------------------------+
void ConfigureTrade()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   const double tick = TickSize();
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int deviation = InpSlippageTicks;
   if(tick > 0.0 && point > 0.0)
      deviation = (int)MathRound(InpSlippageTicks * tick / point);
   if(deviation < 1)
      deviation = 1;
   g_trade.SetDeviationInPoints(deviation);

   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = InpDayResetHour;
   dt.min = 0;
   dt.sec = 0;
   datetime start = StructToTime(dt);
   if(start > t)
      start -= 86400;
   return start;
}

//+------------------------------------------------------------------+
int DigitsSym()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

//+------------------------------------------------------------------+
double TickSize()
{
   const double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0)
      return tick;
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
double NormPrice(const double price)
{
   const double tick = TickSize();
   const int digits = DigitsSym();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathRound(price / tick) * tick, digits);
}

//+------------------------------------------------------------------+
double CeilTick(const double price)
{
   const double tick = TickSize();
   const int digits = DigitsSym();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathCeil(price / tick - 1e-8) * tick, digits);
}

//+------------------------------------------------------------------+
double FloorTick(const double price)
{
   const double tick = TickSize();
   const int digits = DigitsSym();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathFloor(price / tick + 1e-8) * tick, digits);
}

//+------------------------------------------------------------------+
// Nearest valid buy-stop price: strictly above the ask, and outside the broker stop level.
double MinBuyStop()
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double tick = TickSize();
   const double minDist = MinStopDistance();
   double raw = ask + minDist;
   if(raw <= ask)
      raw = ask + tick * 0.01;
   double price = CeilTick(raw);
   if(price <= ask)
      price = CeilTick(ask + tick);
   return price;
}

//+------------------------------------------------------------------+
// Nearest valid sell-stop price: strictly below the bid, and outside the broker stop level.
double MaxSellStop()
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double tick = TickSize();
   const double minDist = MinStopDistance();
   double raw = bid - minDist;
   if(raw >= bid)
      raw = bid - tick * 0.01;
   double price = FloorTick(raw);
   if(price >= bid)
      price = FloorTick(bid - tick);
   return price;
}

//+------------------------------------------------------------------+
double MinStopDistance()
{
   const int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops <= 0)
      return 0.0;
   return stops * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
double NormalizedLots()
{
   double lots = InpLots;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0)
      minLot = 0.01;
   if(lots < minLot)
      lots = minLot;
   if(maxLot > 0.0 && lots > maxLot)
      lots = maxLot;
   if(step > 0.0)
   {
      lots = MathFloor(lots / step + 1e-8) * step;
      if(lots < minLot)
         lots = minLot;
   }
   return NormalizeDouble(lots, 8);
}

//+------------------------------------------------------------------+
double MoneyStopDistance(const ENUM_ORDER_TYPE side)
{
   const double tick = TickSize();
   const double lots = NormalizedLots();
   if(tick <= 0.0 || lots <= 0.0 || InpStopLossMoney <= 0.0)
      return 0.0;

   double price = (side == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      price = SymbolInfoDouble(_Symbol, SYMBOL_LAST);
   if(price <= 0.0)
      return 0.0;

   const double close = (side == ORDER_TYPE_BUY) ? price - tick : price + tick;
   double profit = 0.0;
   if(OrderCalcProfit(side, _Symbol, lots, price, close, profit) && profit != 0.0)
      return (InpStopLossMoney / MathAbs(profit)) * tick;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0.0)
      return 0.0;
   return (InpStopLossMoney / (tickValue * lots)) * tick;
}

//+------------------------------------------------------------------+
void LogRiskOnce(const ENUM_ORDER_TYPE side)
{
   if(g_loggedRisk)
      return;
   const double dist = MoneyStopDistance(side);
   if(dist <= 0.0)
      return;
   g_loggedRisk = true;
   const double tick = TickSize();
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   Print("NQ50 risk check. Tick ", DoubleToString(tick, DigitsSym()),
         ", tick value ", DoubleToString(tickValue, 2),
         " per lot. Volume ", DoubleToString(NormalizedLots(), 2),
         ". A ", DoubleToString(InpStopLossMoney, 2),
         " stop is ", DoubleToString(dist, DigitsSym()),
         " price units (", DoubleToString(dist / tick, 1), " ticks). ",
         "Account currency: ", AccountInfoString(ACCOUNT_CURRENCY), ".");
}

//+------------------------------------------------------------------+
bool StopPriceFor(const ENUM_ORDER_TYPE side, const double entry, double &sl)
{
   const double dist = MoneyStopDistance(side);
   if(dist <= 0.0)
      return false;

   sl = (side == ORDER_TYPE_BUY) ? NormPrice(entry - dist) : NormPrice(entry + dist);
   if(side == ORDER_TYPE_BUY && sl >= entry)
      return false;
   if(side == ORDER_TYPE_SELL && sl <= entry)
      return false;

   const double minDist = MinStopDistance();
   if(minDist > 0.0 && MathAbs(entry - sl) + TickSize() * 0.5 < minDist)
   {
      LogOnce("Stop of " + DoubleToString(InpStopLossMoney, 2)
              + " is inside the broker minimum stop distance. No order sent.");
      return false;
   }
   LogRiskOnce(side);
   return true;
}

//+------------------------------------------------------------------+
bool Channel(double &hh, double &ll)
{
   if(Bars(_Symbol, g_tf) < InpLookback + 1)
      return false;
   const int hi = iHighest(_Symbol, g_tf, MODE_HIGH, InpLookback, 1);
   const int lo = iLowest(_Symbol, g_tf, MODE_LOW, InpLookback, 1);
   if(hi < 0 || lo < 0)
      return false;
   hh = iHigh(_Symbol, g_tf, hi);
   ll = iLow(_Symbol, g_tf, lo);
   return (hh > ll && hh > 0.0 && ll > 0.0);
}

//+------------------------------------------------------------------+
int EntriesToday()
{
   const datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent()))
      return 0;

   int count = 0;
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      const long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type == DEAL_TYPE_BUY || type == DEAL_TYPE_SELL)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int OurPositions(ulong &tickets[])
{
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      const int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
   }
   return ArraySize(tickets);
}

//+------------------------------------------------------------------+
int OurOrders(ulong &tickets[], const int typeFilter)
{
   ArrayResize(tickets, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(typeFilter >= 0 && (int)OrderGetInteger(ORDER_TYPE) != typeFilter)
         continue;
      const int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
   }
   return ArraySize(tickets);
}

//+------------------------------------------------------------------+
bool HasOurPosition()
{
   ulong tickets[];
   return (OurPositions(tickets) > 0);
}

//+------------------------------------------------------------------+
bool PositionOpenedThisBar(const datetime barOpen)
{
   ulong tickets[];
   if(OurPositions(tickets) == 0)
      return false;
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         return false;
      if((datetime)PositionGetInteger(POSITION_TIME) < barOpen)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void DeleteOurPendings()
{
   ulong tickets[];
   OurOrders(tickets, -1);
   for(int i = 0; i < ArraySize(tickets); i++)
      g_trade.OrderDelete(tickets[i]);
}

//+------------------------------------------------------------------+
ulong FindPending(const ENUM_ORDER_TYPE type)
{
   ulong tickets[];
   const int n = OurOrders(tickets, type);
   if(n == 0)
      return 0;
   for(int i = 1; i < n; i++)
      g_trade.OrderDelete(tickets[i]);
   return tickets[0];
}

//+------------------------------------------------------------------+
void CloseIfHeldFromPriorBar(const datetime barOpen)
{
   ulong tickets[];
   OurPositions(tickets);
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) >= barOpen)
         continue;
      if(g_trade.PositionClose(tickets[i]))
         Print("NQ50 exit at ", EnumToString(g_tf), " open. Ticket ", (string)tickets[i],
               " price ", DoubleToString(g_trade.ResultPrice(), DigitsSym()));
      else
         LogOnce("Exit failed ticket " + (string)tickets[i] + ": " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void EnsurePositionStop()
{
   ulong tickets[];
   OurPositions(tickets);
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      if(PositionGetDouble(POSITION_SL) > 0.0)
         continue;

      const bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const ENUM_ORDER_TYPE side = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double sl = 0.0;
      if(!StopPriceFor(side, PositionGetDouble(POSITION_PRICE_OPEN), sl))
         continue;
      if(!g_trade.PositionModify(tickets[i], sl, 0.0))
         LogOnce("Could not attach the cash stop: " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
bool IsTransient(const uint ret)
{
   return (ret == 0
        || ret == TRADE_RETCODE_REQUOTE
        || ret == TRADE_RETCODE_REJECT
        || ret == TRADE_RETCODE_TIMEOUT
        || ret == TRADE_RETCODE_PRICE_CHANGED
        || ret == TRADE_RETCODE_PRICE_OFF
        || ret == TRADE_RETCODE_TOO_MANY_REQUESTS
        || ret == TRADE_RETCODE_CONNECTION
        || ret == TRADE_RETCODE_TRADE_DISABLED
        || ret == TRADE_RETCODE_MARKET_CLOSED
        || ret == TRADE_RETCODE_FROZEN
        || ret == TRADE_RETCODE_SERVER_DISABLES_AT);
}

//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   return (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL);
}

//+------------------------------------------------------------------+
bool SendMarket(const ENUM_ORDER_TYPE side, bool &retry)
{
   retry = false;
   const bool isBuy = (side == ORDER_TYPE_BUY);
   const double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0;
   if(price <= 0.0 || !StopPriceFor(side, price, sl))
   {
      retry = (price <= 0.0);
      return false;
   }

   const double lots = NormalizedLots();
   const bool ok = isBuy ? g_trade.Buy(lots, _Symbol, 0.0, sl, 0.0, "NQ50 market")
                         : g_trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "NQ50 market");
   if(ok)
   {
      Print("NQ50 market ", (isBuy ? "buy" : "sell"),
            " at ", DoubleToString(g_trade.ResultPrice() > 0.0 ? g_trade.ResultPrice() : price, DigitsSym()),
            " SL ", DoubleToString(sl, DigitsSym()),
            ". Level was already through at the bar open.");
      return true;
   }

   retry = IsTransient(g_trade.ResultRetcode());
   LogOnce("NQ50 market entry failed: " + g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
bool EnsureStop(const ENUM_ORDER_TYPE type, const double level, bool &retry)
{
   retry = false;
   const bool isBuy = (type == ORDER_TYPE_BUY_STOP);
   const double price = NormPrice(level);
   const bool tooClose = isBuy ? (price < MinBuyStop()) : (price > MaxSellStop());
   if(tooClose)
   {
      ulong stale[];
      const int n = OurOrders(stale, type);
      for(int i = 0; i < n; i++)
         g_trade.OrderDelete(stale[i]);
      LogOnce((isBuy ? "Buy" : "Sell") + StringFormat(" stop %s is inside the broker minimum distance. Skipped this bar.",
                                                       DoubleToString(price, DigitsSym())));
      return true;
   }

   const ENUM_ORDER_TYPE side = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double sl = 0.0;
   if(!StopPriceFor(side, price, sl))
      return true;

   const double lots = NormalizedLots();
   ulong ticket = FindPending(type);
   if(ticket != 0 && OrderSelect(ticket))
   {
      const double curVol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(MathAbs(curVol - lots) > 1e-8)
      {
         g_trade.OrderDelete(ticket);
         ticket = 0;
      }
   }

   if(ticket == 0)
   {
      const bool ok = isBuy ? g_trade.BuyStop(lots, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "NQ50 buy stop")
                            : g_trade.SellStop(lots, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "NQ50 sell stop");
      if(ok)
      {
         Print("NQ50 ", (isBuy ? "buy" : "sell"), " stop at ", DoubleToString(price, DigitsSym()),
               " SL ", DoubleToString(sl, DigitsSym()));
         return true;
      }
      retry = IsTransient(g_trade.ResultRetcode());
      LogOnce("NQ50 stop failed: " + g_trade.ResultRetcodeDescription()
              + " price " + DoubleToString(price, DigitsSym())
              + " SL " + DoubleToString(sl, DigitsSym()));
      return false;
   }

   if(!OrderSelect(ticket))
   {
      retry = true;
      return false;
   }
   const double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   const double curSl = OrderGetDouble(ORDER_SL);
   if(MathAbs(curPrice - price) < TickSize() * 0.5 && MathAbs(curSl - sl) < TickSize() * 0.5)
      return true;

   if(g_trade.OrderModify(ticket, price, sl, 0.0, ORDER_TIME_GTC, 0))
      return true;

   retry = IsTransient(g_trade.ResultRetcode());
   LogOnce("NQ50 stop modify failed: " + g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
void RefreshBreakoutOrders(bool &retry)
{
   retry = false;
   if(!TradingAllowed())
   {
      retry = true;
      LogOnce("AutoTrading is off, or the symbol is not in full trade mode.");
      return;
   }

   double hh = 0.0, ll = 0.0;
   if(!Channel(hh, ll))
   {
      retry = true;
      LogOnce("Waiting for " + IntegerToString(InpLookback) + " closed " + EnumToString(g_tf) + " bars.");
      return;
   }

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      retry = true;
      LogOnce("Waiting for a bid and ask.");
      return;
   }

   const double buyLevel = NormPrice(hh);
   const double sellLevel = NormPrice(ll);
   const bool buyThrough = (ask >= buyLevel);
   const bool sellThrough = (bid <= sellLevel);

   if(buyThrough && sellThrough)
   {
      DeleteOurPendings();
      LogOnce("Bid/ask is through both channel edges. No entry this bar.");
      return;
   }

   if(buyThrough || sellThrough)
   {
      DeleteOurPendings();
      SendMarket(buyThrough ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, retry);
      return;
   }

   bool buyRetry = false;
   bool sellRetry = false;
   EnsureStop(ORDER_TYPE_BUY_STOP, buyLevel, buyRetry);
   // A buy stop can fill before the sell stop is sent. Do not rest the other side once we are in.
   if(!HasOurPosition())
      EnsureStop(ORDER_TYPE_SELL_STOP, sellLevel, sellRetry);
   if(HasOurPosition())
      DeleteOurPendings();
   retry = buyRetry || sellRetry;
}

//+------------------------------------------------------------------+
void DrawLevel(const string name, const double price, const color clr, const string text)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, text);
}

//+------------------------------------------------------------------+
string PositionText()
{
   ulong tickets[];
   if(OurPositions(tickets) == 0)
      return "flat";
   if(!PositionSelectByTicket(tickets[0]))
      return "flat";
   const string side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "long" : "short";
   return side
        + " " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), DigitsSym())
        + "  SL " + DoubleToString(PositionGetDouble(POSITION_SL), DigitsSym());
}

//+------------------------------------------------------------------+
void UpdateComment(const datetime bar)
{
   double hh = 0.0, ll = 0.0;
   const bool haveChannel = Channel(hh, ll);
   if(haveChannel)
   {
      DrawLevel("NQ50_High", hh, clrDodgerBlue, "50-bar high");
      DrawLevel("NQ50_Low", ll, clrOrangeRed, "50-bar low");
   }
   else
   {
      ObjectDelete(0, "NQ50_High");
      ObjectDelete(0, "NQ50_Low");
   }

   string action = "Waiting for the channel";
   if(HasOurPosition())
      action = "Exit at the next " + EnumToString(g_tf) + " open, unless the stop is hit first";
   else if(EntriesToday() >= InpMaxEntriesPerDay)
      action = "Daily entry cap reached";
   else if(haveChannel && g_ordersBar == bar)
      action = "Buy and sell stops are working";
   else if(haveChannel)
      action = "Placing stops";

   Comment("NQ 50-bar breakout  ", EnumToString(g_tf), "  24h\n",
           "Buy stop   ", (haveChannel ? DoubleToString(hh, DigitsSym()) : "-"), "\n",
           "Sell stop  ", (haveChannel ? DoubleToString(ll, DigitsSym()) : "-"), "\n",
           "Entries today  ", IntegerToString(EntriesToday()), " / ", IntegerToString(InpMaxEntriesPerDay), "\n",
           "Position  ", PositionText(), "\n",
           action);
}

//+------------------------------------------------------------------+
void LogOnce(const string message)
{
   if(message == g_lastLog)
      return;
   g_lastLog = message;
   Print(message);
}
//+------------------------------------------------------------------+
