//+------------------------------------------------------------------+
//| NQ50Breakout.mq5                                                 |
//| 50-bar breakout. Direction is an input. Exit only in profit.    |
//|                                                                  |
//| Market:    NASDAQ index (US100, NQ, or the broker's symbol)     |
//| Session:   24 hours, no clock filter                             |
//| Long:      buy stop at the highest high of the last 50 bars      |
//| Short:     sell stop at the lowest low of the last 50 bars       |
//| Direction: long only, short only, or both                       |
//| Exit:      after the entry bar has closed, and only if the last |
//|            closed M1 bar finished in profit. A live tick is not |
//|            a profit signal.                                      |
//| Stop:      previous candle, or none. Trail is a percent of price |
//| Cap:       2 entries per day                                     |
//| Brake:     market-close every position after a 9000 daily drop  |
//| Risk:      cap each order so the stop risks at most an input % |
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
#property version   "1.29"
#property description "50-bar breakout. Buy stop at the channel high, sell stop at the channel low."
#property description "Direction is long only, short only, or both. Profit exit waits for a closed M1 bar."

#include <Trade/Trade.mqh>

enum ENUM_NQ_DIRECTION
{
   NQ_DIR_LONG  = 0, // Long only
   NQ_DIR_SHORT = 1, // Short only
   NQ_DIR_BOTH  = 2  // Both directions
};

input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M30; // Signal timeframe
input int    InpLookback           = 50;      // Closed bars in the channel
input int    InpMaxEntriesPerDay   = 2;       // Max entries per day
input int    InpDayResetHour       = 0;       // Day starts at this hour, server time
input ENUM_NQ_DIRECTION InpDirection = NQ_DIR_BOTH; // Trade direction

input group "=== Trade ==="
input double InpLots               = 1.0;     // Volume, lots
input double InpMaxRiskPercent     = 5.0;     // Max loss per order, percent of equity
input double InpTrailPercent       = 0.0;     // Trailing stop, percent of price (0 = off)
input bool   InpNoStop             = false;   // No stop loss
input int    InpMaxHoldHours       = 0;       // Close after this many hours (0 = off)
input bool   InpOverclock          = false;   // Overclock, use the input volume above the floor
input double InpEquityFloor        = 180000.0; // Equity floor for sizing
input ulong  InpMagic              = 50302026;
input int    InpSlippageTicks      = 10;      // Max slippage, ticks
input bool   InpRemoveStopsOnRemove = true;   // Delete resting stops when the EA is removed

CTrade            g_trade;
ENUM_TIMEFRAMES   g_tf           = PERIOD_M30;
int               g_lookback     = 50;
int               g_maxEntries   = 2;
int               g_dayReset     = 0;
ulong             g_magic        = 50302026;
int               g_slippage     = 10;
bool              g_removeStops  = true;
datetime g_ordersBar       = 0;
datetime g_seenBar         = 0;
datetime g_capLoggedDay    = 0;
double   g_sentLots        = -1.0;
datetime g_sizeDay         = 0;
double   g_frozenLots      = -1.0;
datetime g_ddDay           = 0;
double   g_dayEquity       = 0.0;
datetime g_brakeLoggedDay  = 0;
ulong    g_trailTicket    = 0;
double   g_trailBest      = 0.0;
datetime g_trailMinute    = 0;
string   g_lastLog         = "";

// Equity sizing is applied to the lot input.
const double EQUITY_CAP  = 210000.0;
const double EQUITY_UNIT = 6000.0;
const double SIZE_FACTOR = 0.35;
const double DAILY_DRAWDOWN_LIMIT = 9000.0;

//+------------------------------------------------------------------+
double EquityRatio()
{
   return (AccountInfoDouble(ACCOUNT_EQUITY) - InpEquityFloor) / EQUITY_UNIT;
}

//+------------------------------------------------------------------+
double SizeFactor()
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= InpEquityFloor)
      return 0.0;
   if(InpOverclock)
      return 1.0;
   const double capped = (equity > EQUITY_CAP ? EQUITY_CAP : equity);
   return (capped - InpEquityFloor) / EQUITY_UNIT * SIZE_FACTOR;
}

