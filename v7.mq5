//+------------------------------------------------------------------+
//|                              OpenLowHighEA_v7.mq5                |
//|              Open=Low/High Strategy with Full Tick Array System  |
//|              FIXED: MQL5 Struct Array Compatibility              |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "7.00"
#property strict

//--- Input Parameters
input group "=== Trade Settings ==="
input double   InpMaxProfitUSD = 100.0;      // Maximum Profit (USD)
input double   InpMaxLossUSD = 50.0;         // Maximum Loss (USD)

input group "=== Loss Saver (Breakeven) ==="
input bool     InpUseLossSaver = true;       // Use Loss Saver
input double   InpLossSaverThreshold = 20.0;  // Loss Saver Threshold (USD)

input group "=== Trailing SL ==="
input double   InpTrailingThreshold = 50.0;   // Trailing Threshold (% of Max Profit)
input double   InpTrailingStep = 10.0;        // Trailing Step (points)

input group "=== Trend Filter ==="
input bool     InpUseTrendFilter = true;     // Use MA Filter
input int      InpMAPeriod = 50;             // MA Period
input ENUM_MA_METHOD InpMAMethod = MODE_EMA; // MA Method
input ENUM_APPLIED_PRICE InpMAAppliedPrice = PRICE_CLOSE; // MA Applied Price

input group "=== Dynamic SL ==="
input bool     InpUseDynamicSL = false;      // Use Dynamic SL
input int      InpDynamicSLBars = 3;        // Dynamic SL Bars

input group "=== Pre-Trade Tick Array Filter ==="
input bool     InpUsePreTradeFilter = true;  // Enable Pre-Trade Filter
input int      InpPreTradeTickCount = 20;    // Ticks to analyze before entry
input double   InpMinDirectionalBias = 60.0;  // Min directional bias % (60 = 60%)
input double   InpMinMomentumPips = 0.3;     // Min momentum in pips
input double   InpMaxPreTradeSpread = 25.0;  // Max spread to trade (points)

input group "=== In-Trade Tick Array Analysis ==="
input bool     InpUseTickAnalysis = true;    // Enable In-Trade Analysis
input int      InpTickMemorySize = 100;      // Max ticks to store per trade
input double   InpProfitPeakThreshold = 30.0; // Close if drawdown from peak exceeds %
input int      InpProfitFlatTicks = 50;      // Close if profit flat for N ticks
input double   InpMinProfitVelocity = 0.5;   // Min profit velocity (pips/tick)
input double   InpLossAccelThreshold = -1.0;   // Emergency exit if loss velocity < this
input double   InpLossRecoveryPct = 60.0;     // Widen SL if recovered this % from worst
input int      InpMaxUnderwaterMinutes = 3;   // Close if underwater this long

input group "=== Trade Memory & Adaptive ==="
input bool     InpUseTradeMemory = true;       // Enable trade memory
input int      InpMemoryWindow = 100;        // Trades to remember
input bool     InpUseAntiRevenge = true;     // Reduce size after losses
input int      InpConsecutiveLossLimit = 3;   // Trades before anti-revenge
input double   InpAntiRevengeFactor = 0.5;    // Reduce lot by this factor

input group "=== Session Filter ==="
input bool     InpUseSessionFilter = false;    // Enable session filter
input int      InpStartHour = 8;             // Start trading hour (GMT)
input int      InpEndHour = 20;              // End trading hour (GMT)

input group "=== Spread Filter ==="
input bool     InpUseSpreadFilter = true;      // Enable spread filter
input double   InpMaxSpreadPoints = 30.0;     // Max spread to trade

input group "=== Order Settings ==="
input int      InpMagicNumber = 123456;      // Magic Number
input int      InpSlippage = 30;             // Slippage (points)
input string   InpTradeComment = "OLH_EA";   // Trade Comment

//--- Maximum positions to track
#define MAX_POSITIONS 10

//--- Pre-Trade Tick Storage (parallel arrays)
double         g_preTradePrice[];
datetime       g_preTradeTime[];
double         g_preTradeSpread[];
double         g_preTradeVelocity[];
int            g_preTradeTickIndex = 0;

//--- In-Trade Tick Storage (parallel arrays for each position)
double         g_tradePrice[MAX_POSITIONS][1000];
datetime       g_tradeTime[MAX_POSITIONS][1000];
double         g_tradeSpread[MAX_POSITIONS][1000];
double         g_tradeProfit[MAX_POSITIONS][1000];
double         g_tradeVelocity[MAX_POSITIONS][1000];
int            g_tradeTickCount[MAX_POSITIONS];
double         g_tradeMaxProfit[MAX_POSITIONS];
double         g_tradeMaxLoss[MAX_POSITIONS];
datetime       g_tradeEntryTime[MAX_POSITIONS];
ulong          g_tradeTicket[MAX_POSITIONS];

