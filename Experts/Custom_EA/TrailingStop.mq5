
//+------------------------------------------------------------------+
//|                                                 TrailingStop.mq5 |
//|                                        Phattharakorn Mahasorasak |
//|                                       https://github.com/Wnatth3 |
//+------------------------------------------------------------------+
/*
Features of TrailingStop.mq5:
- Supports multiple stop loss strategies: None, Trailing Stop, and Break Even.
- Option to set an initial stop loss when a new position is opened.
- Trailing stop can be activated after a configurable profit trigger is reached.
- Break-even stop loss calculation includes trading fees per lot.
- Can close all positions if account equity drops below a minimum or exceeds a maximum loss percentage.
- Option to close all positions when a profit target is reached (separately for long and short positions).
- Option to close positions that have been held longer than a specified number of bars.
- Automatically deletes all pending orders and removes the expert if risk limits are breached.
- Configurable slippage, profit targets, holding time, and other risk management parameters.
- Supports magic number for filtering positions/orders.
- Detailed logging for debugging and error tracking.
*/

#property copyright "Phattharakorn Mahasorasak"
#property link "https://github.com/Wnatth3"
#property version "1.00"

#include <Trade\Trade.mqh>

// #define RandomTrade
#ifdef RandomTrade
//+------------------------------------------------------------------+
//|  RandomTrade.mq5 - Open up to 5 random trades per 24 hours       |
//+------------------------------------------------------------------+
// input double Lots           = 0.1;  // Lot size
int Slippage = 10;  // Slippage
// input double StopLossPips   = 200;  // Stop loss in points
// input double TakeProfitPips = 400;  // Take profit in points

#define MAX_TRADES_PER_DAY 1

// Store timestamps of trades
datetime tradeTimes[MAX_TRADES_PER_DAY];
int      tradeCount = 0;

//+------------------------------------------------------------------+
//|  Function to check and open random trade                        |
//+------------------------------------------------------------------+
void TryRandomTrade() {
  datetime nowTime = TimeCurrent();

  // Remove trades older than 24h from count
  for (int i = 0; i < tradeCount; i++) {
    if ((nowTime - tradeTimes[i]) > 86400)  // 86400 seconds = 24h
    {
      // Shift array left
      for (int j = i; j < tradeCount - 1; j++)
        tradeTimes[j] = tradeTimes[j + 1];
      tradeCount--;
      i--;  // recheck same index
    }
  }

  // Check if we already reached the daily limit
  if (tradeCount >= MAX_TRADES_PER_DAY)
    return;

  // Random condition: e.g., 1% chance per tick
  if (MathRand() % 1000 == 0) {
    // Pick random direction: 0 = buy, 1 = sell
    bool isBuy = (MathRand() % 2 == 0);

    double price /*, sl, tp*/;
    if (isBuy) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // sl    = price - StopLossPips * _Point;
      // tp    = price + TakeProfitPips * _Point;
      // if (OrderSend(_Symbol, ORDER_TYPE_BUY, Lots, price, Slippage, sl, tp)) {
      if (trade.Buy(0.01, _Symbol, price, 0.0, 0.0, NULL)) {
        Print("Random BUY opened");
        tradeTimes[tradeCount++] = nowTime;
      }
    } else {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      // sl    = price + StopLossPips * _Point;
      // tp    = price - TakeProfitPips * _Point;
      // if (OrderSend(_Symbol, ORDER_TYPE_SELL, Lots, price, Slippage, sl, tp)) {
      if (trade.Sell(0.01, _Symbol, price, 0.0, 0.0, NULL)) {
        Print("Random SELL opened");
        tradeTimes[tradeCount++] = nowTime;
      }
    }
  }
}
#endif

enum initSlType {
  initSlNone,
  initSlFixed,
  initSlAtr
};

enum stopLossType {
  slNone,
  slTrailingStop,
  slBreakEven
};