//+------------------------------------------------------------------+
double EffectiveLotsRaw()
{
   return InpLots * SizeFactor();
}

//+------------------------------------------------------------------+
bool AllowBuy()
{
   return (InpDirection == NQ_DIR_LONG || InpDirection == NQ_DIR_BOTH);
}

//+------------------------------------------------------------------+
bool AllowSell()
{
   return (InpDirection == NQ_DIR_SHORT || InpDirection == NQ_DIR_BOTH);
}

//+------------------------------------------------------------------+
string DirectionText()
{
   if(InpDirection == NQ_DIR_LONG)
      return "Long only";
   if(InpDirection == NQ_DIR_SHORT)
      return "Short only";
   return "Both directions";
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLookback < 2 || InpMaxEntriesPerDay < 1 || InpLots <= 0.0 || InpEquityFloor <= 0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpMaxRiskPercent <= 0.0 || InpMaxRiskPercent > 100.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpTrailPercent < 0.0 || InpTrailPercent >= 100.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpMaxHoldHours < 0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpDayResetHour < 0 || InpDayResetHour > 23)
      return INIT_PARAMETERS_INCORRECT;

   g_tf = (InpTimeframe == PERIOD_CURRENT) ? Period() : InpTimeframe;
   g_lookback = InpLookback;
   g_maxEntries = InpMaxEntriesPerDay;
   g_dayReset = InpDayResetHour;
   g_magic = InpMagic;
   g_slippage = InpSlippageTicks;
   g_removeStops = InpRemoveStopsOnRemove;

   if(PeriodSeconds(g_tf) <= 0)
   {
      Print("Signal timeframe is not a candle period.");
      return INIT_PARAMETERS_INCORRECT;
   }
   // The tester cannot build the signal bars from a higher test period.
   // A live chart can: ticks still arrive, and the signal series is read directly.
   if(MQLInfoInteger(MQL_TESTER) && PeriodSeconds(Period()) > PeriodSeconds(g_tf))
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
   g_sentLots = -1.0;
   g_sizeDay = 0;
   g_frozenLots = -1.0;
   g_ddDay = 0;
   g_dayEquity = 0.0;
   g_brakeLoggedDay = 0;
   g_trailTicket = 0;
   g_trailBest = 0.0;
   g_trailMinute = 0;
   g_lastLog = "";
   ConfigureTrade();

   Print("NQ50Breakout on ", _Symbol,
         ". Channel ", g_lookback, " ", EnumToString(g_tf),
         " bars, max ", g_maxEntries,
         " entries/day, day resets at ", g_dayReset, ":00.",
         " Direction ", DirectionText(),
         InpNoStop ? ". No stop loss. Exit only after a closed M1 bar in profit"
                   : ". Stop is the previous candle. Trail " + DoubleToString(InpTrailPercent, 2)
                     + "% of price. Exit only after a closed M1 bar in profit",
         InpMaxHoldHours > 0 ? ". Close after " + IntegerToString(InpMaxHoldHours) + " hours." : ". No time exit.",
         ". Equity ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
         ", ratio ", DoubleToString(EquityRatio(), 3),
         ", factor ", DoubleToString(SizeFactor(), 3),
         ", lots ", DoubleToString(EffectiveLotsRaw(), 2),
         " from input ", DoubleToString(InpLots, 2),
         ". Risk cap ", DoubleToString(InpMaxRiskPercent, 1), "% of equity.",
         " Emergency brake at ", DoubleToString(DAILY_DRAWDOWN_LIMIT, 0), " daily drawdown.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   ObjectDelete(0, "NQ50_High");
   ObjectDelete(0, "NQ50_Low");
   if(g_removeStops)
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
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_magic)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   // One position at a time: the opposite breakout stop is cancelled as soon as this one fills.
   DeleteOurPendings();
}

