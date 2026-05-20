//+------------------------------------------------------------------+
//|                                       OpenEqualHighLow_EA_v7.mq5 |
//|                        Copyright 2026, MetaQuotes Software Corp.   |
//|                                             https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "7.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Enums
enum ENUM_LOT_MODE
{
   LOT_FIXED,
   LOT_DYNAMIC
};

enum ENUM_TICK_DIR
{
   DIR_NONE,
   DIR_UP,
   DIR_DOWN,
   DIR_SIDEWAYS
};

//--- Tick Data Structure
struct TickData
{
   double   price;
   datetime time;
   double   weight;
};

//--- Price Zone Structure
struct PriceZone
{
   double   price;
   int      touches;
   datetime lastTouch;
   double   high;
   double   low;
};

//--- Profit/Loss History Structure
struct PLData
{
   double   profit;
   datetime time;
   double   weight;
};

//--- Input Parameters
input group "=== GENERAL SETTINGS ==="
input int               InpMagicNumber     = 123456;
input double            InpLotSize         = 0.01;
input int               InpMaxOrders       = 10;
input bool              InpUseMAFilter     = true;

input group "=== MOVING AVERAGE SETTINGS ==="
input int               InpMAPeriod        = 50;
input ENUM_MA_METHOD    InpMAMethod        = MODE_SMA;
input ENUM_APPLIED_PRICE InpMAAppliedPrice = PRICE_CLOSE;
input ENUM_TIMEFRAMES   InpMATimeframe     = PERIOD_M1;

input group "=== MONEY MANAGEMENT ==="
input double            InpMaxProfit       = 100.0;
input double            InpMaxLoss         = 50.0;
input bool              InpUseTrailingSL   = true;
input bool              InpAutoExit        = true;

input group "=== TOUCH-BASED AVERAGING ==="
input double            InpZoneTolerance   = 1.0;
input int               InpMinTouches      = 3;
input ENUM_LOT_MODE     InpLotMode         = LOT_DYNAMIC;
input double            InpLotMultiplier   = 2.0;
input double            InpMaxLotSize      = 1.0;
input double            InpMaxTotalVolume  = 5.0;
input int               InpMaxTickAge      = 300;
input int               InpBaseTickStorage = 200;
input double            InpMomentumThresh  = 0.5;

input group "=== PROFIT ARRAY EXIT SETTINGS ==="
input bool              InpUseProfitArrayExit = true;
input double            InpProfitTrailPercent = 50.0;
input int               InpProfitStagnationSecs = 60;
input int               InpProfitArraySize = 500;

input group "=== LOSS ARRAY EXIT SETTINGS ==="
input bool              InpUseLossArrayExit = true;
input double            InpLossWorsenPercent = 50.0;
input int               InpLossStagnationSecs = 120;
input int               InpLossArraySize = 500;

//--- Global Variables
CTrade                  m_trade;
CPositionInfo           m_position;
int                     m_maHandle;
datetime                m_lastCandleTime  = 0;
bool                    m_setupBuy        = false;
bool                    m_setupSell       = false;
double                  m_lastAvgPrice    = 0.0;
int                     m_orderCount      = 0;
ENUM_ORDER_TYPE         m_direction       = ORDER_TYPE_BUY;

TickData                m_ticks[];
int                     m_tickCount       = 0;
datetime                m_lastTickTime    = 0;

PriceZone               m_zones[];
int                     m_zoneCount       = 0;

PLData                  m_profitArray[];
int                     m_profitCount     = 0;
double                  m_maxProfit       = 0.0;
datetime                m_lastProfitHigh  = 0;