//--- Trade Memory
struct TradeRecord
{
   ulong    ticket;
   datetime entryTime;
   datetime exitTime;
   double   entryPrice;
   double   exitPrice;
   long     direction;
   double   lotSize;
   double   finalProfit;
   double   maxProfit;
   double   maxLoss;
   int      durationMinutes;
   int      tickCount;
   string   exitReason;
   string   preTradePattern;
   bool     wasWinner;
};

TradeRecord    g_tradeMemory[];
int            g_tradeMemoryCount = 0;
int            g_consecutiveLosses = 0;

//--- Pre-Trade Analysis Result
struct PreTradeAnalysisResult
{
   bool     isFavorable;
   double   bias;
   double   momentum;
   string   pattern;
};

//--- Global Variables
int            g_maHandle = INVALID_HANDLE;
datetime       g_lastBarTime = 0;
bool           g_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize Moving Average
   if(InpUseTrendFilter)
   {
      g_maHandle = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, InpMAMethod, InpMAAppliedPrice);
      if(g_maHandle == INVALID_HANDLE)
      {
         Print("Error creating MA indicator. Error: ", GetLastError());
         return(INIT_FAILED);
      }
   }

   g_lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_initialized = true;

   //--- Initialize pre-trade arrays
   ArrayResize(g_preTradePrice, InpPreTradeTickCount);
   ArrayResize(g_preTradeTime, InpPreTradeTickCount);
   ArrayResize(g_preTradeSpread, InpPreTradeTickCount);
   ArrayResize(g_preTradeVelocity, InpPreTradeTickCount);

   //--- Initialize in-trade arrays
   for(int i = 0; i < MAX_POSITIONS; i++)
   {
      g_tradeTickCount[i] = 0;
      g_tradeMaxProfit[i] = 0;
      g_tradeMaxLoss[i] = 0;
      g_tradeEntryTime[i] = 0;
      g_tradeTicket[i] = 0;
   }

   //--- Initialize trade memory
   ArrayResize(g_tradeMemory, InpMemoryWindow);

   //--- Print info
   Print("=== OpenLowHigh EA v7.0 - MQL5 Compatible Tick System ===");
   Print("Symbol: ", _Symbol, " | Digits: ", _Digits, " | Point: ", _Point);
   Print("Pre-Trade Filter: ", InpUsePreTradeFilter ? "ENABLED" : "DISABLED");
   Print("In-Trade Analysis: ", InpUseTickAnalysis ? "ENABLED" : "DISABLED");
   Print("Trade Memory: ", InpUseTradeMemory ? "ENABLED" : "DISABLED");
   Print("Anti-Revenge: ", InpUseAntiRevenge ? "ENABLED" : "DISABLED");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);

   Print("=== EA v7.0 Deinitialized ===");
   Print("Total trades in memory: ", g_tradeMemoryCount);
   Print("Consecutive losses: ", g_consecutiveLosses);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_initialized) return;

   //--- Collect pre-trade ticks if enabled and no position open
   if(InpUsePreTradeFilter && CountOpenPositions() == 0)
   {
      CollectPreTradeTick();
   }

   //--- Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (currentBarTime != g_lastBarTime);

   if(!isNewBar)
   {
      //--- Manage existing positions with tick analysis
      ManageInTradeTickAnalysis();
      ManageLossSaver();
      ManageTrailingSL();
      if(InpUseDynamicSL)
         ManageDynamicSL();
      return;
   }

   //--- New bar formed
   g_lastBarTime = currentBarTime;

   //--- Check if positions exist
   if(CountOpenPositions() > 0)
   {
      ManageInTradeTickAnalysis();
      ManageLossSaver();
      ManageTrailingSL();
      if(InpUseDynamicSL)
         ManageDynamicSL();
      return;
   }

   //--- Session filter
   if(InpUseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
         return;
   }

   //--- Spread filter
   if(InpUseSpreadFilter)
   {
      long currentSpreadLong = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double currentSpread = (double)currentSpreadLong;
      if(currentSpread > InpMaxSpreadPoints)
      {
         Print("Spread too high: ", currentSpread, " > ", InpMaxSpreadPoints);
         return;
      }
   }

   //--- Analyze previous candle (index 1)
   double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double prevLow = iLow(_Symbol, PERIOD_CURRENT, 1);
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(prevOpen == 0 || prevHigh == 0 || prevLow == 0)
      return;

   //--- Get current price
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Trend filter
   double maValue = 0;
   bool trendBullish = false;
   bool trendBearish = false;

   if(InpUseTrendFilter)
   {
      double maBuffer[];
      ArraySetAsSeries(maBuffer, true);
      if(CopyBuffer(g_maHandle, 0, 0, 2, maBuffer) <= 0)
      {
         Print("Error copying MA buffer");
         return;
      }
      maValue = maBuffer[1];
      trendBullish = (prevClose > maValue);
      trendBearish = (prevClose < maValue);
   }
   else
   {
      trendBullish = true;
      trendBearish = true;
   }

   //--- Signal detection
   double pointVal = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tolerance = pointVal * 2.0;

   bool isOpenLow = (MathAbs(prevOpen - prevLow) <= tolerance);
   bool isOpenHigh = (MathAbs(prevOpen - prevHigh) <= tolerance);

   //--- Pre-trade tick array analysis
   bool preTradeOK = true;
   string preTradePattern = "NONE";

   if(InpUsePreTradeFilter && g_preTradeTickIndex >= InpPreTradeTickCount)
   {
      PreTradeAnalysisResult result = AnalyzePreTradeTicks();
      preTradeOK = result.isFavorable;
      preTradePattern = result.pattern;

      Print("Pre-Trade Analysis: Pattern=", result.pattern, 
            " Bias=", DoubleToString(result.bias, 1), "%",
            " Momentum=", DoubleToString(result.momentum, 2),
            " Decision=", preTradeOK ? "GO" : "SKIP");
   }

   if(!preTradeOK)
   {
      Print("Pre-Trade Filter BLOCKED signal. Pattern: ", preTradePattern);
      ResetPreTradeArray();
      return;
   }

   //--- Execute SELL
   if(isOpenLow && trendBearish)
   {
      double tpPrice = NormalizeDouble(prevLow, _Digits);
      double lotSize = 0;
      double slPrice = CalculateSellSLAndLot(tpPrice, InpMaxLossUSD, lotSize);

      //--- Anti-revenge
      if(InpUseAntiRevenge && g_consecutiveLosses >= InpConsecutiveLossLimit)
      {
         lotSize *= InpAntiRevengeFactor;
         lotSize = NormalizeLotSize(lotSize);
         Print("Anti-Revenge activated. Lot reduced to: ", lotSize);
      }

      if(lotSize > 0 && slPrice > 0 && ValidateStops(ORDER_TYPE_SELL, currentBid, slPrice, tpPrice))
      {
         if(OpenSellOrder(lotSize, slPrice, tpPrice, preTradePattern))
         {
            ResetPreTradeArray();
         }
      }
   }

   //--- Execute BUY
   if(isOpenHigh && trendBullish)
   {
      double tpPrice = NormalizeDouble(prevHigh, _Digits);
      double lotSize = 0;
      double slPrice = CalculateBuySLAndLot(tpPrice, InpMaxLossUSD, lotSize);

      //--- Anti-revenge
      if(InpUseAntiRevenge && g_consecutiveLosses >= InpConsecutiveLossLimit)
      {
         lotSize *= InpAntiRevengeFactor;
         lotSize = NormalizeLotSize(lotSize);
         Print("Anti-Revenge activated. Lot reduced to: ", lotSize);
      }

      if(lotSize > 0 && slPrice > 0 && ValidateStops(ORDER_TYPE_BUY, currentAsk, slPrice, tpPrice))
      {
         if(OpenBuyOrder(lotSize, slPrice, tpPrice, preTradePattern))
         {
            ResetPreTradeArray();
         }
      }
   }

   //--- Reset pre-trade array if no signal
   if(!isOpenLow && !isOpenHigh)
   {
      ResetPreTradeArray();
   }
}

