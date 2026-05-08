//+------------------------------------------------------------------+
//|                                       OpenLowHighEA_v4.mq5       |
//|                        Open=Low/High Strategy with Loss Saver    |
//|                        + Trailing SL + Dynamic SL + Trend Filter |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "4.00"
#property strict

//--- Input Parameters
input group "=== Trade Settings ==="
input double   InpMaxProfitUSD = 100.0;      // Maximum Profit (USD/Account Currency)
input double   InpMaxLossUSD = 50.0;         // Maximum Loss (USD/Account Currency)

input group "=== Loss Saver (Breakeven) ==="
input bool     InpUseLossSaver = true;       // Use Loss Saver (Move SL to Entry)
input double   InpLossSaverThreshold = 20.0;  // Loss Saver Threshold (USD) - Move SL to breakeven when profit reaches this

input group "=== Trailing SL ==="
input double   InpTrailingThreshold = 50.0;   // Trailing SL Threshold (% of Max Profit)
input double   InpTrailingStep = 10.0;        // Trailing Step (points)

input group "=== Trend Filter ==="
input bool     InpUseTrendFilter = true;     // Use Moving Average Filter
input int      InpMAPeriod = 50;             // Moving Average Period
input ENUM_MA_METHOD InpMAMethod = MODE_EMA; // MA Method
input ENUM_APPLIED_PRICE InpMAAppliedPrice = PRICE_CLOSE; // MA Applied Price

input group "=== Dynamic SL Settings ==="
input bool     InpUseDynamicSL = false;      // Use Dynamic SL (Exit on continuous adverse move)
input int      InpDynamicSLBars = 3;       // Dynamic SL: Exit after N consecutive adverse bars

input group "=== Order Settings ==="
input int      InpMagicNumber = 123456;    // Magic Number
input int      InpSlippage = 30;            // Slippage (points)
input string   InpTradeComment = "OLH_EA"; // Trade Comment