//----- Input parameters
// trading
input group ">>> Close Position Bot <<<";
input group "Initial Stop Loss Type";
input initSlType inpInitSlType = initSlNone;  // Initial Stop Loss Type: None, Fixed, or ATR (Default = initSlNone)
// input bool inpEnableInitStopLoss = false;  // Enable initial stop loss (Default = false)
input group "Initial Stop Loss: Fixed";
input uint inpInitSlFixed = 2000;  // Initial stop Loss in points (Default = 2000)
input group "Initial Stop Loss: ATR";
input uint   inpAtrPeriod     = 9;    // ATR period for initial stop loss (Default = 9)
input double inpAtrMultiplier = 1.5;  // ATR multiplier for initial stop loss (Default = 1.5)
input group "Stop Loss Type";
input stopLossType inpStopLossType = slNone;  // Type of stop loss: Trailing Stop or Break Even (Default = slNone)
input group "Trailing Stop";
input uint inpTrailingStop    = 1200;  // Trailing stop in points (Default = 1200)
input uint inpTsProfitTrigger = 2000;  // Profit trigger in points (Default = 2000)
input group "Break Even Stop Loss";
input double inpFeePerLot       = 20.0;  // Fee per lot both side of positions in USD (Default = 16.0)
input double inpBeProfitTrigger = 2000;  // Profit trigger in points for break-even stop loss (Default = 2000)
input group "Close Position by Profit";
input bool inpEnableCloseByProfit = false;  // Enable closing by profit (Default = false)
input uint inpProfitTarget        = 2000;   // Profit target in points (Default = 2000)
input group "Close Position by Time";
input bool inpEnableCloseByTime = false;  // Enable closing by time (Default = false)
input uint inpHoldingBar        = 10;     // Position holding time in bars (Default = 10)
input group "Slippage";
input uint inpSlippage = 10;  // Slippage in points (Default = 10)
// risk management
input group "Risk Management";
input double inpMinimumEquity  = 100.0;  // Minimum equity to allow trading (Default = 100.0)
input double inpMaxLossPercent = 20.0;   // Max % loss of balance allowed (Default = 20.0)
// Expert Advisor ID
input group "Expert ID";
input long inpMagicNumber = 121400;  // Magic Number

//----- global variables
// double lot = 0.01;  // Lot (Default = 0.01)
double startingBalance;
int    atrHandle;
//----- Objects
CTrade trade;

int OnInit() {
#ifdef RandomTrade
  MathSrand(GetTickCount());  // Seed random generator
#endif

  startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  Print("Starting balance: ", startingBalance);

  trade.SetDeviationInPoints(inpSlippage);     // slippage
  trade.SetExpertMagicNumber(inpMagicNumber);  // Expert Advisor ID
  trade.LogLevel(LOG_LEVEL_ERRORS);            // logging level

  // double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  // if (!trade.Buy(0.01, _Symbol, price, 0.0, 0.0, NULL)) {
  //   Print("Error opening buy order: ", GetLastError());
  // }

  atrHandle = iATR(_Symbol, PERIOD_CURRENT, inpAtrPeriod);
  if (atrHandle == INVALID_HANDLE) {
    Print("Error creating ATR indicator");
    return (INIT_FAILED);
  }

  return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
  // Deinitialization code here
}

void OnTick() {
  // Check equity limits and clear all positions/orders if breached
  if (AccountInfoDouble(ACCOUNT_EQUITY) <= inpMinimumEquity || CheckEquityLossExceeded()) {
    PrintFormat("⚠️ Equity %.2f below minimum required %.2f", AccountInfoDouble(ACCOUNT_EQUITY), inpMinimumEquity);
    ClearAllPositionsAndOrders();
  }

#ifdef RandomTrade
  TryRandomTrade();
#endif

  if (!HasOpenPosition()) return;

  // if (inpEnableInitStopLoss) SetInitStopLossFixed();
  switch (inpInitSlType) {
    case initSlFixed: SetInitStopLossFixed(); break;
    case initSlAtr: SetInitStopLossAtr(); break;
    default: break;  // No action for slInitNone
  }

  if (inpEnableCloseByProfit) CloseByProfit();

  if (inpEnableCloseByTime) ClosePositionsExceededTime();

  switch (inpStopLossType) {
    case slTrailingStop: ApplyTrailingStop(); break;
    case slBreakEven: ApplyStopLossAtBreakEven(); break;
    default: break;  // No action for slNone
  }
}

bool CheckEquityLossExceeded() {
  double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  double limitEquity   = startingBalance * (1.0 - (inpMaxLossPercent / 100.0f));
  return currentEquity <= limitEquity;
}

void ClearAllPositionsAndOrders() {
  // Close all open positions if there are any
  int positions = PositionsTotal();
  if (positions > 0) {
    for (int i = positions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (ticket != 0) {
        if (!trade.PositionClose(ticket, inpSlippage))
          PrintFormat("Failed to close position: %I64u, Error: %d", ticket, GetLastError());
        // else  PrintFormat("Position %I64u closed successfully at %f", ticket, SymbolInfoDouble(_Symbol, SYMBOL_BID));
      }
    }
  }
  // Delete all pending orders only if there are any
  int orders = OrdersTotal();
  if (orders > 0) {
    for (int i = orders - 1; i >= 0; i--) {
      // ulong ticket = OrderGetTicket(i);
      if (OrderGetTicket(i) != 0) {
        if (!trade.OrderDelete(OrderGetTicket(i)))
          PrintFormat("Failed to delete order: %I64u, Error: %d", OrderGetTicket(i), GetLastError());
        // else PrintFormat("Order %I64u deleted successfully", ticket);
      }
    }
  }
  // ExpertRemove(); // Remove the expert from the chart
}