PLData                  m_lossArray[];
int                     m_lossCount       = 0;
double                  m_minLoss         = 0.0;
datetime                m_lastLossImprove  = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   m_trade.SetAsyncMode(false);

   if(InpUseMAFilter)
   {
      m_maHandle = iMA(_Symbol, InpMATimeframe, InpMAPeriod, 0, InpMAMethod, InpMAAppliedPrice);
      if(m_maHandle == INVALID_HANDLE)
      {
         Print("MA init failed");
         return(INIT_FAILED);
      }
   }

   // FIX: Ensure minimum array sizes to prevent out of range
   int tickSize = MathMax(100, InpBaseTickStorage);
   int profitSize = MathMax(100, InpProfitArraySize);
   int lossSize = MathMax(100, InpLossArraySize);

   ArrayResize(m_ticks, tickSize);
   ArrayResize(m_zones, 50);
   ArrayResize(m_profitArray, profitSize);
   ArrayResize(m_lossArray, lossSize);

   RestoreState();
   Print("EA v7.10 - Array Out of Range FIX");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(InpUseMAFilter && m_maHandle != INVALID_HANDLE)
      IndicatorRelease(m_maHandle);
   ArrayFree(m_ticks);
   ArrayFree(m_zones);
   ArrayFree(m_profitArray);
   ArrayFree(m_lossArray);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ProcessTick();
   UpdatePLArrays();

   datetime currentCandle = iTime(_Symbol, PERIOD_M1, 0);
   if(currentCandle != m_lastCandleTime)
   {
      m_lastCandleTime = currentCandle;
      CheckForSetup();
      ExecuteSetups();
      CheckAveraging();
   }

   UpdateTrailingSL();
   CheckAutoExit();
   CheckMaxLossExit();
   CheckProfitArrayExit();
   CheckLossArrayExit();
}

//+------------------------------------------------------------------+
//| Update Profit/Loss Arrays                                        |
//+------------------------------------------------------------------+
void UpdatePLArrays()
{
   if(CountPos() == 0) return;

   double currentProfit = TotalProfit();
   datetime now = TimeCurrent();

   // Update Max Profit tracking
   if(currentProfit > m_maxProfit)
   {
      m_maxProfit = currentProfit;
      m_lastProfitHigh = now;
   }

   // FIX: Proper min loss tracking - don't reset incorrectly
   if(currentProfit < 0)
   {
      if(m_minLoss == 0 || currentProfit > m_minLoss)
      {
         m_minLoss = currentProfit;
         m_lastLossImprove = now;
      }
   }

   // Add to profit array (only positive profits)
   if(currentProfit > 0)
      AddProfit(currentProfit, now);

   // Add to loss array (only negative profits = losses)
   if(currentProfit < 0)
      AddLoss(currentProfit, now);

   // Clean old data
   CleanPLArrays();
}

//+------------------------------------------------------------------+
//| Add profit to array                                              |
//+------------------------------------------------------------------+
void AddProfit(double profit, datetime time)
{
   if(m_profitCount >= ArraySize(m_profitArray))
   {
      if(ArrayResize(m_profitArray, ArraySize(m_profitArray) + 100) == -1)
      {
         Print("Failed to resize profit array");
         return;
      }
   }

   for(int i = m_profitCount; i > 0; i--)
      m_profitArray[i] = m_profitArray[i-1];

   m_profitArray[0].profit = profit;
   m_profitArray[0].time = time;
   m_profitArray[0].weight = 1.0;
   m_profitCount++;
}

//+------------------------------------------------------------------+
//| Add loss to array                                                |
//+------------------------------------------------------------------+
void AddLoss(double loss, datetime time)
{
   if(m_lossCount >= ArraySize(m_lossArray))
   {
      if(ArrayResize(m_lossArray, ArraySize(m_lossArray) + 100) == -1)
      {
         Print("Failed to resize loss array");
         return;
      }
   }

   for(int i = m_lossCount; i > 0; i--)
      m_lossArray[i] = m_lossArray[i-1];

   m_lossArray[0].profit = loss;
   m_lossArray[0].time = time;
   m_lossArray[0].weight = 1.0;
   m_lossCount++;
}