//--- Global Variables
int            g_maHandle = INVALID_HANDLE;
datetime       g_lastBarTime = 0;
bool           g_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
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

   //--- Print symbol info for debugging
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   Print("=== OpenLowHigh EA v4.0 Initialized ===");
   Print("Symbol: ", _Symbol, " | Digits: ", _Digits, " | Point: ", _Point);
   Print("Stop Level: ", stopLevel, " | Tick Size: ", tickSize, " | Tick Value: ", tickValue);
   Print("Min Lot: ", minLot, " | Lot Step: ", lotStep);
   Print("Max Profit: $", InpMaxProfitUSD, " | Max Loss: $", InpMaxLossUSD);
   Print("Loss Saver: ", InpUseLossSaver ? "ENABLED" : "DISABLED", 
         " | Threshold: $", InpLossSaverThreshold);
   Print("Trailing SL: Threshold ", InpTrailingThreshold, "% | Step: ", InpTrailingStep, " points");
   Print("Trend Filter: ", InpUseTrendFilter ? "ENABLED" : "DISABLED");
   Print("Dynamic SL: ", InpUseDynamicSL ? "ENABLED" : "DISABLED");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);

   Print("=== OpenLowHigh EA v4.0 Deinitialized ===");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_initialized) return;

   //--- Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
   {
      //--- Even if no new bar, manage SL systems
      ManageLossSaver();
      ManageTrailingSL();
      if(InpUseDynamicSL)
         ManageDynamicSL();
      return;
   }

   //--- New bar formed - update last bar time
   g_lastBarTime = currentBarTime;

   //--- Check if we already have positions open
   if(CountOpenPositions() > 0)
   {
      //--- Manage existing positions
      ManageLossSaver();
      ManageTrailingSL();
      if(InpUseDynamicSL)
         ManageDynamicSL();
      return;
   }

   //--- Analyze previous completed candle (index 1)
   double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double prevLow = iLow(_Symbol, PERIOD_CURRENT, 1);
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   //--- Check for valid prices
   if(prevOpen == 0 || prevHigh == 0 || prevLow == 0)
      return;

   //--- Get current price
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Get MA value for trend filter
   double maValue = 0;
   bool trendBullish = false;
   bool trendBearish = false;

   if(InpUseTrendFilter)
   {
      double maBuffer[];
      ArraySetAsSeries(maBuffer, true);
      if(CopyBuffer(g_maHandle, 0, 0, 2, maBuffer) <= 0)
      {
         Print("Error copying MA buffer. Error: ", GetLastError());
         return;
      }
      maValue = maBuffer[1]; // Previous bar's MA value

      trendBullish = (prevClose > maValue);
      trendBearish = (prevClose < maValue);
   }
   else
   {
      //--- No trend filter, allow both directions
      trendBullish = true;
      trendBearish = true;
   }

   //--- Define tolerance for comparing prices (in points)
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tolerance = point * 2; // 2 points tolerance

   //--- Check for Open = Low (Bearish Pin Bar / Sell Signal)
   bool isOpenLow = (MathAbs(prevOpen - prevLow) <= tolerance);

   //--- Check for Open = High (Bullish Pin Bar / Buy Signal)
   bool isOpenHigh = (MathAbs(prevOpen - prevHigh) <= tolerance);

   //--- Execute SELL order if Open = Low and trend is bearish (or filter disabled)
   if(isOpenLow && trendBearish)
   {
      //--- For SELL: TP = Open price of signal candle (prevOpen)
      double tpPrice = NormalizeDouble(prevOpen, _Digits);

      //--- Calculate lot size and SL together to ensure valid stops
      double lotSize = 0;
      double slPrice = CalculateSellSLAndLot(tpPrice, InpMaxLossUSD, lotSize);

      if(lotSize > 0 && slPrice > 0)
      {
         //--- Validate stops before sending
         if(ValidateStops(ORDER_TYPE_SELL, currentBid, slPrice, tpPrice))
         {
            OpenSellOrder(lotSize, slPrice, tpPrice);
         }
         else
         {
            Print("SELL stops validation failed. Bid: ", currentBid, " SL: ", slPrice, " TP: ", tpPrice);
         }
      }
   }

   //--- Execute BUY order if Open = High and trend is bullish (or filter disabled)
   if(isOpenHigh && trendBullish)
   {
      //--- For BUY: TP = Open price of signal candle (prevOpen)
      double tpPrice = NormalizeDouble(prevOpen, _Digits);

      //--- Calculate lot size and SL together to ensure valid stops
      double lotSize = 0;
      double slPrice = CalculateBuySLAndLot(tpPrice, InpMaxLossUSD, lotSize);

      if(lotSize > 0 && slPrice > 0)
      {
         //--- Validate stops before sending
         if(ValidateStops(ORDER_TYPE_BUY, currentAsk, slPrice, tpPrice))
         {
            OpenBuyOrder(lotSize, slPrice, tpPrice);
         }
         else
         {
            Print("BUY stops validation failed. Ask: ", currentAsk, " SL: ", slPrice, " TP: ", tpPrice);
         }
      }
   }

   //--- Manage SL systems for any open positions
   ManageLossSaver();
   ManageTrailingSL();
   if(InpUseDynamicSL)
      ManageDynamicSL();
}

//+------------------------------------------------------------------+
//| Calculate SL and Lot Size for SELL order                         |
//| Returns SL price, sets lotSize by reference                      |
//+------------------------------------------------------------------+
double CalculateSellSLAndLot(double tpPrice, double maxLossUSD, double &lotSize)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(tickValue <= 0)
   {
      Print("Error: Tick value is zero or negative");
      return 0;
   }

   //--- Get current price for entry reference
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- For SELL: TP is BELOW entry (prevOpen), SL is ABOVE entry
   //--- TP distance = bid - tpPrice (should be positive for valid SELL)
   double tpDistance = bid - tpPrice;

   //--- Ensure TP is below entry for SELL
   if(tpDistance <= 0)
   {
      Print("Invalid SELL setup: TP (", tpPrice, ") is not below entry (", bid, ")");
      return 0;
   }

   //--- Calculate minimum SL distance based on stop level
   double minSLDistance = MathMax(stopLevel, tickSize);

   //--- SL must be at least minSLDistance above entry for SELL
   double slPrice = bid + minSLDistance;

   //--- Calculate lot size based on TP distance and max profit
   //--- Profit = lotSize * (tpDistance / tickSize) * tickValue = maxProfitUSD
   lotSize = InpMaxProfitUSD / ((tpDistance / tickSize) * tickValue);

   //--- Round to lot step and constrain
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   //--- Now recalculate SL based on actual lot size and max loss
   //--- Loss = lotSize * (slDistance / tickSize) * tickValue = maxLossUSD
   double slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;

   //--- Ensure SL distance meets minimum requirements
   slDistance = MathMax(slDistance, minSLDistance);

   //--- For SELL: SL = entry + slDistance
   slPrice = bid + slDistance;

   //--- Final validation: SL must be above entry, TP below entry
   if(slPrice <= bid || tpPrice >= bid)
   {
      Print("Invalid SELL stop levels. SL: ", slPrice, " Entry: ", bid, " TP: ", tpPrice);
      return 0;
   }

   //--- Check margin
   double marginRequired;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, lotSize, bid, marginRequired))
   {
      Print("Error calculating margin. Error: ", GetLastError());
      return 0;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.9)
   {
      Print("Warning: Insufficient margin. Required: ", marginRequired, " Free: ", freeMargin);
      //--- Reduce lot size to fit margin
      lotSize = (freeMargin * 0.9 / marginRequired) * lotSize;
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(lotSize, minLot);

      //--- Recalculate SL with new lot size
      slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
      slDistance = MathMax(slDistance, minSLDistance);
      slPrice = bid + slDistance;
   }

   return NormalizeDouble(slPrice, _Digits);
}