//+------------------------------------------------------------------+
//| Collect tick for pre-trade analysis                                |
//+------------------------------------------------------------------+
void CollectPreTradeTick()
{
   if(g_preTradeTickIndex >= InpPreTradeTickCount)
   {
      //--- Shift array left (FIFO)
      for(int i = 0; i < InpPreTradeTickCount - 1; i++)
      {
         g_preTradePrice[i] = g_preTradePrice[i + 1];
         g_preTradeTime[i] = g_preTradeTime[i + 1];
         g_preTradeSpread[i] = g_preTradeSpread[i + 1];
         g_preTradeVelocity[i] = g_preTradeVelocity[i + 1];
      }
      g_preTradeTickIndex = InpPreTradeTickCount - 1;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   g_preTradePrice[g_preTradeTickIndex] = (bid + ask) / 2.0;
   g_preTradeTime[g_preTradeTickIndex] = TimeCurrent();
   g_preTradeSpread[g_preTradeTickIndex] = spread;
   g_preTradeVelocity[g_preTradeTickIndex] = 0;

   if(g_preTradeTickIndex > 0)
   {
      double priceDiff = g_preTradePrice[g_preTradeTickIndex] - g_preTradePrice[g_preTradeTickIndex - 1];
      double timeDiff = (double)(g_preTradeTime[g_preTradeTickIndex] - g_preTradeTime[g_preTradeTickIndex - 1]);
      if(timeDiff > 0)
         g_preTradeVelocity[g_preTradeTickIndex] = priceDiff / timeDiff;
   }

   g_preTradeTickIndex++;
}

//+------------------------------------------------------------------+
//| Reset pre-trade array                                              |
//+------------------------------------------------------------------+
void ResetPreTradeArray()
{
   ArrayResize(g_preTradePrice, InpPreTradeTickCount);
   ArrayResize(g_preTradeTime, InpPreTradeTickCount);
   ArrayResize(g_preTradeSpread, InpPreTradeTickCount);
   ArrayResize(g_preTradeVelocity, InpPreTradeTickCount);
   g_preTradeTickIndex = 0;
}

//+------------------------------------------------------------------+
//| Analyze pre-trade ticks                                            |
//+------------------------------------------------------------------+
PreTradeAnalysisResult AnalyzePreTradeTicks()
{
   PreTradeAnalysisResult result;
   result.isFavorable = false;
   result.bias = 0;
   result.momentum = 0;
   result.pattern = "FLAT";

   if(g_preTradeTickIndex < InpPreTradeTickCount / 2)
   {
      result.pattern = "INSUFFICIENT_DATA";
      return result;
   }

   int upTicks = 0;
   int downTicks = 0;
   int flatTicks = 0;
   double totalMove = 0;
   double startPrice = g_preTradePrice[0];
   double endPrice = g_preTradePrice[g_preTradeTickIndex - 1];
   double pointVal = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = 1; i < g_preTradeTickIndex; i++)
   {
      double diff = g_preTradePrice[i] - g_preTradePrice[i - 1];
      totalMove += MathAbs(diff);

      if(diff > pointVal)
         upTicks++;
      else if(diff < -pointVal)
         downTicks++;
      else
         flatTicks++;
   }

   int totalCounted = upTicks + downTicks;
   if(totalCounted == 0)
   {
      result.pattern = "FLAT";
      return result;
   }

   double upBias = (double)upTicks / (double)totalCounted * 100.0;
   double downBias = (double)downTicks / (double)totalCounted * 100.0;

   double netMove = (endPrice - startPrice) / pointVal;
   result.momentum = netMove;

   if(upBias >= InpMinDirectionalBias && netMove > 0)
   {
      result.pattern = "BULLISH";
      result.bias = upBias;
   }
   else if(downBias >= InpMinDirectionalBias && netMove < 0)
   {
      result.pattern = "BEARISH";
      result.bias = downBias;
   }
   else if(totalMove > 0 && MathAbs(netMove) / totalMove < 0.3)
   {
      result.pattern = "CHOP";
      result.bias = MathMax(upBias, downBias);
   }
   else
   {
      result.pattern = "FLAT";
      result.bias = MathMax(upBias, downBias);
   }

   bool momentumOK = (MathAbs(netMove) >= InpMinMomentumPips);

   double avgSpread = 0;
   for(int i = 0; i < g_preTradeTickIndex; i++)
      avgSpread += g_preTradeSpread[i];
   avgSpread /= (double)g_preTradeTickIndex;

   bool spreadOK = (avgSpread <= InpMaxPreTradeSpread);

   result.isFavorable = momentumOK && spreadOK;

   return result;
}