//+------------------------------------------------------------------+
//| Clean old PL arrays                                              |
//+------------------------------------------------------------------+
void CleanPLArrays()
{
   datetime now = TimeCurrent();
   int maxAge = MathMax(1, InpMaxTickAge) * 2;

   // Clean profit array
   int validProfit = 0;
   for(int i = 0; i < m_profitCount; i++)
   {
      int age = (int)(now - m_profitArray[i].time);
      if(age <= maxAge)
         validProfit++;
   }

   if(m_profitCount - validProfit >= 50)
   {
      PLData temp[];
      if(ArrayResize(temp, validProfit) == -1)
      {
         Print("Failed to resize temp profit array");
         return;
      }

      int idx = 0;
      for(int i = 0; i < m_profitCount; i++)
      {
         int age = (int)(now - m_profitArray[i].time);
         if(age <= maxAge)
            temp[idx++] = m_profitArray[i];
      }

      // FIX: Resize to fit valid data, not base size
      int newSize = MathMax(InpProfitArraySize, validProfit) + 100;
      if(ArrayResize(m_profitArray, newSize) == -1)
      {
         Print("Failed to resize profit array after clean");
         return;
      }

      m_profitCount = validProfit;
      for(int i = 0; i < validProfit; i++)
         m_profitArray[i] = temp[i];

      ArrayFree(temp);
   }

   // Clean loss array
   int validLoss = 0;
   for(int i = 0; i < m_lossCount; i++)
   {
      int age = (int)(now - m_lossArray[i].time);
      if(age <= maxAge)
         validLoss++;
   }

   if(m_lossCount - validLoss >= 50)
   {
      PLData temp[];
      if(ArrayResize(temp, validLoss) == -1)
      {
         Print("Failed to resize temp loss array");
         return;
      }

      int idx = 0;
      for(int i = 0; i < m_lossCount; i++)
      {
         int age = (int)(now - m_lossArray[i].time);
         if(age <= maxAge)
            temp[idx++] = m_lossArray[i];
      }

      // FIX: Resize to fit valid data, not base size
      int newSize = MathMax(InpLossArraySize, validLoss) + 100;
      if(ArrayResize(m_lossArray, newSize) == -1)
      {
         Print("Failed to resize loss array after clean");
         return;
      }

      m_lossCount = validLoss;
      for(int i = 0; i < validLoss; i++)
         m_lossArray[i] = temp[i];

      ArrayFree(temp);
   }
}