//+------------------------------------------------------------------+
//| Calculate SL and Lot Size for BUY order                          |
//| Returns SL price, sets lotSize by reference                      |
//+------------------------------------------------------------------+
double CalculateBuySLAndLot(double tpPrice, double maxLossUSD, double &lotSize)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(tickValue <= 0)
   {
      Print("Error: Tick value is zero or negative");
      return 0;
   }

   //--- Get current price for entry reference
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- For BUY: TP is ABOVE entry (prevOpen), SL is BELOW entry
   //--- TP distance = tpPrice - ask (should be positive for valid BUY)
   double tpDistance = tpPrice - ask;

   //--- Ensure TP is above entry for BUY
   if(tpDistance <= 0)
   {
      Print("Invalid BUY setup: TP (", tpPrice, ") is not above entry (", ask, ")");
      return 0;
   }

   //--- Calculate minimum SL distance based on stop level
   double minSLDistance = MathMax(stopLevel, tickSize);

   //--- SL must be at least minSLDistance below entry for BUY
   double slPrice = ask - minSLDistance;

   //--- Calculate lot size based on TP distance and max profit
   lotSize = InpMaxProfitUSD / ((tpDistance / tickSize) * tickValue);

   //--- Round to lot step and constrain
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   //--- Now recalculate SL based on actual lot size and max loss
   double slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;

   //--- Ensure SL distance meets minimum requirements
   slDistance = MathMax(slDistance, minSLDistance);

   //--- For BUY: SL = entry - slDistance
   slPrice = ask - slDistance;

   //--- Final validation: SL must be below entry, TP above entry
   if(slPrice >= ask || tpPrice <= ask)
   {
      Print("Invalid BUY stop levels. SL: ", slPrice, " Entry: ", ask, " TP: ", tpPrice);
      return 0;
   }

   //--- Check margin
   double marginRequired;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize, ask, marginRequired))
   {
      Print("Error calculating margin. Error: ", GetLastError());
      return 0;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.9)
   {
      Print("Warning: Insufficient margin. Required: ", marginRequired, " Free: ", freeMargin);
      //--- Reduce lot size to fit margin
      lotSize = (freeMargin * 0.9 / marginRequired) * lotSize;
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(lotSize, minLot);

      //--- Recalculate SL with new lot size
      slDistance = (maxLossUSD / lotSize) * tickSize / tickValue;
      slDistance = MathMax(slDistance, minSLDistance);
      slPrice = ask - slDistance;
   }

   return NormalizeDouble(slPrice, _Digits);
}