//+------------------------------------------------------------------+
bool ResizeWorkingStops()
{
   const double base = NormalizedLots();
   if(base <= 0.0)
      return false;

   ulong tickets[];
   const int n = OurOrders(tickets, -1);
   if(n == 0)
      return false;

   for(int i = 0; i < n; i++)
   {
      if(!OrderSelect(tickets[i]))
         return false;
      const double price = OrderGetDouble(ORDER_PRICE_OPEN);
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const ENUM_ORDER_TYPE side = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY)
                                   ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double sl = 0.0;
      const bool haveLevel = InpNoStop ? RiskLevel(side, price, sl) : StopPriceFor(side, price, sl);
      if(!haveLevel && !InpNoStop)
         return false;
      const double brokerSl = InpNoStop ? 0.0 : sl;
      if((side == ORDER_TYPE_BUY && !AllowBuy()) || (side == ORDER_TYPE_SELL && !AllowSell()))
      {
         if(!g_trade.OrderDelete(tickets[i]))
            return false;
         continue;
      }
      const double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      const double curSl = OrderGetDouble(ORDER_SL);
      const double lots = haveLevel ? CapLotsForRisk(base, side, price, sl) : base;
      if(lots <= 0.0)
      {
         ReportRiskSize(side == ORDER_TYPE_BUY ? "buy" : "sell", base, lots, side, price, sl);
         if(!g_trade.OrderDelete(tickets[i]))
            return false;
         continue;
      }
      if(MathAbs(vol - lots) <= 1e-8 && MathAbs(curSl - brokerSl) < TickSize() * 0.5)
         continue;
      if(!g_trade.OrderDelete(tickets[i]))
         return false;
      const bool ok = (side == ORDER_TYPE_BUY)
                      ? g_trade.BuyStop(lots, price, _Symbol, brokerSl, 0.0, ORDER_TIME_GTC, 0, "NQ50 buy stop")
                      : g_trade.SellStop(lots, price, _Symbol, brokerSl, 0.0, ORDER_TIME_GTC, 0, "NQ50 sell stop");
      if(!ok)
      {
         LogOnce("NQ50 size update failed: " + g_trade.ResultRetcodeDescription());
         return false;
      }
      ReportRiskSize(side == ORDER_TYPE_BUY ? "buy" : "sell", base, lots, side, price, sl);
   }
   return true;
}

//+------------------------------------------------------------------+
string DayEquityKey(const datetime day)
{
   return "NQ50DD_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((int)day);
}

//+------------------------------------------------------------------+
void LockDayEquity()
{
   const datetime day = DayStart(TimeCurrent());
   if(g_ddDay == day)
      return;
   if(g_ddDay != 0 && !MQLInfoInteger(MQL_TESTER))
      GlobalVariableDel(DayEquityKey(g_ddDay));
   g_ddDay = day;

   if(MQLInfoInteger(MQL_TESTER))
   {
      g_dayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }

   const string key = DayEquityKey(day);
   if(GlobalVariableCheck(key))
   {
      g_dayEquity = GlobalVariableGet(key);
      return;
   }
   g_dayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   GlobalVariableSet(key, g_dayEquity);
}

//+------------------------------------------------------------------+
double DailyDrawdown()
{
   LockDayEquity();
   const double drop = g_dayEquity - AccountInfoDouble(ACCOUNT_EQUITY);
   if(drop < 0.0)
      return 0.0;
   return drop;
}

//+------------------------------------------------------------------+
void PrepareSymbolTrade(const string symbol)
{
   const long mode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.SetDeviationInPoints(100000);
}