//+------------------------------------------------------------------+
//| Check Profit Array Exit                                          |
//+------------------------------------------------------------------+
void CheckProfitArrayExit()
{
   if(!InpUseProfitArrayExit || CountPos() == 0 || m_maxProfit <= 0) return;

   double currentProfit = TotalProfit();
   if(currentProfit <= 0) return;

   // 1. Profit Trail Exit: Drop from peak
   double profitDrop = 0;
   if(m_maxProfit > 0)
      profitDrop = ((m_maxProfit - currentProfit) / m_maxProfit) * 100.0;

   if(profitDrop >= InpProfitTrailPercent)
   {
      Print("Profit Trail Exit: Dropped ", DoubleToString(profitDrop, 1), "% from peak $", DoubleToString(m_maxProfit, 2), " to $", DoubleToString(currentProfit, 2));
      CloseAll();
      return;
   }

   // 2. Profit Stagnation Exit: No new high for X seconds
   if(InpProfitStagnationSecs > 0 && m_lastProfitHigh > 0)
   {
      int secsSinceHigh = (int)(TimeCurrent() - m_lastProfitHigh);
      if(secsSinceHigh >= InpProfitStagnationSecs && currentProfit < m_maxProfit)
      {
         Print("Profit Stagnation Exit: No new high for ", secsSinceHigh, " sec");
         CloseAll();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Check Loss Array Exit                                            |
//+------------------------------------------------------------------+
void CheckLossArrayExit()
{
   if(!InpUseLossArrayExit || CountPos() == 0) return;

   double currentProfit = TotalProfit();
   if(currentProfit >= 0) return;

   // FIX: Proper loss worsen calculation using tracked best loss
   if(m_minLoss < 0 && currentProfit < m_minLoss)
   {
      double worsenAmount = MathAbs(currentProfit) - MathAbs(m_minLoss);
      double worsenPercent = (worsenAmount / MathAbs(m_minLoss)) * 100.0;

      if(worsenPercent >= InpLossWorsenPercent)
      {
         Print("Loss Worsen Exit: Worsened ", DoubleToString(worsenPercent, 1), "% from best $", DoubleToString(m_minLoss, 2), " to $", DoubleToString(currentProfit, 2));
         CloseAll();
         return;
      }
   }

   // 2. Loss Stagnation Exit: No improvement for X seconds while in loss
   if(InpLossStagnationSecs > 0 && m_lastLossImprove > 0)
   {
      int secsSinceImprove = (int)(TimeCurrent() - m_lastLossImprove);
      if(secsSinceImprove >= InpLossStagnationSecs)
      {
         Print("Loss Stagnation Exit: No improvement for ", secsSinceImprove, " sec");
         CloseAll();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Process every tick                                               |
//+------------------------------------------------------------------+
void ProcessTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.time == m_lastTickTime) return;

   m_lastTickTime = tick.time;

   AddTick(tick.bid, tick.time);
   UpdateWeights();
   UpdateZones(tick.bid, tick.time);
   CleanOldTicks();
   CleanOldZones();
}

//+------------------------------------------------------------------+
//| Add tick to array                                                |
//+------------------------------------------------------------------+
void AddTick(double price, datetime tickTime)
{
   if(m_tickCount >= ArraySize(m_ticks))
   {
      if(ArrayResize(m_ticks, ArraySize(m_ticks) + 100) == -1)
      {
         Print("Failed to resize tick array");
         return;
      }
   }

   for(int i = m_tickCount; i > 0; i--)
      m_ticks[i] = m_ticks[i-1];

   m_ticks[0].price = price;
   m_ticks[0].time = tickTime;
   m_ticks[0].weight = 1.0;
   m_tickCount++;
}

//+------------------------------------------------------------------+
//| Update time-decayed weights                                      |
//+------------------------------------------------------------------+
void UpdateWeights()
{
   datetime now = TimeCurrent();
   for(int i = 0; i < m_tickCount; i++)
   {
      // FIX: Ensure non-negative age
      int age = (int)(now - m_ticks[i].time);
      if(age < 0) age = 0;
      m_ticks[i].weight = 1.0 / (age + 1.0);
   }
}

//+------------------------------------------------------------------+
//| Clean old ticks                                                  |
//+------------------------------------------------------------------+
void CleanOldTicks()
{
   datetime now = TimeCurrent();
   int maxAge = MathMax(1, InpMaxTickAge);
   int valid = 0;

   for(int i = 0; i < m_tickCount; i++)
   {
      int age = (int)(now - m_ticks[i].time);
      if(age <= maxAge)
         valid++;
   }

   if(m_tickCount - valid < 50) return;

   TickData temp[];
   if(ArrayResize(temp, valid) == -1)
   {
      Print("Failed to resize temp tick array");
      return;
   }

   int idx = 0;
   for(int i = 0; i < m_tickCount; i++)
   {
      int age = (int)(now - m_ticks[i].time);
      if(age <= maxAge)
         temp[idx++] = m_ticks[i];
   }

   // FIX: Resize to fit valid data, not base size
   int newSize = MathMax(InpBaseTickStorage, valid) + 100;
   if(ArrayResize(m_ticks, newSize) == -1)
   {
      Print("Failed to resize tick array after clean");
      return;
   }

   m_tickCount = valid;
   for(int i = 0; i < valid; i++)
      m_ticks[i] = temp[i];

   ArrayFree(temp);
}

//+------------------------------------------------------------------+
//| Update price zones                                               |
//+------------------------------------------------------------------+
void UpdateZones(double price, datetime tickTime)
{
   double pipVal = GetPipValue();
   double tolerance = InpZoneTolerance * pipVal;

   for(int i = 0; i < m_zoneCount; i++)
   {
      if(MathAbs(price - m_zones[i].price) <= tolerance)
      {
         m_zones[i].touches++;
         m_zones[i].lastTouch = tickTime;
         m_zones[i].high = MathMax(m_zones[i].high, price);
         m_zones[i].low = MathMin(m_zones[i].low, price);
         m_zones[i].price = (m_zones[i].high + m_zones[i].low) / 2.0;
         SortZones();
         return;
      }
   }

   if(m_zoneCount >= ArraySize(m_zones)) return;

   m_zones[m_zoneCount].price = price;
   m_zones[m_zoneCount].touches = 1;
   m_zones[m_zoneCount].lastTouch = tickTime;
   m_zones[m_zoneCount].high = price;
   m_zones[m_zoneCount].low = price;
   m_zoneCount++;
   SortZones();
}

//+------------------------------------------------------------------+
//| Sort zones by touches                                            |
//+------------------------------------------------------------------+
void SortZones()
{
   for(int i = 0; i < m_zoneCount - 1; i++)
   {
      for(int j = i + 1; j < m_zoneCount; j++)
      {
         if(m_zones[j].touches > m_zones[i].touches)
         {
            PriceZone tmp = m_zones[i];
            m_zones[i] = m_zones[j];
            m_zones[j] = tmp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Clean old zones                                                  |
//+------------------------------------------------------------------+
void CleanOldZones()
{
   datetime now = TimeCurrent();
   int maxAge = MathMax(1, InpMaxTickAge) * 2;
   int valid = 0;

   for(int i = 0; i < m_zoneCount; i++)
   {
      int age = (int)(now - m_zones[i].lastTouch);
      if(age <= maxAge)
         valid++;
   }

   if(m_zoneCount - valid < 10) return;

   PriceZone tmp[];
   if(ArrayResize(tmp, valid) == -1)
   {
      Print("Failed to resize temp zone array");
      return;
   }

   int idx = 0;
   for(int i = 0; i < m_zoneCount; i++)
   {
      int age = (int)(now - m_zones[i].lastTouch);
      if(age <= maxAge)
         tmp[idx++] = m_zones[i];
   }

   m_zoneCount = valid;
   for(int i = 0; i < valid; i++)
      m_zones[i] = tmp[i];

   ArrayFree(tmp);
}

//+------------------------------------------------------------------+
//| Detect tick direction                                            |
//+------------------------------------------------------------------+
ENUM_TICK_DIR GetTickDir()
{
   if(m_tickCount < 10) return DIR_NONE;

   double sum = 0, wSum = 0;
   int limit = MathMin(m_tickCount, 50);

   for(int i = 1; i < limit; i++)
   {
      double change = m_ticks[i-1].price - m_ticks[i].price;
      double w = m_ticks[i].weight;
      sum += change * w;
      wSum += w;
   }

   if(wSum <= 0) return DIR_NONE;

   double avg = sum / wSum;
   double pipVal = GetPipValue();

   if(avg > InpMomentumThresh * pipVal) return DIR_UP;
   if(avg < -InpMomentumThresh * pipVal) return DIR_DOWN;
   return DIR_SIDEWAYS;
}

//+------------------------------------------------------------------+
//| Get momentum strength 0-1                                        |
//+------------------------------------------------------------------+
double GetMomentum()
{
   if(m_tickCount < 10) return 0;

   double sum = 0, wSum = 0;
   int limit = MathMin(m_tickCount, 50);

   for(int i = 1; i < limit; i++)
   {
      sum += MathAbs(m_ticks[i-1].price - m_ticks[i].price) * m_ticks[i].weight;
      wSum += m_ticks[i].weight;
   }

   if(wSum <= 0) return 0;
   return MathMin(sum / wSum / (10 * GetPipValue()), 1.0);
}

//+------------------------------------------------------------------+
//| Check if price at confirmed zone                                 |
//+------------------------------------------------------------------+
bool AtConfirmedZone(double price)
{
   double pipVal = GetPipValue();
   double tol = InpZoneTolerance * pipVal;

   for(int i = 0; i < m_zoneCount; i++)
   {
      if(m_zones[i].touches >= InpMinTouches &&
         MathAbs(price - m_zones[i].price) <= tol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate dynamic lot                                            |
//+------------------------------------------------------------------+
double CalcLot()
{
   double base = InpLotSize * MathPow(InpLotMultiplier, m_orderCount);

   if(InpLotMode == LOT_FIXED)
      return LimitLot(base);

   double conf = 1.0;
   double price = (m_direction == ORDER_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Zone boost
   if(AtConfirmedZone(price))
   {
      int maxTouches = 0;
      for(int i = 0; i < m_zoneCount; i++)
         if(m_zones[i].touches > maxTouches)
            maxTouches = m_zones[i].touches;

      if(maxTouches >= 5) conf *= 1.4;
      else if(maxTouches >= 4) conf *= 1.2;
   }
   else
   {
      conf *= 0.7;
   }

   // Momentum
   double mom = GetMomentum();
   if(mom > 0.7) conf *= 1.3;
   else if(mom < 0.3) conf *= 0.8;

   // Direction alignment
   ENUM_TICK_DIR dir = GetTickDir();
   if(m_direction == ORDER_TYPE_BUY && dir == DIR_DOWN) conf *= 1.1;
   else if(m_direction == ORDER_TYPE_SELL && dir == DIR_UP) conf *= 1.1;
   else if(dir == DIR_SIDEWAYS) conf *= 0.9;
   else conf *= 0.7;

   return LimitLot(base * conf);
}

//+------------------------------------------------------------------+
//| Apply lot limits                                                 |
//+------------------------------------------------------------------+
double LimitLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // FIX: Safety check for zero lot step
   if(lotStep <= 0) lotStep = 0.01;

   lot = MathMin(lot, InpMaxLotSize);
   lot = MathMin(lot, maxLot);
   lot = MathMax(lot, minLot);
   return MathFloor(lot / lotStep) * lotStep;
}

//+------------------------------------------------------------------+
//| Get pip value                                                    |
//+------------------------------------------------------------------+
double GetPipValue()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3) return 10 * _Point;
   return _Point;
}

//+------------------------------------------------------------------+
//| Restore state                                                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Get broker minimum stop distance in price units                  |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(stopsLevel <= 0 || tickSize <= 0) return 0;

   return stopsLevel * tickSize;
}

void RestoreState()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         m_direction = (ENUM_ORDER_TYPE)m_position.PositionType();
         m_lastAvgPrice = m_position.PriceOpen();
         m_orderCount = CountPos();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Check for setup                                                  |
//+------------------------------------------------------------------+
void CheckForSetup()
{
   double open1 = iOpen(_Symbol, PERIOD_M1, 1);
   double high1 = iHigh(_Symbol, PERIOD_M1, 1);
   double low1 = iLow(_Symbol, PERIOD_M1, 1);

   m_setupBuy = false;
   m_setupSell = false;

   if(CountPos() > 0) return;

   double tol = _Point * 2;

   if(MathAbs(open1 - low1) <= tol && CheckMA(ORDER_TYPE_SELL))
   {
      m_setupSell = true;
      m_direction = ORDER_TYPE_SELL;
      m_orderCount = 0;
      ResetAllData();
      Print("SELL Setup: Open=Low");
   }

   if(MathAbs(open1 - high1) <= tol && CheckMA(ORDER_TYPE_BUY))
   {
      m_setupBuy = true;
      m_direction = ORDER_TYPE_BUY;
      m_orderCount = 0;
      ResetAllData();
      Print("BUY Setup: Open=High");
   }
}

//+------------------------------------------------------------------+
//| Reset all data                                                   |
//+------------------------------------------------------------------+
void ResetAllData()
{
   m_tickCount = 0;
   m_zoneCount = 0;
   m_profitCount = 0;
   m_lossCount = 0;
   m_maxProfit = 0.0;
   m_minLoss = 0.0;
   m_lastProfitHigh = 0;
   m_lastLossImprove = 0;
}

//+------------------------------------------------------------------+
//| MA filter                                                        |
//+------------------------------------------------------------------+
bool CheckMA(ENUM_ORDER_TYPE dir)
{
   if(!InpUseMAFilter) return true;

   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(m_maHandle, 0, 0, 1, ma) <= 0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (dir == ORDER_TYPE_BUY) ? (price > ma[0]) : (price < ma[0]);
}

//+------------------------------------------------------------------+
//| Execute setups                                                   |
//+------------------------------------------------------------------+
void ExecuteSetups()
{
   if(m_setupSell)
   {
      double p = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Order(ORDER_TYPE_SELL, p, InpLotSize);
      m_setupSell = false;
   }
   if(m_setupBuy)
   {
      double p = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      Order(ORDER_TYPE_BUY, p, InpLotSize);
      m_setupBuy = false;
   }
}

//+------------------------------------------------------------------+
//| Place order                                                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Place order with valid stops                                     |
//+------------------------------------------------------------------+
void Order(ENUM_ORDER_TYPE type, double price, double lot)
{
   double sl = 0, tp = 0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickValue <= 0 || tickSize <= 0) return;

   double lossDist = (InpMaxLoss / tickValue) * tickSize;
   double profitDist = (InpMaxProfit / tickValue) * tickSize;

   // FIX: Enforce broker minimum stop distance for XAUUSD and similar symbols
   double minStopDist = GetMinStopDistance();
   double minLossDist = MathMax(lossDist, minStopDist + tickSize);
   double minProfitDist = MathMax(profitDist, minStopDist + tickSize);

   if(type == ORDER_TYPE_BUY)
   {
      sl = price - minLossDist;
      tp = price + minProfitDist;
   }
   else
   {
      sl = price + minLossDist;
      tp = price - minProfitDist;
   }

   // FIX: Normalize to tick size, not just digits (critical for XAUUSD)
   sl = NormalizeDouble(sl / tickSize, 0) * tickSize;
   tp = NormalizeDouble(tp / tickSize, 0) * tickSize;
   price = NormalizeDouble(price / tickSize, 0) * tickSize;

   string comment = StringFormat("OHLv7 #%d", m_orderCount + 1);
   bool result = (type == ORDER_TYPE_BUY) ?
                 m_trade.Buy(lot, _Symbol, price, sl, tp, comment) :
                 m_trade.Sell(lot, _Symbol, price, sl, tp, comment);

   if(result)
   {
      m_lastAvgPrice = price;
      m_orderCount++;
      Print((type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " ", price, " Lot:", lot, " SL:", sl, " TP:", tp);
   }
   else
   {
      Print("Order failed: ", GetLastError());
   }
}

void CheckAveraging()
{
   int total = CountPos();
   if(total == 0 || total >= InpMaxOrders) return;

   double price = (m_direction == ORDER_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lot = CalcLot();
   if(TotalVolume() + lot > InpMaxTotalVolume)
   {
      Print("Max volume reached");
      return;
   }

   bool atZone = AtConfirmedZone(price);
   ENUM_TICK_DIR dir = GetTickDir();
   double mom = GetMomentum();

   bool ok = false;
   if(atZone && (dir == DIR_DOWN || dir == DIR_SIDEWAYS) && m_direction == ORDER_TYPE_BUY)
      ok = true;
   else if(atZone && (dir == DIR_UP || dir == DIR_SIDEWAYS) && m_direction == ORDER_TYPE_SELL)
      ok = true;
   else if(mom > 0.8 && ((dir == DIR_DOWN && m_direction == ORDER_TYPE_BUY) ||
                         (dir == DIR_UP && m_direction == ORDER_TYPE_SELL)))
      ok = true;

   if(!ok) return;

   Order(m_direction, price, lot);
   UpdateGroupSL();
}

//+------------------------------------------------------------------+
//| Total volume                                                     |
//+------------------------------------------------------------------+
double TotalVolume()
{
   double vol = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
         vol += m_position.Volume();
   }
   return vol;
}

//+------------------------------------------------------------------+
//| Update grouped SL                                                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Update grouped SL                                                |
//+------------------------------------------------------------------+
void UpdateGroupSL()
{
   int total = CountPos();
   if(total == 0) return;

   double vol = 0, wPrice = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         vol += m_position.Volume();
         wPrice += m_position.PriceOpen() * m_position.Volume();
      }
   }

   if(vol <= 0) return;
   double avg = wPrice / vol;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   // FIX: Safety check
   if(tickSize <= 0 || tickValue <= 0) return;

   double lossDist = (InpMaxLoss / tickValue) * tickSize;

   // FIX: Enforce minimum stop distance
   double minStopDist = GetMinStopDistance();
   lossDist = MathMax(lossDist, minStopDist + tickSize);

   double sl = (m_direction == ORDER_TYPE_BUY) ? avg - lossDist : avg + lossDist;
   sl = NormalizeDouble(sl / tickSize, 0) * tickSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i) || m_position.Magic() != InpMagicNumber) continue;

      double currSL = m_position.StopLoss();
      bool modify = false;

      if(m_direction == ORDER_TYPE_BUY && (sl > currSL || currSL == 0))
         modify = true;
      else if(m_direction == ORDER_TYPE_SELL && (sl < currSL || currSL == 0))
         modify = true;

      if(modify)
         m_trade.PositionModify(m_position.Ticket(), sl, m_position.TakeProfit());
   }
}

void UpdateTrailingSL()
{
   if(!InpUseTrailingSL || CountPos() == 0) return;

   double price = (m_direction == ORDER_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double avg = AvgEntry();
   if(avg == 0) return;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   // FIX: Safety check
   if(tickSize <= 0 || tickValue <= 0) return;

   double trailDist = (InpMaxLoss * 0.5 / tickValue) * tickSize;

   // FIX: Enforce minimum stop distance
   double minStopDist = GetMinStopDistance();
   trailDist = MathMax(trailDist, minStopDist + tickSize);

   double newSL = 0;
   bool trail = false;

   if(m_direction == ORDER_TYPE_BUY && price - avg > trailDist)
   {
      newSL = price - trailDist;
      trail = true;
   }
   else if(m_direction == ORDER_TYPE_SELL && avg - price > trailDist)
   {
      newSL = price + trailDist;
      trail = true;
   }

   if(!trail) return;
   newSL = NormalizeDouble(newSL / tickSize, 0) * tickSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i) || m_position.Magic() != InpMagicNumber) continue;

      double currSL = m_position.StopLoss();
      bool modify = false;

      if(m_direction == ORDER_TYPE_BUY && (newSL > currSL || currSL == 0))
         modify = true;
      else if(m_direction == ORDER_TYPE_SELL && (newSL < currSL || currSL == 0))
         modify = true;

      if(modify)
         m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
   }
}

double AvgEntry()
{
   double vol = 0, wPrice = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         vol += m_position.Volume();
         wPrice += m_position.PriceOpen() * m_position.Volume();
      }
   }
   return (vol > 0) ? wPrice / vol : 0;
}