//+------------------------------------------------------------------+
//| Validate Stop Levels before sending order                        |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE orderType, double entryPrice, double slPrice, double tpPrice)
{
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minDistance = MathMax(stopLevel, tickSize);

   if(orderType == ORDER_TYPE_BUY)
   {
      //--- For BUY: SL < Entry < TP
      //--- SL must be below entry by at least minDistance
      if((entryPrice - slPrice) < minDistance)
      {
         Print("BUY SL too close to entry. Distance: ", entryPrice - slPrice, " Min: ", minDistance);
         return false;
      }
      //--- TP must be above entry by at least minDistance
      if((tpPrice - entryPrice) < minDistance)
      {
         Print("BUY TP too close to entry. Distance: ", tpPrice - entryPrice, " Min: ", minDistance);
         return false;
      }
      //--- SL must be below TP
      if(slPrice >= tpPrice)
      {
         Print("BUY SL >= TP. SL: ", slPrice, " TP: ", tpPrice);
         return false;
      }
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      //--- For SELL: TP < Entry < SL
      //--- SL must be above entry by at least minDistance
      if((slPrice - entryPrice) < minDistance)
      {
         Print("SELL SL too close to entry. Distance: ", slPrice - entryPrice, " Min: ", minDistance);
         return false;
      }
      //--- TP must be below entry by at least minDistance
      if((entryPrice - tpPrice) < minDistance)
      {
         Print("SELL TP too close to entry. Distance: ", entryPrice - tpPrice, " Min: ", minDistance);
         return false;
      }
      //--- SL must be above TP
      if(slPrice <= tpPrice)
      {
         Print("SELL SL <= TP. SL: ", slPrice, " TP: ", tpPrice);
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Manage Loss Saver - Move SL to Breakeven at threshold            |
//+------------------------------------------------------------------+
void ManageLossSaver()
{
   if(!InpUseLossSaver) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      //--- Check if position belongs to this EA
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);

      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

      //--- Calculate current profit in account currency
      double currentProfit = 0;
      double currentPrice = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double priceDiff = currentPrice - openPrice;
         currentProfit = (priceDiff / tickSize) * tickValue * lotSize;
      }
      else // POSITION_TYPE_SELL
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double priceDiff = openPrice - currentPrice;
         currentProfit = (priceDiff / tickSize) * tickValue * lotSize;
      }

      //--- Check if profit has reached Loss Saver threshold
      if(currentProfit >= InpLossSaverThreshold)
      {
         double newSL = 0;
         bool moveToBreakeven = false;

         if(posType == POSITION_TYPE_BUY)
         {
            //--- For BUY: SL should be at or below entry price (breakeven)
            //--- Only move if SL is currently below entry (not yet at breakeven)
            if(currentSL < openPrice)
            {
               newSL = openPrice;
               moveToBreakeven = true;
            }
         }
         else // POSITION_TYPE_SELL
         {
            //--- For SELL: SL should be at or above entry price (breakeven)
            //--- Only move if SL is currently above entry (not yet at breakeven)
            if(currentSL > openPrice || currentSL == 0)
            {
               newSL = openPrice;
               moveToBreakeven = true;
            }
         }

         //--- Move SL to breakeven if needed
         if(moveToBreakeven && newSL > 0)
         {
            newSL = NormalizeDouble(newSL, _Digits);

            //--- Ensure minimum distance from current price for broker compliance
            if(posType == POSITION_TYPE_BUY)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double minDistance = MathMax(stopLevel, tickSize);
               if((bid - newSL) < minDistance)
               {
                  newSL = bid - minDistance;
                  newSL = NormalizeDouble(newSL, _Digits);
               }
            }
            else
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double minDistance = MathMax(stopLevel, tickSize);
               if((newSL - ask) < minDistance)
               {
                  newSL = ask + minDistance;
                  newSL = NormalizeDouble(newSL, _Digits);
               }
            }

            //--- Only modify if SL has actually changed
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

               if(!OrderSend(request, result))
               {
                  Print("Loss Saver modification failed. Error: ", GetLastError());
               }
               else if(result.retcode == TRADE_RETCODE_DONE)
               {
                  Print("=== LOSS SAVER ACTIVATED === Ticket: ", ticket, 
                        " | SL moved to BREAKEVEN: ", newSL,
                        " | Current Profit: $", DoubleToString(currentProfit, 2),
                        " | Threshold: $", InpLossSaverThreshold);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop Loss                                        |
//+------------------------------------------------------------------+
void ManageTrailingSL()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      //--- Check if position belongs to this EA
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double lotSize = PositionGetDouble(POSITION_VOLUME);

      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

      //--- Calculate current profit in account currency
      double currentProfit = 0;
      double currentPrice = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double priceDiff = currentPrice - openPrice;
         currentProfit = (priceDiff / tickSize) * tickValue * lotSize;
      }
      else // POSITION_TYPE_SELL
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double priceDiff = openPrice - currentPrice;
         currentProfit = (priceDiff / tickSize) * tickValue * lotSize;
      }

      //--- Calculate trailing threshold in USD
      double trailingThresholdUSD = InpMaxProfitUSD * (InpTrailingThreshold / 100.0);

      //--- Check if profit has reached trailing threshold
      if(currentProfit >= trailingThresholdUSD)
      {
         double newSL = 0;
         bool modifySL = false;

         if(posType == POSITION_TYPE_BUY)
         {
            //--- Phase 1: If SL is still below entry, move to breakeven first
            if(currentSL < openPrice)
            {
               newSL = openPrice;
               modifySL = true;
            }
            //--- Phase 2: Trail if profit exceeds threshold and SL is already at or above breakeven
            else if(currentProfit > trailingThresholdUSD && currentSL >= openPrice)
            {
               double trailSL = currentPrice - (InpTrailingStep * _Point);
               trailSL = NormalizeDouble(trailSL, _Digits);

               //--- Ensure minimum distance from current price
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
         else // POSITION_TYPE_SELL
         {
            //--- Phase 1: If SL is still above entry, move to breakeven first
            if(currentSL > openPrice || currentSL == 0)
            {
               newSL = openPrice;
               modifySL = true;
            }
            //--- Phase 2: Trail if profit exceeds threshold and SL is already at or below breakeven
            else if(currentProfit > trailingThresholdUSD && (currentSL <= openPrice || currentSL == 0))
            {
               double trailSL = currentPrice + (InpTrailingStep * _Point);
               trailSL = NormalizeDouble(trailSL, _Digits);

               //--- Ensure minimum distance from current price
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

         //--- Modify SL if needed
         if(modifySL && newSL > 0)
         {
            newSL = NormalizeDouble(newSL, _Digits);

            //--- Only modify if SL has actually changed meaningfully
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

               if(!OrderSend(request, result))
               {
                  Print("Trailing SL modification failed. Error: ", GetLastError());
               }
               else if(result.retcode == TRADE_RETCODE_DONE)
               {
                  Print("Trailing SL updated. Ticket: ", ticket, 
                        " | New SL: ", newSL, 
                        " | Current Profit: $", DoubleToString(currentProfit, 2));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Dynamic SL - Exit on continuous adverse movement          |
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

      //--- Count consecutive adverse bars since position open
      int adverseBars = 0;
      int totalBars = iBars(_Symbol, PERIOD_CURRENT);

      //--- Find the bar index when position was opened
      int startBar = iBarShift(_Symbol, PERIOD_CURRENT, openTime, false);
      if(startBar < 0) startBar = 1;

      //--- Check last N bars after position open
      int barsToCheck = MathMin(InpDynamicSLBars, totalBars - startBar);

      for(int b = 1; b <= barsToCheck; b++)
      {
         int barIndex = startBar + b;
         if(barIndex >= totalBars) break;

         double barOpen = iOpen(_Symbol, PERIOD_CURRENT, barIndex);
         double barClose = iClose(_Symbol, PERIOD_CURRENT, barIndex);

         bool isAdverse = false;

         if(posType == POSITION_TYPE_BUY)
            isAdverse = (barClose < barOpen); // Bearish bar = adverse for BUY
         else
            isAdverse = (barClose > barOpen); // Bullish bar = adverse for SELL

         if(isAdverse)
            adverseBars++;
         else
            break;
      }

      //--- If N consecutive adverse bars, close position
      if(adverseBars >= InpDynamicSLBars)
      {
         Print("Dynamic SL triggered. Ticket: ", ticket, 
               " | Consecutive adverse bars: ", adverseBars);
         ClosePosition(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Close Position                                                   |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
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

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = volume;
   request.deviation = InpSlippage;
   request.magic = InpMagicNumber;

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
      Print("Position closed. Ticket: ", ticket);
      return true;
   }

   Print("Close position failed. Retcode: ", result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Open BUY Order                                                   |
//+------------------------------------------------------------------+
bool OpenBuyOrder(double lotSize, double slPrice, double tpPrice)
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
   request.comment = InpTradeComment;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("Buy OrderSend failed. Error: ", GetLastError());
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("BUY Order executed. Ticket: ", result.order, 
            " | Lot: ", lotSize, 
            " | Entry: ", ask,
            " | SL: ", slPrice, 
            " | TP: ", tpPrice);
      return true;
   }
   else
   {
      Print("Buy Order failed. Retcode: ", result.retcode);
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open SELL Order                                                  |
//+------------------------------------------------------------------+
bool OpenSellOrder(double lotSize, double slPrice, double tpPrice)
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
   request.comment = InpTradeComment;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("Sell OrderSend failed. Error: ", GetLastError());
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("SELL Order executed. Ticket: ", result.order, 
            " | Lot: ", lotSize, 
            " | Entry: ", bid,
            " | SL: ", slPrice, 
            " | TP: ", tpPrice);
      return true;
   }
   else
   {
      Print("Sell Order failed. Retcode: ", result.retcode);
      return false;
   }
}

//+------------------------------------------------------------------+
//| Count Open Positions for this EA                                 |
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
      {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get Appropriate Filling Mode                                     |
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