bool HasOpenPosition() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) != 0) {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
    }
  }
  return false;
}

void SetInitStopLossFixed() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;  // Skip if failed to get position
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long   type       = PositionGetInteger(POSITION_TYPE);
    double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
    double stopLoss   = PositionGetDouble(POSITION_SL);
    double takeProfit = PositionGetDouble(POSITION_TP);
    if (stopLoss == 0.0) {
      double newStop = 0.0;
      if (type == POSITION_TYPE_BUY) newStop = openPrice - inpInitSlFixed * point;
      else if (type == POSITION_TYPE_SELL) newStop = openPrice + inpInitSlFixed * point;

      if (!trade.PositionModify(PositionGetTicket(i), newStop, takeProfit))
        PrintFormat("Failed to set initial stop loss for position: %I64u, Error: %d", PositionGetTicket(i), GetLastError());
      // else PrintFormat("Initial fixed stop loss set for position: %I64u at %f", PositionGetTicket(i), newStop);
    }
  }
}

double Atr() {
  double indicator_values[];
  if (CopyBuffer(atrHandle, 0, 0, 1, indicator_values) < 0) {
    PrintFormat("Failed to copy data from the ATR indicator, error code %d", GetLastError());
    return (EMPTY_VALUE);
  }
  return (indicator_values[0]);
}

void SetInitStopLossAtr() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;  // Skip if failed to get position
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long   type       = PositionGetInteger(POSITION_TYPE);
    double atr        = Atr();
    double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
    double stopLoss   = PositionGetDouble(POSITION_SL);
    double takeProfit = PositionGetDouble(POSITION_TP);
    if (stopLoss == 0.0) {
      double newStop = 0.0;
      if (type == POSITION_TYPE_BUY) newStop = openPrice - atr * inpAtrMultiplier;
      else if (type == POSITION_TYPE_SELL) newStop = openPrice + atr * inpAtrMultiplier;
      PrintFormat("ATR: %f | Stop loss: %f | Take profit: %f | Multiplier: %f | Point: %f", atr, newStop, takeProfit, inpAtrMultiplier, point);

      if (!trade.PositionModify(PositionGetTicket(i), newStop, takeProfit))
        PrintFormat("Failed to set initial stop loss for position: %I64u, Error: %d", PositionGetTicket(i), GetLastError());
      // else PrintFormat("Initial ATR stop loss set for position: %I64u at %f", PositionGetTicket(i), newStop);
    }
  }
}

void CloseByProfit() {
  // Calculate total profit and count for long and short positions separately
  double totalLongProfit  = 0.0;
  double totalShortProfit = 0.0;
  int    longCount        = 0;
  int    shortCount       = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long type = PositionGetInteger(POSITION_TYPE);
    if (type == POSITION_TYPE_BUY) {
      totalLongProfit += PositionGetDouble(POSITION_PROFIT);
      longCount++;
    } else if (type == POSITION_TYPE_SELL) {
      totalShortProfit += PositionGetDouble(POSITION_PROFIT);
      shortCount++;
    }
  }
  // Print counts for debugging
  PrintFormat("Long positions: %d, Short positions: %d", longCount, shortCount);

  // Close all long positions if their total profit reaches/exceeds the target
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (totalLongProfit >= longCount * inpProfitTarget * point) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) == 0) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        if (!trade.PositionClose(PositionGetTicket(i), inpSlippage))
          PrintFormat("Failed to close long position %I64u by total profit, Error: %d", PositionGetTicket(i), GetLastError());
      // else PrintFormat("Long Position %I64u closed due to profit target reached at %G", PositionGetTicket(i)), PositionGetDouble(POSITION_PRICE_CURRENT));
    }
  }
  // Close all short positions if their total profit reaches/exceeds the target
  if (totalShortProfit >= shortCount * inpProfitTarget * point) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) == 0) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        if (!trade.PositionClose(PositionGetTicket(i), inpSlippage))
          PrintFormat("Failed to close short position %I64u by total profit, Error: %d", PositionGetTicket(i), GetLastError());
      // else PrintFormat("Short Position %I64u closed due to profit target reached at %G", PositionGetTicket(i)), PositionGetDouble(POSITION_PRICE_CURRENT));
    }
  }
}

void ClosePositionsExceededTime() {
  datetime currentTime = TimeCurrent();
  int      barsToHold  = (int)inpHoldingBar;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    datetime openTime   = (datetime)PositionGetInteger(POSITION_TIME);
    int      openBar    = iBarShift(_Symbol, PERIOD_CURRENT, openTime, false);
    int      currentBar = iBarShift(_Symbol, PERIOD_CURRENT, currentTime, false);
    if (currentBar - openBar > barsToHold) {
      if (!trade.PositionClose(PositionGetTicket(i), inpSlippage)) {
        string stringType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        PrintFormat("Failed to close %s position by time position: %I64u, Error: %d", stringType, PositionGetTicket(i), GetLastError());
        // else PrintFormat("%s Position %I64u closed due to holding time exceeded (%d bars)", stringType, PositionGetTicket(i), barsHeld);
      }
    }
  }
}