//+------------------------------------------------------------------+
//| Auto exit                                                        |
//+------------------------------------------------------------------+
void CheckAutoExit()
{
   if(!InpAutoExit || CountPos() == 0) return;
   double profit = TotalProfit();
   if(profit >= InpMaxProfit * 0.6 && profit > 0)
   {
      Print("Auto exit, profit: ", profit);
      CloseAll();
   }
}

//+------------------------------------------------------------------+
//| Max loss exit                                                    |
//+------------------------------------------------------------------+
void CheckMaxLossExit()
{
   if(CountPos() == 0) return;
   double profit = TotalProfit();
   if(profit <= -InpMaxLoss)
   {
      Print("Max loss: ", profit);
      CloseAll();
   }
}

//+------------------------------------------------------------------+
//| Total profit                                                     |
//+------------------------------------------------------------------+
double TotalProfit()
{
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
         p += m_position.Profit() + m_position.Swap() + m_position.Commission();
   }
   return p;
}

//+------------------------------------------------------------------+
//| Count positions                                                  |
//+------------------------------------------------------------------+
int CountPos()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
         c++;
   return c;
}

//+------------------------------------------------------------------+
//| Close all                                                        |
//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
         m_trade.PositionClose(m_position.Ticket());
   }
   m_orderCount = 0;
   m_lastAvgPrice = 0;
   m_setupBuy = false;
   m_setupSell = false;
   ResetAllData();
}
//+------------------------------------------------------------------+