//+------------------------------------------------------------------+
//| Manage In-Trade Tick Analysis                                      |
//+------------------------------------------------------------------+
void ManageInTradeTickAnalysis()
{
   if(!InpUseTickAnalysis) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);
      datetime entryTime = (datetime)PositionGetInteger(POSITION_TIME);

      //--- Find or create trade index
      int tradeIdx = FindTradeIndex(ticket);
      if(tradeIdx < 0)
      {
         tradeIdx = CreateTradeIndex(ticket, entryTime);
         if(tradeIdx < 0) continue;
      }

      //--- Capture current tick
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
      double currentProfit = 0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

      if(posType == POSITION_TYPE_BUY)
         currentProfit = (bid - openPrice) / _Point * lotSize * tickValue;
      else
         currentProfit = (openPrice - ask) / _Point * lotSize * tickValue;

      //--- Store tick in parallel arrays
      int tickIdx = g_tradeTickCount[tradeIdx];
      if(tickIdx < InpTickMemorySize && tickIdx < 1000)
      {
         g_tradePrice[tradeIdx][tickIdx] = currentPrice;
         g_tradeTime[tradeIdx][tickIdx] = TimeCurrent();
         g_tradeSpread[tradeIdx][tickIdx] = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         g_tradeProfit[tradeIdx][tickIdx] = currentProfit;

         if(tickIdx > 0)
         {
            double profitDiff = g_tradeProfit[tradeIdx][tickIdx] - g_tradeProfit[tradeIdx][tickIdx - 1];
            double timeDiff = (double)(g_tradeTime[tradeIdx][tickIdx] - g_tradeTime[tradeIdx][tickIdx - 1]);
            if(timeDiff > 0)
               g_tradeVelocity[tradeIdx][tickIdx] = profitDiff / timeDiff;
            else
               g_tradeVelocity[tradeIdx][tickIdx] = 0;
         }
         else
         {
            g_tradeVelocity[tradeIdx][tickIdx] = 0;
         }

         g_tradeTickCount[tradeIdx]++;
      }

      //--- Update max profit/loss
      if(currentProfit > g_tradeMaxProfit[tradeIdx])
         g_tradeMaxProfit[tradeIdx] = currentProfit;
      if(currentProfit < g_tradeMaxLoss[tradeIdx])
         g_tradeMaxLoss[tradeIdx] = currentProfit;

      //--- Analyze and take action
      string action = AnalyzeTradeTicks(tradeIdx, posType, currentProfit, openPrice, currentSL);

      if(action == "CLOSE_PROFIT_PEAK")
      {
         Print("Tick Analysis: Profit peaked and reversing. Closing ticket ", ticket);
         ClosePosition(ticket, "TickProfitPeak");
      }
      else if(action == "CLOSE_FLAT")
      {
         Print("Tick Analysis: Profit flatlining. Closing ticket ", ticket);
         ClosePosition(ticket, "TickFlat");
      }
      else if(action == "CLOSE_LOSS_ACCEL")
      {
         Print("Tick Analysis: Loss accelerating. Emergency close ticket ", ticket);
         ClosePosition(ticket, "TickLossAccel");
      }
      else if(action == "CLOSE_UNDERWATER")
      {
         Print("Tick Analysis: Underwater too long. Closing ticket ", ticket);
         ClosePosition(ticket, "TickUnderwater");
      }
      else if(action == "WIDEN_SL_RECOVERY")
      {
         double newSL = (posType == POSITION_TYPE_BUY) ? openPrice - 50.0 * _Point : openPrice + 50.0 * _Point;
         ModifySL(ticket, newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Find trade index in arrays                                         |
//+------------------------------------------------------------------+
int FindTradeIndex(ulong ticket)
{
   for(int i = 0; i < MAX_POSITIONS; i++)
   {
      if(g_tradeTicket[i] == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Create trade index in arrays                                       |
//+------------------------------------------------------------------+
int CreateTradeIndex(ulong ticket, datetime entryTime)
{
   for(int i = 0; i < MAX_POSITIONS; i++)
   {
      if(g_tradeEntryTime[i] == 0)
      {
         g_tradeEntryTime[i] = entryTime;
         g_tradeTicket[i] = ticket;
         g_tradeTickCount[i] = 0;
         g_tradeMaxProfit[i] = 0;
         g_tradeMaxLoss[i] = 0;
         return i;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Analyze trade ticks and return action                              |
//+------------------------------------------------------------------+
string AnalyzeTradeTicks(int tradeIdx, long posType, double currentProfit, double openPrice, double currentSL)
{
   int tickCount = g_tradeTickCount[tradeIdx];
   if(tickCount < 10) return "HOLD";

   double maxProfit = g_tradeMaxProfit[tradeIdx];
   double maxLoss = g_tradeMaxLoss[tradeIdx];

   //--- 1. Profit peaked and reversing
   if(maxProfit > 0 && currentProfit > 0)
   {
      double drawdownFromMax = (maxProfit - currentProfit) / maxProfit * 100.0;
      if(drawdownFromMax >= InpProfitPeakThreshold)
         return "CLOSE_PROFIT_PEAK";
   }

   //--- 2. Profit flatlining
   if(tickCount >= InpProfitFlatTicks)
   {
      double recentProfit = g_tradeProfit[tradeIdx][tickCount - 1];
      double oldProfit = g_tradeProfit[tradeIdx][tickCount - InpProfitFlatTicks];

      if(MathAbs(recentProfit - oldProfit) < 1.0)
         return "CLOSE_FLAT";
   }

   //--- 3. Loss accelerating
   if(tickCount >= 5)
   {
      double recentVelocity = 0;
      for(int j = tickCount - 5; j < tickCount; j++)
         recentVelocity += g_tradeVelocity[tradeIdx][j];
      recentVelocity /= 5.0;

      if(recentVelocity < InpLossAccelThreshold)
         return "CLOSE_LOSS_ACCEL";
   }

   //--- 4. Underwater too long
   if(currentProfit < 0)
   {
      int underwaterTicks = 0;
      for(int j = tickCount - 1; j >= 0; j--)
      {
         if(g_tradeProfit[tradeIdx][j] < 0)
            underwaterTicks++;
         else
            break;
      }

      double underwaterMinutes = (double)underwaterTicks / 60.0;
      if(underwaterMinutes >= (double)InpMaxUnderwaterMinutes)
         return "CLOSE_UNDERWATER";
   }

   //--- 5. Loss recovering - widen SL
   if(maxLoss < 0 && currentProfit > maxLoss)
   {
      double recovery = (currentProfit - maxLoss) / MathAbs(maxLoss) * 100.0;
      if(recovery >= InpLossRecoveryPct && currentSL == openPrice)
         return "WIDEN_SL_RECOVERY";
   }

   return "HOLD";
}

//+------------------------------------------------------------------+
//| Manage Loss Saver                                                  |
//+------------------------------------------------------------------+
void ManageLossSaver()
{
   if(!InpUseLossSaver) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);

      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

      double currentProfit = 0;
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         currentProfit = (bid - openPrice) / tickSize * tickValue * lotSize;
      }
      else
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         currentProfit = (openPrice - ask) / tickSize * tickValue * lotSize;
      }

      if(currentProfit >= InpLossSaverThreshold)
      {
         double newSL = 0;
         bool moveToBreakeven = false;

         if(posType == POSITION_TYPE_BUY && currentSL < openPrice)
         {
            newSL = openPrice;
            moveToBreakeven = true;
         }
         else if(posType == POSITION_TYPE_SELL && (currentSL > openPrice || currentSL == 0))
         {
            newSL = openPrice;
            moveToBreakeven = true;
         }

         if(moveToBreakeven && newSL > 0)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

            if(posType == POSITION_TYPE_BUY)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               if((bid - newSL) < stopLevel)
                  newSL = bid - stopLevel;
            }
            else
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               if((newSL - ask) < stopLevel)
                  newSL = ask + stopLevel;
            }

            newSL = NormalizeDouble(newSL, _Digits);

            if(MathAbs(newSL - currentSL) > _Point)
            {
               MqlTradeRequest request = {};
               MqlTradeResult result = {};

               request.action = TRADE_ACTION_SLTP;
               request.position = ticket;
               request.symbol = _Symbol;
               request.sl = newSL;
               request.tp = currentTP;
               request.magic = InpMagicNumber;

               if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
               {
                  Print("=== LOSS SAVER === Ticket: ", ticket, " SL->Breakeven: ", newSL,
                        " Profit: $", DoubleToString(currentProfit, 2));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing SL                                                 |
//+------------------------------------------------------------------+
void ManageTrailingSL()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);

      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

      double currentProfit = 0;
      double currentPrice = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         currentProfit = (currentPrice - openPrice) / tickSize * tickValue * lotSize;
      }
      else
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         currentProfit = (openPrice - currentPrice) / tickSize * tickValue * lotSize;
      }

      double trailingThresholdUSD = InpMaxProfitUSD * (InpTrailingThreshold / 100.0);

      if(currentProfit >= trailingThresholdUSD)
      {
         double newSL = 0;
         bool modifySL = false;

         if(posType == POSITION_TYPE_BUY)
         {
            if(currentSL < openPrice)
            {
               newSL = openPrice;
               modifySL = true;
            }
            else if(currentProfit > trailingThresholdUSD && currentSL >= openPrice)
            {
               double trailSL = currentPrice - (InpTrailingStep * _Point);
               trailSL = NormalizeDouble(trailSL, _Digits);
               double minTrailDistance = MathMax(stopLevel, InpTrailingStep * _Point);
               if((currentPrice - trailSL) < minTrailDistance)
                  trailSL = currentPrice - minTrailDistance;

               if(trailSL > currentSL)
               {
                  newSL = trailSL;
                  modifySL = true;
               }
            }
         }
         else // SELL
         {
            if(currentSL > openPrice || currentSL == 0)
            {
               newSL = openPrice;
               modifySL = true;
            }
            else if(currentProfit > trailingThresholdUSD && (currentSL <= openPrice || currentSL == 0))
            {
               double trailSL = currentPrice + (InpTrailingStep * _Point);
               trailSL = NormalizeDouble(trailSL, _Digits);
               double minTrailDistance = MathMax(stopLevel, InpTrailingStep * _Point);
               if((trailSL - currentPrice) < minTrailDistance)
                  trailSL = currentPrice + minTrailDistance;

               if(trailSL < currentSL || currentSL == 0)
               {
                  newSL = trailSL;
                  modifySL = true;
               }
            }
         }

         if(modifySL && newSL > 0)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            if(MathAbs(newSL - currentSL) > _Point)
            {
               MqlTradeRequest request = {};
               MqlTradeResult result = {};

               request.action = TRADE_ACTION_SLTP;
               request.position = ticket;
               request.symbol = _Symbol;
               request.sl = newSL;
               request.tp = currentTP;
               request.magic = InpMagicNumber;

               if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
               {
                  Print("Trailing SL updated. Ticket: ", ticket, " SL: ", newSL,
                        " Profit: $", DoubleToString(currentProfit, 2));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Dynamic SL                                                  |
//+------------------------------------------------------------------+
void ManageDynamicSL()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      int adverseBars = 0;
      int totalBars = iBars(_Symbol, PERIOD_CURRENT);
      int startBar = iBarShift(_Symbol, PERIOD_CURRENT, openTime, false);
      if(startBar < 0) startBar = 1;

      int barsToCheck = MathMin(InpDynamicSLBars, totalBars - startBar);

      for(int b = 1; b <= barsToCheck; b++)
      {
         int barIndex = startBar + b;
         if(barIndex >= totalBars) break;

         double barOpen = iOpen(_Symbol, PERIOD_CURRENT, barIndex);
         double barClose = iClose(_Symbol, PERIOD_CURRENT, barIndex);

         bool isAdverse = false;
         if(posType == POSITION_TYPE_BUY)
            isAdverse = (barClose < barOpen);
         else
            isAdverse = (barClose > barOpen);

         if(isAdverse)
            adverseBars++;
         else
            break;
      }

      if(adverseBars >= InpDynamicSLBars)
      {
         Print("Dynamic SL triggered. Ticket: ", ticket, " Adverse bars: ", adverseBars);
         ClosePosition(ticket, "DynamicSL");
      }
   }
}

//+------------------------------------------------------------------+
//| Close Position with reason                                         |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket))
   {
      Print("Error selecting position. Error: ", GetLastError());
      return false;
   }

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   long posType = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = volume;
   request.deviation = InpSlippage;
   request.magic = InpMagicNumber;
   request.comment = InpTradeComment + "_" + reason;

   if(posType == POSITION_TYPE_BUY)
   {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   else
   {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   }

   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("Close position failed. Error: ", GetLastError());
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      if(InpUseTradeMemory)
         LogTradeToMemory(ticket, openPrice, request.price, posType, volume, reason);

      //--- Clear trade index
      int idx = FindTradeIndex(ticket);
      if(idx >= 0)
      {
         g_tradeEntryTime[idx] = 0;
         g_tradeTicket[idx] = 0;
         g_tradeTickCount[idx] = 0;
         g_tradeMaxProfit[idx] = 0;
         g_tradeMaxLoss[idx] = 0;
      }

      Print("Position closed. Ticket: ", ticket, " Reason: ", reason);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Log trade to memory                                                |
//+------------------------------------------------------------------+
void LogTradeToMemory(ulong ticket, double entryPrice, double exitPrice, 
                      long direction, double lotSize, string reason)
{
   if(g_tradeMemoryCount >= InpMemoryWindow)
   {
      for(int i = 0; i < InpMemoryWindow - 1; i++)
         g_tradeMemory[i] = g_tradeMemory[i + 1];
      g_tradeMemoryCount = InpMemoryWindow - 1;
   }

   double profit = 0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(direction == POSITION_TYPE_BUY)
      profit = (exitPrice - entryPrice) / _Point * lotSize * tickValue;
   else
      profit = (entryPrice - exitPrice) / _Point * lotSize * tickValue;

   g_tradeMemory[g_tradeMemoryCount].ticket = ticket;
   g_tradeMemory[g_tradeMemoryCount].entryPrice = entryPrice;
   g_tradeMemory[g_tradeMemoryCount].exitPrice = exitPrice;
   g_tradeMemory[g_tradeMemoryCount].direction = direction;
   g_tradeMemory[g_tradeMemoryCount].lotSize = lotSize;
   g_tradeMemory[g_tradeMemoryCount].finalProfit = profit;
   g_tradeMemory[g_tradeMemoryCount].exitReason = reason;
   g_tradeMemory[g_tradeMemoryCount].wasWinner = (profit > 0);

   if(profit > 0)
      g_consecutiveLosses = 0;
   else
      g_consecutiveLosses++;

   g_tradeMemoryCount++;

   Print("Trade logged. Ticket: ", ticket, " Profit: $", DoubleToString(profit, 2),
         " Consecutive losses: ", g_consecutiveLosses);
}

//+------------------------------------------------------------------+
//| Modify SL                                                          |
//+------------------------------------------------------------------+
bool ModifySL(ulong ticket, double newSL, double currentTP)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.sl = newSL;
   request.tp = currentTP;
   request.magic = InpMagicNumber;

   if(!OrderSend(request, result))
   {
      Print("Modify SL failed. Error: ", GetLastError());
      return false;
   }

   return (result.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//| Calculate SL and Lot for SELL                                      |
//+------------------------------------------------------------------+
double CalculateSellSLAndLot(double tpPrice, double maxLossUSD, double &lotSize)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(tickValue <= 0) return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tpDistance = bid - tpPrice;

   if(tpDistance <= 0)
   {
      Print("Invalid SELL: TP (", tpPrice, ") not below entry (", bid, ")");
      return 0;
   }

   double minSLDistance = MathMax(stopLevel, tickSize);

   lotSize = InpMaxProfitUSD / ((tpDistance / tickSize) * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   double slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
   slDistance = MathMax(slDistance, minSLDistance);

   double slPrice = bid + slDistance;

   if(slPrice <= bid || tpPrice >= bid)
   {
      Print("Invalid SELL stops. SL: ", slPrice, " Entry: ", bid, " TP: ", tpPrice);
      return 0;
   }

   double marginRequired;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lotSize, bid, marginRequired))
      return 0;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.9)
   {
      lotSize = (freeMargin * 0.9 / marginRequired) * lotSize;
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(lotSize, minLot);

      slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
      slDistance = MathMax(slDistance, minSLDistance);
      slPrice = bid + slDistance;
   }

   return NormalizeDouble(slPrice, _Digits);
}

//+------------------------------------------------------------------+
//| Calculate SL and Lot for BUY                                       |
//+------------------------------------------------------------------+
double CalculateBuySLAndLot(double tpPrice, double maxLossUSD, double &lotSize)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(tickValue <= 0) return 0;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tpDistance = tpPrice - ask;

   if(tpDistance <= 0)
   {
      Print("Invalid BUY: TP (", tpPrice, ") not above entry (", ask, ")");
      return 0;
   }

   double minSLDistance = MathMax(stopLevel, tickSize);

   lotSize = InpMaxProfitUSD / ((tpDistance / tickSize) * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   double slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
   slDistance = MathMax(slDistance, minSLDistance);

   double slPrice = ask - slDistance;

   if(slPrice >= ask || tpPrice <= ask)
   {
      Print("Invalid BUY stops. SL: ", slPrice, " Entry: ", ask, " TP: ", tpPrice);
      return 0;
   }

   double marginRequired;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, ask, marginRequired))
      return 0;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.9)
   {
      lotSize = (freeMargin * 0.9 / marginRequired) * lotSize;
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(lotSize, minLot);

      slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
      slDistance = MathMax(slDistance, minSLDistance);
      slPrice = ask - slDistance;
   }

   return NormalizeDouble(slPrice, _Digits);
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                 |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lotSize)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Validate stops                                                     |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE orderType, double entryPrice, double slPrice, double tpPrice)
{
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minDistance = MathMax(stopLevel, tickSize);

   if(orderType == ORDER_TYPE_BUY)
   {
      if((entryPrice - slPrice) < minDistance)
      {
         Print("BUY SL too close. Dist: ", entryPrice - slPrice, " Min: ", minDistance);
         return false;
      }
      if((tpPrice - entryPrice) < minDistance)
      {
         Print("BUY TP too close. Dist: ", tpPrice - entryPrice, " Min: ", minDistance);
         return false;
      }
      if(slPrice >= tpPrice)
      {
         Print("BUY SL >= TP");
         return false;
      }
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      if((slPrice - entryPrice) < minDistance)
      {
         Print("SELL SL too close. Dist: ", slPrice - entryPrice, " Min: ", minDistance);
         return false;
      }
      if((entryPrice - tpPrice) < minDistance)
      {
         Print("SELL TP too close. Dist: ", entryPrice - tpPrice, " Min: ", minDistance);
         return false;
      }
      if(slPrice <= tpPrice)
      {
         Print("SELL SL <= TP");
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Open BUY Order                                                     |
//+------------------------------------------------------------------+
bool OpenBuyOrder(double lotSize, double slPrice, double tpPrice, string pattern)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.sl = slPrice;
   request.tp = tpPrice;
   request.deviation = InpSlippage;
   request.magic = InpMagicNumber;
   request.comment = InpTradeComment + "_" + pattern;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("Buy OrderSend failed. Error: ", GetLastError());
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("BUY Executed. Ticket: ", result.order, " Lot: ", lotSize,
            " Entry: ", ask, " SL: ", slPrice, " TP: ", tpPrice,
            " Pattern: ", pattern);
      return true;
   }

   Print("Buy Order failed. Retcode: ", result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Open SELL Order                                                    |
//+------------------------------------------------------------------+
bool OpenSellOrder(double lotSize, double slPrice, double tpPrice, string pattern)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = bid;
   request.sl = slPrice;
   request.tp = tpPrice;
   request.deviation = InpSlippage;
   request.magic = InpMagicNumber;
   request.comment = InpTradeComment + "_" + pattern;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("Sell OrderSend failed. Error: ", GetLastError());
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("SELL Executed. Ticket: ", result.order, " Lot: ", lotSize,
            " Entry: ", bid, " SL: ", slPrice, " TP: ", tpPrice,
            " Pattern: ", pattern);
      return true;
   }

   Print("Sell Order failed. Retcode: ", result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Count open positions                                               |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get filling mode                                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}
//+------------------------------------------------------------------+