void ApplyTrailingStop() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long   type            = PositionGetInteger(POSITION_TYPE);
    double point           = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double openPrice       = PositionGetDouble(POSITION_PRICE_OPEN);
    double stopLoss        = PositionGetDouble(POSITION_SL);
    double profitTrigger   = (type == POSITION_TYPE_BUY) ? openPrice + inpTsProfitTrigger * point : openPrice - inpTsProfitTrigger * point;
    double currPrice       = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    bool   triggerReached  = (type == POSITION_TYPE_BUY) ? (currPrice >= profitTrigger) : (currPrice <= profitTrigger);
    double newStopLoss     = (type == POSITION_TYPE_BUY) ? currPrice - inpTrailingStop * point : currPrice + inpTrailingStop * point;
    bool   stopLossUpdated = (type == POSITION_TYPE_BUY) ? (newStopLoss > stopLoss) : (newStopLoss < stopLoss);
    if (triggerReached && stopLossUpdated) {
      double takeProfit = PositionGetDouble(POSITION_TP);
      if (!trade.PositionModify(PositionGetTicket(i), newStopLoss, takeProfit)) {
        string stringType = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        PrintFormat("Failed to modify trailing stop for %s position #%I64u, error=%d", stringType, PositionGetTicket(i), GetLastError());
      }  // else PrintFormat("%s Position %I64u trailing stop modified to %f", tType, PositionGetTicket(i), newStopLoss);
    }
  }
}

void ApplyStopLossAtBreakEven() {
  // Calculate break-even prices for long and short positions
  double totalLongVolume = 0.0, totalShortVolume = 0.0;
  double totalLongCost = 0.0, totalShortCost = 0.0;
  double totalLongFee = 0.0, totalShortFee = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long   type      = PositionGetInteger(POSITION_TYPE);
    double volume    = PositionGetDouble(POSITION_VOLUME);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    if (type == POSITION_TYPE_BUY) {
      totalLongVolume += volume;
      totalLongCost += openPrice * volume;
      totalLongFee += inpFeePerLot * volume;
    } else if (type == POSITION_TYPE_SELL) {
      totalShortVolume += volume;
      totalShortCost += openPrice * volume;
      totalShortFee += inpFeePerLot * volume;
    }
  }
  // PrintFormat("totalLongVolume: %f | totalLongCost: %f | totalLongFee: %f", totalLongVolume, totalLongCost, totalLongFee);
  double longBreakEven  = (totalLongVolume > 0.0) ? (totalLongCost / totalLongVolume + totalLongFee) : 0.0;
  double shortBreakEven = (totalShortVolume > 0.0) ? (totalShortCost / totalShortVolume - totalShortFee) : 0.0;
  // PrintFormat("*Long Break Even: %f | Short Break Even: %f", longBreakEven, shortBreakEven);

  // Set stop loss for each position at its break-even price
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionGetTicket(i) == 0) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    long   type            = PositionGetInteger(POSITION_TYPE);
    double point           = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double openPrice       = PositionGetDouble(POSITION_PRICE_OPEN);
    double stopLoss        = PositionGetDouble(POSITION_SL);
    double profitTrigger   = (type == POSITION_TYPE_BUY) ? openPrice + inpBeProfitTrigger * point : openPrice - inpBeProfitTrigger * point;
    double currPrice       = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    bool   triggerReached  = (type == POSITION_TYPE_BUY) ? (currPrice >= profitTrigger) : (currPrice <= profitTrigger);
    double newStopLoss     = (type == POSITION_TYPE_BUY) ? longBreakEven : shortBreakEven;
    bool   stopLossUpdated = (type == POSITION_TYPE_BUY) ? (newStopLoss > stopLoss) : (newStopLoss < stopLoss);
    if (triggerReached && stopLossUpdated) {
      double takeProfit = PositionGetDouble(POSITION_TP);
      PrintFormat("***OpenPrice: %f | ProfitTrigger: %f | Break Even stoploss: %f | Current price: %f", openPrice, profitTrigger, newStopLoss, currPrice);
      if (!trade.PositionModify(PositionGetTicket(i), newStopLoss, takeProfit)) {
        string stringType = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        PrintFormat("Failed to set break-even SL for %s position %I64u, Error: %d", stringType, PositionGetTicket(i), GetLastError());
      }  // else PrintFormat("Break-even SL set for %s position %I64u at %f", stringType, PositionGetTicket(i), newStopLoss);
    }
  }
}