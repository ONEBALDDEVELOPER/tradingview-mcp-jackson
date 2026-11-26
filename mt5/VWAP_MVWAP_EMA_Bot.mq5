//+------------------------------------------------------------------+
//|                                       VWAP_MVWAP_EMA_Bot.mq5    |
//| Port of TradingView "VWAP/MVWAP/EMA CROSSOVER" (@totoboy) |
//| Adds: SL/TP via settings, consolidation filter, risk sizing      |
//+------------------------------------------------------------------+
#property copyright "VWAP/MVWAP/EMA Bot"
#property version   "1.00"
#property description "Long when EMA1, EMA2 and VWAP are all >= MVWAP (state flips on)."
#property description "Short when that state flips off. No entries during consolidation."

#include <Trade/Trade.mqh>

enum ENUM_DIR_MODE   { DIR_BOTH, DIR_LONG_ONLY, DIR_SHORT_ONLY };
enum ENUM_SL_MODE    { SL_FIXED_PIPS, SL_ATR_MULT };
enum ENUM_TP_MODE    { TP_FIXED_PIPS, TP_RISK_REWARD, TP_ATR_MULT, TP_NONE };
enum ENUM_LOT_MODE   { LOT_FIXED, LOT_RISK_PERCENT };

//--- Strategy (from Pine)
input group "=== Strategy (from Pine script) ==="
input int    InpVwapLen      = 1;      // VWAP Length (EMA of VWAP)
input int    InpMvwapLen     = 21;     // MVWAP Length (EMA of VWAP)
input int    InpEma1Len      = 7;      // EMA 1 Length (close)
input int    InpEma2Len      = 25;     // EMA 2 Length (close)
input ENUM_DIR_MODE InpDirection = DIR_BOTH; // Trade direction
input bool   InpCloseOnOpposite = true;// Close position on opposite signal

input group "=== Optional RSI filter (long entries) ==="
input bool   InpUseRsiFilter = false;  // Require RSI between min and limit
input int    InpRsiPeriod    = 14;     // RSI period
input double InpRsiMin       = 51;     // RSI minimum (wait for dip)
input double InpRsiLimit     = 65;     // RSI limit (risky above)

//--- Stop loss / take profit
input group "=== Stop Loss / Take Profit ==="
input ENUM_SL_MODE InpSlMode = SL_FIXED_PIPS; // Stop loss mode
input double InpSlPips       = 30.0;   // SL: fixed distance in pips
input double InpSlAtrMult    = 1.5;    // SL: ATR multiplier
input ENUM_TP_MODE InpTpMode = TP_RISK_REWARD;// Take profit mode
input double InpTpPips       = 60.0;   // TP: fixed distance in pips
input double InpTpRR         = 2.0;    // TP: reward:risk ratio
input double InpTpAtrMult    = 3.0;    // TP: ATR multiplier
input int    InpAtrPeriod    = 14;     // ATR period

//--- Position size
input group "=== Position Size ==="
input ENUM_LOT_MODE InpLotMode = LOT_FIXED; // Lot mode
input double InpLots         = 0.10;   // Fixed lots
input double InpRiskPercent  = 1.0;    // Risk % of equity per trade

//--- Consolidation filter
input group "=== Consolidation filter (no entries while ranging) ==="
input bool   InpUseConsFilter = true;  // Enable consolidation filter
input bool   InpUseAdx       = true;   // Test 1: ADX below threshold
input int    InpAdxPeriod    = 14;     // ADX period
input double InpAdxMin       = 20.0;   // ADX < this = consolidating
input bool   InpUseRange     = true;   // Test 2: tight N-bar range
input int    InpRangeBars    = 20;     // Bars in range window
input double InpRangeAtrMult = 3.0;    // Range < this x ATR = consolidating
input bool   InpUseEmaSpread = false;  // Test 3: EMA1/EMA2 squeezed
input double InpEmaSpreadAtr = 0.3;    // |EMA1-EMA2| < this x ATR = consolidating

//--- Trade filters / misc
input group "=== Filters & misc ==="
input int    InpMaxSpreadPts = 0;      // Max spread in points (0 = off)
input bool   InpUseTimeFilter= false;  // Restrict trading hours
input int    InpStartHour    = 7;      // Start hour (server time)
input int    InpEndHour      = 20;     // End hour (server time)
input int    InpWarmupBars   = 300;    // Bars of history for VWAP/MVWAP warmup
input long   InpMagic        = 20250101; // Magic number
input int    InpSlippagePts  = 20;     // Max slippage (points)
input string InpComment      = "VWAP_MVWAP_EMA"; // Order comment