//+------------------------------------------------------------------+
bool EmergencyBrake()
{
   const double drop = DailyDrawdown();
   if(drop < DAILY_DRAWDOWN_LIMIT)
      return false;

   const datetime day = DayStart(TimeCurrent());
   if(g_brakeLoggedDay != day)
   {
      g_brakeLoggedDay = day;
      Print("NQ50 emergency brake. Daily drawdown ", DoubleToString(drop, 2),
            " has reached ", DoubleToString(DAILY_DRAWDOWN_LIMIT, 0),
            ". Closing every position until the next day.");
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      const string symbol = PositionGetString(POSITION_SYMBOL);
      SymbolSelect(symbol, true);
      PrepareSymbolTrade(symbol);
      if(!g_trade.PositionClose(ticket))
         Print("Emergency close failed ticket ", (string)ticket, ": ", g_trade.ResultRetcodeDescription());
   }
   DeleteOurPendings();
   return true;
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
   if(EmergencyBrake())
   {
      UpdateComment(bar);
      return;
   }
   CloseIfHeldFromPriorBar(bar);
   CloseIfExpired();

   if(HasOurPosition())
   {
      DeleteOurPendings();
      EnsurePositionStop();
      TrailPositions();
      if(PositionOpenedThisBar(bar))
         g_ordersBar = bar;
      UpdateComment(bar);
      return;
   }

   if(EntriesToday() >= g_maxEntries)
   {
      DeleteOurPendings();
      g_ordersBar = bar;
      if(g_capLoggedDay != DayStart(TimeCurrent()))
      {
         g_capLoggedDay = DayStart(TimeCurrent());
         Print("NQ50 entry cap reached (", g_maxEntries, "). No new entries until the next day.");
      }
      UpdateComment(bar);
      return;
   }

   const double lotsNow = NormalizedLots();
   if(lotsNow <= 0.0)
   {
      DeleteOurPendings();
      LogOnce("Equity " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
              + " is at or below the floor. No new entries.");
      UpdateComment(bar);
      return;
   }

   // Orders for this bar are already working, or this bar already took its entry.
   // A stop-out does not open a replacement until the next bar.
   // Lot size changes only at the day reset, so this replaces resting stops once.
   if(g_ordersBar == bar)
   {
      if(MathAbs(lotsNow - g_sentLots) > 1e-8 && ResizeWorkingStops())
         g_sentLots = lotsNow;
      UpdateComment(bar);
      return;
   }

   bool retry = true;
   RefreshBreakoutOrders(retry);
   if(!retry)
   {
      g_ordersBar = bar;
      g_sentLots = lotsNow;
   }

   UpdateComment(bar);
}