CTrade   trade;
int      hEma1 = INVALID_HANDLE, hEma2 = INVALID_HANDLE;
int      hRsi  = INVALID_HANDLE, hAtr  = INVALID_HANDLE, hAdx = INVALID_HANDLE;
datetime g_lastBar = 0;
double   g_pip = 0.0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_pip = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;

   hEma1 = iMA(_Symbol, _Period, InpEma1Len, 0, MODE_EMA, PRICE_CLOSE);
   hEma2 = iMA(_Symbol, _Period, InpEma2Len, 0, MODE_EMA, PRICE_CLOSE);
   hRsi  = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, InpAtrPeriod);
   hAdx  = iADX(_Symbol, _Period, InpAdxPeriod);
   if(hEma1 == INVALID_HANDLE || hEma2 == INVALID_HANDLE || hRsi == INVALID_HANDLE ||
      hAtr == INVALID_HANDLE || hAdx == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   int h[] = {hEma1, hEma2, hRsi, hAtr, hAdx};
   for(int i = 0; i < ArraySize(h); i++)
      if(h[i] != INVALID_HANDLE) IndicatorRelease(h[i]);
}

//+------------------------------------------------------------------+
//| Read one indicator value at a given shift                        |
//+------------------------------------------------------------------+
bool Val(int handle, int buffer, int shift, double &out)
{
   double b[];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1) return false;
   out = b[0];
   return true;
}

//+------------------------------------------------------------------+
//| Daily-anchored VWAP (hlc3, tick volume) + EMAs of it.            |
//| Returns VWAP-EMA(InpVwapLen) and MVWAP at shift 1 and shift 2.   |
//+------------------------------------------------------------------+
bool GetVwap(double &cv1, double &cv2, double &mv1, double &mv2)
{
   datetime t0 = iTime(_Symbol, _Period, InpWarmupBars);
   if(t0 == 0) return false;
   MqlDateTime d;
   TimeToStruct(t0, d);
   d.hour = 0; d.min = 0; d.sec = 0;
   datetime start = StructToTime(d);

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, _Period, start, TimeCurrent(), r);
   if(n < InpMvwapLen + 5) return false;

   double kC = 2.0 / (InpVwapLen + 1.0);
   double kM = 2.0 / (InpMvwapLen + 1.0);
   double cumPV = 0, cumV = 0, cv = 0, mv = 0;
   long   lastDay = -1;
   double cvArr[], mvArr[];
   ArrayResize(cvArr, n);
   ArrayResize(mvArr, n);

   for(int i = 0; i < n; i++)
   {
      long day = (long)(r[i].time / 86400);
      if(day != lastDay) { cumPV = 0; cumV = 0; lastDay = day; }
      double vol = (double)r[i].tick_volume;
      if(vol <= 0) vol = 1.0;
      double tp = (r[i].high + r[i].low + r[i].close) / 3.0;
      cumPV += tp * vol;
      cumV  += vol;
      double vwap = cumPV / cumV;

      if(i == 0) { cv = vwap; mv = vwap; }
      else       { cv = kC * vwap + (1.0 - kC) * cv; mv = kM * vwap + (1.0 - kM) * mv; }
      cvArr[i] = cv;
      mvArr[i] = mv;
   }
   // r[n-1] is the forming bar (shift 0); shift 1 = n-2, shift 2 = n-3
   cv1 = cvArr[n - 2]; mv1 = mvArr[n - 2];
   cv2 = cvArr[n - 3]; mv2 = mvArr[n - 3];
   return true;
}

//+------------------------------------------------------------------+
//| Consolidation detector. True = market is ranging, don't enter.   |
//+------------------------------------------------------------------+
bool IsConsolidating(string &why)
{
   why = "";
   if(!InpUseConsFilter) return false;

   double atr;
   if(!Val(hAtr, 0, 1, atr) || atr <= 0) return false;

   if(InpUseAdx)
   {
      double adx;
      if(Val(hAdx, 0, 1, adx) && adx < InpAdxMin)
      { why = StringFormat("ADX %.1f < %.1f", adx, InpAdxMin); return true; }
   }
   if(InpUseRange)
   {
      int ih = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeBars, 1);
      int il = iLowest (_Symbol, _Period, MODE_LOW,  InpRangeBars, 1);
      if(ih >= 0 && il >= 0)
      {
         double rng = iHigh(_Symbol, _Period, ih) - iLow(_Symbol, _Period, il);
         if(rng < InpRangeAtrMult * atr)
         { why = StringFormat("range %.1f ATR < %.1f", rng / atr, InpRangeAtrMult); return true; }
      }
   }
   if(InpUseEmaSpread)
   {
      double e1, e2;
      if(Val(hEma1, 0, 1, e1) && Val(hEma2, 0, 1, e2) && MathAbs(e1 - e2) < InpEmaSpreadAtr * atr)
      { why = "EMA1/EMA2 squeezed"; return true; }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool HasPosition(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return true;
   }
   return false;
}