//+------------------------------------------------------------------+
void ConfigureTrade()
{
   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   const double tick = TickSize();
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int deviation = g_slippage;
   if(tick > 0.0 && point > 0.0)
      deviation = (int)MathRound(g_slippage * tick / point);
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
   dt.hour = g_dayReset;
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
double LotsFromEquity()
{
   double lots = EffectiveLotsRaw();
   if(lots <= 0.0)
      return 0.0;
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      lots = MathFloor(lots / step + 1e-8) * step;
   if(minLot > 0.0 && lots < minLot)
      return 0.0;
   if(maxLot > 0.0 && lots > maxLot)
      lots = maxLot;
   return NormalizeDouble(lots, 8);
}

//+------------------------------------------------------------------+
void LockDailyLots()
{
   const datetime day = DayStart(TimeCurrent());
   if(g_sizeDay == day && g_frozenLots >= 0.0)
      return;
   g_sizeDay = day;
   g_frozenLots = LotsFromEquity();
   Print("NQ50 lots locked at ", DoubleToString(g_frozenLots, 2),
         " for the day starting ", TimeToString(day, TIME_DATE|TIME_MINUTES),
         ". Equity ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), ".");
}

//+------------------------------------------------------------------+
double NormalizedLots()
{
   LockDailyLots();
   return (g_frozenLots < 0.0 ? 0.0 : g_frozenLots);
}

//+------------------------------------------------------------------+
double CapLotsForRisk(const double lots, const ENUM_ORDER_TYPE side, const double entry, const double sl)
{
   if(lots <= 0.0)
      return 0.0;
   double perLot = 0.0;
   if(!OrderCalcProfit(side, _Symbol, 1.0, entry, sl, perLot))
      return 0.0;
   perLot = MathAbs(perLot);
   if(perLot <= 0.0)
      return 0.0;

   const double maxLoss = AccountInfoDouble(ACCOUNT_EQUITY) * InpMaxRiskPercent / 100.0;
   if(maxLoss <= 0.0)
      return 0.0;

   double capped = lots;
   if(lots * perLot > maxLoss)
      capped = maxLoss / perLot;

   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      capped = MathFloor(capped / step + 1e-8) * step;
   if(capped > lots)
      capped = lots;
   if(minLot > 0.0 && capped < minLot)
      return 0.0;
   if(maxLot > 0.0 && capped > maxLot)
      capped = maxLot;
   return NormalizeDouble(capped, 8);
}

//+------------------------------------------------------------------+
void ReportRiskSize(const string side, const double base, const double lots,
                    const ENUM_ORDER_TYPE orderSide, const double price, const double sl)
{
   if(lots <= 0.0)
   {
      LogOnce("NQ50 " + side + " skipped. The stop would risk more than "
              + DoubleToString(InpMaxRiskPercent, 1) + "% of equity.");
      return;
   }
   if(lots + 1e-8 >= base)
      return;
   double loss = 0.0;
   if(!OrderCalcProfit(orderSide, _Symbol, lots, price, sl, loss))
      loss = 0.0;
   LogOnce("NQ50 " + side + " size cut from " + DoubleToString(base, 2)
           + " to " + DoubleToString(lots, 2)
           + ". Estimated loss " + DoubleToString(MathAbs(loss), 2) + ".");
}

//+------------------------------------------------------------------+
bool CandleStop(const ENUM_ORDER_TYPE side, const int prevShift, const double entry, double &sl, const bool checkDistance)
{
   if(prevShift < 1 || Bars(_Symbol, g_tf) <= prevShift)
      return false;

   const bool isBuy = (side == ORDER_TYPE_BUY);
   const double raw = isBuy ? iLow(_Symbol, g_tf, prevShift) : iHigh(_Symbol, g_tf, prevShift);
   if(raw <= 0.0)
      return false;
   sl = NormPrice(raw);
   if(isBuy && sl >= entry)
      return false;
   if(!isBuy && sl <= entry)
      return false;

   if(!checkDistance)
      return true;

   const double minDist = MinStopDistance();
   if(minDist > 0.0 && MathAbs(entry - sl) + TickSize() * 0.5 < minDist)
   {
      LogOnce("Previous-candle stop is inside the broker minimum stop distance. No order sent.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool StopPriceFor(const ENUM_ORDER_TYPE side, const double entry, double &sl)
{
   return CandleStop(side, 1, entry, sl, true);
}

//+------------------------------------------------------------------+
// The risk cap still uses the previous candle when no broker stop is sent.
bool RiskLevel(const ENUM_ORDER_TYPE side, const double entry, double &sl)
{
   return CandleStop(side, 1, entry, sl, false);
}

//+------------------------------------------------------------------+
bool Channel(double &hh, double &ll)
{
   if(Bars(_Symbol, g_tf) < g_lookback + 1)
      return false;
   const int hi = iHighest(_Symbol, g_tf, MODE_HIGH, g_lookback, 1);
   const int lo = iLowest(_Symbol, g_tf, MODE_LOW, g_lookback, 1);
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
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_magic)
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
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_magic)
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
      if((ulong)OrderGetInteger(ORDER_MAGIC) != g_magic)
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
void DeletePendingType(const ENUM_ORDER_TYPE type)
{
   ulong tickets[];
   OurOrders(tickets, type);
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
bool ClosedM1BarInProfit(const bool isBuy, const double openPrice, const datetime opened, datetime &closedBar, double &closedPrice)
{
   closedBar = iTime(_Symbol, PERIOD_M1, 1);
   closedPrice = iClose(_Symbol, PERIOD_M1, 1);
   if(closedBar <= 0 || closedPrice <= 0.0)
   {
      LogOnce("Profit exit is waiting for a closed M1 bar.");
      return false;
   }

   // Shift 1 has finished. A bar that ended at or before the fill cannot confirm the trade.
   if(closedBar + PeriodSeconds(PERIOD_M1) <= opened)
      return false;

   const double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(isBuy)
      return (closedPrice > openPrice);
   return (closedPrice + (spread > 0.0 ? spread : 0.0) < openPrice);
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
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(opened >= barOpen)
         continue;

      // The signal candle after the entry bar must have closed. Profit is then
      // read from the last closed M1 bar, never from the forming bar's tick.
      const int shift = iBarShift(_Symbol, g_tf, opened, false);
      if(shift < 2)
         continue;

      const bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime closedBar = 0;
      double closedPrice = 0.0;
      if(!ClosedM1BarInProfit(isBuy, openPrice, opened, closedBar, closedPrice))
         continue;

      if(g_trade.PositionClose(tickets[i]))
         Print("NQ50 exit on closed M1 bar ", TimeToString(closedBar, TIME_DATE | TIME_MINUTES),
               " close ", DoubleToString(closedPrice, DigitsSym()),
               ", in profit. Ticket ", (string)tickets[i],
               " price ", DoubleToString(g_trade.ResultPrice(), DigitsSym()));
      else
         LogOnce("Exit failed ticket " + (string)tickets[i] + ": " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void CloseIfExpired()
{
   if(InpMaxHoldHours <= 0)
      return;

   const datetime now = TimeCurrent();
   const int limit = InpMaxHoldHours * 3600;
   ulong tickets[];
   OurPositions(tickets);
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(opened <= 0 || (now - opened) < limit)
         continue;

      const double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(tickets[i]))
         Print("NQ50 time exit after ", IntegerToString(InpMaxHoldHours),
               " hours. Ticket ", (string)tickets[i],
               " profit ", DoubleToString(pnl, 2),
               " price ", DoubleToString(g_trade.ResultPrice(), DigitsSym()));
      else
         LogOnce("Time exit failed ticket " + (string)tickets[i] + ": " + g_trade.ResultRetcodeDescription());
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
      if(InpNoStop)
      {
         if(PositionGetDouble(POSITION_SL) <= 0.0)
            continue;
         if(!g_trade.PositionModify(tickets[i], 0.0, 0.0))
            LogOnce("Could not remove the stop: " + g_trade.ResultRetcodeDescription());
         continue;
      }
      if(PositionGetDouble(POSITION_SL) > 0.0)
         continue;

      const bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const ENUM_ORDER_TYPE side = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int shift = iBarShift(_Symbol, g_tf, opened, false);
      if(shift < 0)
         shift = 0;
      double sl = 0.0;
      if(!CandleStop(side, shift + 1, PositionGetDouble(POSITION_PRICE_OPEN), sl, true))
         continue;
      if(!g_trade.PositionModify(tickets[i], sl, 0.0))
         LogOnce("Could not attach the previous-candle stop: " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void TrailPositions()
{
   if(InpNoStop || InpTrailPercent <= 0.0)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double minDist = MinStopDistance();
   const double tick = TickSize();
   const double frac = InpTrailPercent / 100.0;
   const datetime now = TimeCurrent();
   const datetime minute = now - (now % 60);

   ulong tickets[];
   OurPositions(tickets);
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      const ulong ticket = tickets[i];
      const bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const double curSl = PositionGetDouble(POSITION_SL);
      if(curSl <= 0.0)
         continue;

      if(ticket != g_trailTicket)
      {
         g_trailTicket = ticket;
         g_trailBest = 0.0;
         g_trailMinute = minute;
      }

      const double next = isBuy ? FloorTick(bid * (1.0 - frac))
                                : CeilTick(ask * (1.0 + frac));
      const bool placeable = (next > 0.0)
         && (isBuy ? (next < bid && (minDist <= 0.0 || bid - next >= minDist))
                   : (next > ask && (minDist <= 0.0 || next - ask >= minDist)));
      if(placeable && (g_trailBest <= 0.0 || (isBuy && next > g_trailBest) || (!isBuy && next < g_trailBest)))
         g_trailBest = next;

      if(minute == g_trailMinute)
         continue;
      g_trailMinute = minute;

      if(g_trailBest <= 0.0)
         continue;
      if(isBuy && (g_trailBest >= bid || (minDist > 0.0 && bid - g_trailBest < minDist)))
      {
         g_trailBest = 0.0;
         continue;
      }
      if(!isBuy && (g_trailBest <= ask || (minDist > 0.0 && g_trailBest - ask < minDist)))
      {
         g_trailBest = 0.0;
         continue;
      }
      if(isBuy && g_trailBest <= curSl + tick * 0.5)
         continue;
      if(!isBuy && g_trailBest >= curSl - tick * 0.5)
         continue;

      if(!g_trade.PositionModify(ticket, g_trailBest, 0.0))
         LogOnce("Trail stop failed: " + g_trade.ResultRetcodeDescription());
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
   const bool haveLevel = InpNoStop ? RiskLevel(side, price, sl) : StopPriceFor(side, price, sl);
   if(price <= 0.0 || (!haveLevel && !InpNoStop))
   {
      retry = (price <= 0.0);
      return false;
   }

   const double base = NormalizedLots();
   const double lots = haveLevel ? CapLotsForRisk(base, side, price, sl) : base;
   const double brokerSl = InpNoStop ? 0.0 : sl;
   ReportRiskSize(isBuy ? "buy" : "sell", base, lots, side, price, sl);
   if(lots <= 0.0)
      return false;

   const bool ok = isBuy ? g_trade.Buy(lots, _Symbol, 0.0, brokerSl, 0.0, "NQ50 market")
                         : g_trade.Sell(lots, _Symbol, 0.0, brokerSl, 0.0, "NQ50 market");
   if(ok)
   {
      Print("NQ50 market ", (isBuy ? "buy" : "sell"),
            " ", DoubleToString(lots, 2), " at ",
            DoubleToString(g_trade.ResultPrice() > 0.0 ? g_trade.ResultPrice() : price, DigitsSym()),
            brokerSl > 0.0 ? " SL " + DoubleToString(brokerSl, DigitsSym()) : " no SL",
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
   const bool haveLevel = InpNoStop ? RiskLevel(side, price, sl) : StopPriceFor(side, price, sl);
   if(!haveLevel && !InpNoStop)
      return true;

   const double base = NormalizedLots();
   const double lots = haveLevel ? CapLotsForRisk(base, side, price, sl) : base;
   const double brokerSl = InpNoStop ? 0.0 : sl;
   ulong ticket = FindPending(type);
   if(lots <= 0.0)
   {
      if(ticket != 0)
         g_trade.OrderDelete(ticket);
      ReportRiskSize(isBuy ? "buy" : "sell", base, lots, side, price, sl);
      return true;
   }
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
      const bool ok = isBuy ? g_trade.BuyStop(lots, price, _Symbol, brokerSl, 0.0, ORDER_TIME_GTC, 0, "NQ50 buy stop")
                            : g_trade.SellStop(lots, price, _Symbol, brokerSl, 0.0, ORDER_TIME_GTC, 0, "NQ50 sell stop");
      if(ok)
      {
         Print("NQ50 ", (isBuy ? "buy" : "sell"), " stop ", DoubleToString(lots, 2),
               " at ", DoubleToString(price, DigitsSym()),
               brokerSl > 0.0 ? " SL " + DoubleToString(brokerSl, DigitsSym()) : " no SL");
         ReportRiskSize(isBuy ? "buy" : "sell", base, lots, side, price, sl);
         return true;
      }
      retry = IsTransient(g_trade.ResultRetcode());
      LogOnce("NQ50 stop failed: " + g_trade.ResultRetcodeDescription()
              + " price " + DoubleToString(price, DigitsSym())
              + (brokerSl > 0.0 ? " SL " + DoubleToString(brokerSl, DigitsSym()) : " no SL"));
      return false;
   }

   if(!OrderSelect(ticket))
   {
      retry = true;
      return false;
   }
   const double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   const double curSl = OrderGetDouble(ORDER_SL);
   if(MathAbs(curPrice - price) < TickSize() * 0.5 && MathAbs(curSl - brokerSl) < TickSize() * 0.5)
      return true;

   if(g_trade.OrderModify(ticket, price, brokerSl, 0.0, ORDER_TIME_GTC, 0))
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
      LogOnce("Waiting for " + IntegerToString(g_lookback) + " closed " + EnumToString(g_tf) + " bars.");
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

   const bool wantBuy = AllowBuy();
   const bool wantSell = AllowSell();

   if(wantBuy && wantSell && buyThrough && sellThrough)
   {
      DeleteOurPendings();
      LogOnce("Bid/ask is through both channel edges. No entry this bar.");
      return;
   }

   if(wantBuy && buyThrough)
   {
      DeleteOurPendings();
      SendMarket(ORDER_TYPE_BUY, retry);
      return;
   }
   if(wantSell && sellThrough)
   {
      DeleteOurPendings();
      SendMarket(ORDER_TYPE_SELL, retry);
      return;
   }

   bool buyRetry = false;
   bool sellRetry = false;
   if(wantBuy)
      EnsureStop(ORDER_TYPE_BUY_STOP, buyLevel, buyRetry);
   else
      DeletePendingType(ORDER_TYPE_BUY_STOP);
   // A stop can fill before the other side is sent. Do not rest the other side once we are in.
   if(!HasOurPosition())
   {
      if(wantSell)
         EnsureStop(ORDER_TYPE_SELL_STOP, sellLevel, sellRetry);
      else
         DeletePendingType(ORDER_TYPE_SELL_STOP);
   }
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
      DrawLevel("NQ50_High", hh, clrDodgerBlue, IntegerToString(g_lookback) + "-bar high");
      DrawLevel("NQ50_Low", ll, clrOrangeRed, IntegerToString(g_lookback) + "-bar low");
   }
   else
   {
      ObjectDelete(0, "NQ50_High");
      ObjectDelete(0, "NQ50_Low");
   }

   string action = "Waiting for the channel";
   if(DailyDrawdown() >= DAILY_DRAWDOWN_LIMIT)
      action = "Emergency brake: daily drawdown limit hit";
   else if(HasOurPosition())
   {
      action = InpNoStop ? "Exit only after a closed M1 bar in profit"
                         : "Exit only after a closed M1 bar in profit, unless the stop is hit first";
      if(InpMaxHoldHours > 0)
         action += ". Close after " + IntegerToString(InpMaxHoldHours) + " hours";
   }
   else if(EntriesToday() >= g_maxEntries)
      action = "Daily entry cap reached";
   else if(haveChannel && g_ordersBar == bar)
      action = AllowBuy() && AllowSell() ? "Buy and sell stops are working"
             : (AllowBuy() ? "Buy stop is working" : "Sell stop is working");
   else if(haveChannel)
      action = "Placing stops";

   double buyLots = -1.0;
   double sellLots = -1.0;
   if(haveChannel)
   {
      const double base = NormalizedLots();
      double buySl = 0.0;
      double sellSl = 0.0;
      const double buyPx = NormPrice(hh);
      const double sellPx = NormPrice(ll);
      const bool buyLevel = InpNoStop ? RiskLevel(ORDER_TYPE_BUY, buyPx, buySl) : StopPriceFor(ORDER_TYPE_BUY, buyPx, buySl);
      const bool sellLevel = InpNoStop ? RiskLevel(ORDER_TYPE_SELL, sellPx, sellSl) : StopPriceFor(ORDER_TYPE_SELL, sellPx, sellSl);
      if(buyLevel)
         buyLots = CapLotsForRisk(base, ORDER_TYPE_BUY, buyPx, buySl);
      else if(InpNoStop)
         buyLots = base;
      if(sellLevel)
         sellLots = CapLotsForRisk(base, ORDER_TYPE_SELL, sellPx, sellSl);
      else if(InpNoStop)
         sellLots = base;
   }

   Comment(EnumToString(g_tf), "  ", DirectionText(),
           "  equity ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 0),
           "  ratio ", DoubleToString(EquityRatio(), 2), "\n",
           "Lots ", DoubleToString(NormalizedLots(), 2),
           " (input ", DoubleToString(InpLots, 2), ")",
           "   risk cap ", DoubleToString(InpMaxRiskPercent, 1), "%",
           "   buy ", (buyLots < 0.0 ? "-" : DoubleToString(buyLots, 2)),
           "   sell ", (sellLots < 0.0 ? "-" : DoubleToString(sellLots, 2)),
           "   exit Profit only",
           InpNoStop ? "   stop none" : "\n   trail " + DoubleToString(InpTrailPercent, 2) + "%",
           InpMaxHoldHours > 0 ? "   expire " + IntegerToString(InpMaxHoldHours) + " h\n" : "\n",
           "Buy stop   ", (haveChannel ? DoubleToString(hh, DigitsSym()) : "-"), "\n",
           "Sell stop  ", (haveChannel ? DoubleToString(ll, DigitsSym()) : "-"), "\n",
           "Entries today  ", IntegerToString(EntriesToday()), " / ", IntegerToString(g_maxEntries), "\n",
           "Drawdown  ", DoubleToString(DailyDrawdown(), 0), " / ", DoubleToString(DAILY_DRAWDOWN_LIMIT, 0), "\n",
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