void ClosePositions(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         trade.PositionClose(tk);
   }
}

//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lots = MathFloor(lots / step) * step;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return NormalizeDouble(lots, 2);
}

double CalcLots(double slDist)
{
   if(InpLotMode == LOT_FIXED || slDist <= 0) return NormalizeLots(InpLots);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return NormalizeLots(InpLots);
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double lossPerLot = (slDist / tickSize) * tickVal;
   if(lossPerLot <= 0) return NormalizeLots(InpLots);
   return NormalizeLots(riskMoney / lossPerLot);
}

//+------------------------------------------------------------------+
//| Open a trade with SL/TP from settings                            |
//+------------------------------------------------------------------+
void OpenTrade(bool isBuy)
{
   double atr = 0;
   Val(hAtr, 0, 1, atr);

   double slDist = (InpSlMode == SL_FIXED_PIPS) ? InpSlPips * g_pip : InpSlAtrMult * atr;
   if(slDist <= 0) { Print("SL distance invalid, skipping"); return; }

   double tpDist = 0;
   switch(InpTpMode)
   {
      case TP_FIXED_PIPS:   tpDist = InpTpPips * g_pip;   break;
      case TP_RISK_REWARD:  tpDist = slDist * InpTpRR;    break;
      case TP_ATR_MULT:     tpDist = InpTpAtrMult * atr;  break;
      default:              tpDist = 0;                   break;
   }

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minDist) slDist = minDist;
   if(tpDist > 0 && tpDist < minDist) tpDist = minDist;

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = isBuy ? price - slDist : price + slDist;
   double tp = (tpDist > 0) ? (isBuy ? price + tpDist : price - tpDist) : 0.0;
   sl = NormalizeDouble(sl, _Digits);
   if(tp > 0) tp = NormalizeDouble(tp, _Digits);

   double lots = CalcLots(slDist);
   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0, sl, tp, InpComment)
                   : trade.Sell(lots, _Symbol, 0, sl, tp, InpComment);
   if(!ok)
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
bool TradingAllowedNow()
{
   if(InpMaxSpreadPts > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPts) return false;
   if(InpUseTimeFilter)
   {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      if(InpStartHour <= InpEndHour) { if(t.hour < InpStartHour || t.hour >= InpEndHour) return false; }
      else                           { if(t.hour < InpStartHour && t.hour >= InpEndHour) return false; }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Evaluate once per new bar on CLOSED bars (no repainting)         |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar = iTime(_Symbol, _Period, 0);
   if(bar == g_lastBar) return;
   g_lastBar = bar;

   double cv1, cv2, mv1, mv2;
   if(!GetVwap(cv1, cv2, mv1, mv2)) return;

   double e1_1, e1_2, e2_1, e2_2;
   if(!Val(hEma1, 0, 1, e1_1) || !Val(hEma1, 0, 2, e1_2) ||
      !Val(hEma2, 0, 1, e2_1) || !Val(hEma2, 0, 2, e2_2)) return;

   // Pine: Crossup = ema1>=mvwap AND ema2>=mvwap AND vwap>=mvwap ; Long=Buy, Short=!Buy
   bool bull1 = (e1_1 >= mv1 && e2_1 >= mv1 && cv1 >= mv1); // shift 1 (last closed bar)
   bool bull2 = (e1_2 >= mv2 && e2_2 >= mv2 && cv2 >= mv2); // shift 2

   bool longSignal  = bull1 && !bull2;   // Longtrigger  = crossover(Long, 0.5)
   bool shortSignal = !bull1 && bull2;   // Shorttrigger = crossover(Short, 0.5)

   // Exits on opposite signal are always allowed
   if(InpCloseOnOpposite)
   {
      if(longSignal)  ClosePositions(POSITION_TYPE_SELL);
      if(shortSignal) ClosePositions(POSITION_TYPE_BUY);
   }

   if(!longSignal && !shortSignal) return;
   if(!TradingAllowedNow()) return;

   string why;
   if(IsConsolidating(why))
   {
      PrintFormat("%s signal skipped - consolidation (%s)", longSignal ? "Long" : "Short", why);
      return;
   }

   if(longSignal && InpDirection != DIR_SHORT_ONLY && !HasPosition(POSITION_TYPE_BUY))
   {
      if(InpUseRsiFilter)
      {
         double rsi;
         if(!Val(hRsi, 0, 1, rsi) || rsi >= InpRsiLimit || rsi <= InpRsiMin) return;
      }
      OpenTrade(true);
   }
   else if(shortSignal && InpDirection != DIR_LONG_ONLY && !HasPosition(POSITION_TYPE_SELL))
   {
      OpenTrade(false);
   }
}
//+------------------------------------------------------------------+
