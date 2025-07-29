
//+------------------------------------------------------------------+
//|                                             Engulfing_StoRsi.mq5 |
//|                                        Phattharakorn Mahasorasak |
//|                                       https://github.com/Wnatth3 |
//+------------------------------------------------------------------+
/*
Features of Engulfing_StoRSI.mq5:

- Detects Bullish and Bearish Engulfing candlestick patterns.
- Confirms signals using a custom Stochastic RSI indicator (K & D lines).
- Opens Buy/Sell positions based on detected and confirmed signals.
- Supports position closing by signal, by holding time (bars), or by equity loss.
- Implements trailing stop and standard SL/TP management.
- Money management: minimum equity, max loss percent, fixed lot size.
- Handles all positions/orders for the EA's magic number and symbol.
- Uses a trend filter via Simple Moving Average (SMA).
- Prints detailed pattern and confirmation info to the log.
- Modular functions for pattern detection, confirmation, position management, and indicator access.
*/
#property copyright "Phattharakorn Mahasorasak"
#property link "https://github.com/Wnatth3"
#property version "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

#define SIGNAL_BUY  1   // Buy signal
#define SIGNAL_NOT  0   // no trading signal
#define SIGNAL_SELL -1  // Sell signal

#define CLOSE_LONG  2   // signal to close Long
#define CLOSE_SHORT -2  // signal to close Short

//--- Input parameters
input int                InpAverBodyPeriod = 12;           // period for calculating average candlestick size (Default = 12)
input int                InpMAPeriod       = 5;            // Trend MA period (Default = 5)
input int                inpK              = 3;            // K (Default = 3)
input int                inpD              = 3;            // D (Default = 3)
input int                inpRsiPeriod      = 14;           // RSI period (Default = 14)
input int                inpStoPeriod      = 14;           // Stochastic period (Default = 14)
input ENUM_APPLIED_PRICE inpAppliedPrice   = PRICE_CLOSE;  // RSI Applied price (Default = PRICE_CLOSE)

//--- trade parameters
input uint InpDuration           = 10;     // Position holding time in bars (Default = 10)
input uint InpSL                 = 1500;   // Stop Loss in points (Default = 1500)
input uint InpTP                 = 2000;   // Take Profit in points (Default = 2000)
input uint InpSlippage           = 10;     // Slippage in points (Default = 10)
input bool enableTrailingStop    = false;  // Enable trailing stop (Default = false)
input uint InpTrailingStopPoints = 2000;   // Trailing stop in points (Default = 2000)

//--- money management parameters
input double InpLot           = 0.06;   // Lot (Default = 0.06)
input double InpMinimumEquity = 100.0;  // Minimum equity to allow trading (Default = 100.0)
input double MaxLossPercent   = 20.0;   // Max % loss of balance allowed (Default = 20.0)

//--- Expert ID
input long InpMagicNumber = 121400;  // Magic Number

//--- global variables
int    ExtAvgBodyPeriod;            // average candlestick calculation period
int    ExtSignalOpen      = 0;      // Buy/Sell signal
int    ExtSignalClose     = 0;      // signal to close a position
string ExtPatternInfo     = "";     // current pattern information
string ExtDirection       = "";     // position opening direction
bool   ExtPatternDetected = false;  // pattern detected
bool   ExtConfirmed       = false;  // pattern confirmed
bool   ExtCloseByTime     = true;   // requires closing by time
bool   ExtCheckPassed     = true;   // status checking error

//---  indicator handles
const string stoRsiPath       = "Custom_Indic\\StochasticRsi_32185.ex5";
const int    kLine            = 0;
const int    dLine            = 1;
int          stoRsiHandle     = INVALID_HANDLE;
int          ExtTrendMAHandle = INVALID_HANDLE;

//--- Balance and equity
double startingBalance;

//--- service objects
CTrade      ExtTrade;
CSymbolInfo ExtSymbolInfo;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  Print("Starting balance: ", startingBalance);
  Print("InpSL=", InpSL);
  Print("InpTP=", InpTP);
  //--- set parameters for trading operations
  ExtTrade.SetDeviationInPoints(InpSlippage);     // slippage
  ExtTrade.SetExpertMagicNumber(InpMagicNumber);  // Expert Advisor ID
  ExtTrade.LogLevel(LOG_LEVEL_ERRORS);            // logging level

  ExtAvgBodyPeriod = InpAverBodyPeriod;
  //--- indicator initialization
  stoRsiHandle = iCustom(_Symbol, PERIOD_CURRENT, stoRsiPath, inpK, inpD, inpRsiPeriod, inpStoPeriod, inpAppliedPrice);
  if (stoRsiHandle == INVALID_HANDLE) {
    Print("Error: stoRsiHandle ", GetLastError());
    return (INIT_FAILED);
  }

  //--- trend moving average
  ExtTrendMAHandle = iMA(_Symbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
  if (ExtTrendMAHandle == INVALID_HANDLE) {
    Print("Error creating Moving Average indicator");
    return (INIT_FAILED);
  }

  //--- OK
  return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  //--- release indicator handle
  // IndicatorRelease(stoRsiHandle);
  // IndicatorRelease(ExtTrendMAHandle);
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
// Handles equity checks, position/order management, and trading signals on each tick.
void OnTick() {
  //--- save the next bar start time; all checks at bar opening only
  static datetime next_bar_open = 0;

  if (TimeCurrent() >= next_bar_open) {
    // Check equity limits and clear all positions/orders if breached
    if (AccountInfoDouble(ACCOUNT_EQUITY) <= InpMinimumEquity || CheckEquityLossExceeded()) {
      PrintFormat("⚠️ Equity %.2f below minimum required %.2f", AccountInfoDouble(ACCOUNT_EQUITY), InpMinimumEquity);
      ClearAllPositionsAndOrders();
    }

    // Apply trailing stop to all open positions on every tick
    if (enableTrailingStop) ApplyTrailingStop(InpTrailingStopPoints);

    //--- Phase 1 - check the emergence of a new bar and update the status
    //--- get the current state of environment on the new bar
    // namely, set the values of global variables:
    // ExtPatternDetected - pattern detection
    // ExtConfirmed - pattern confirmation
    // ExtSignalOpen - signal to open
    // ExtSignalClose - signal to close
    // ExtPatternInfo - current pattern information
    if (CheckState()) {
      //--- set the new bar opening time
      next_bar_open = TimeCurrent();
      next_bar_open -= next_bar_open % PeriodSeconds(_Period);
      next_bar_open += PeriodSeconds(_Period);

      //--- report the emergence of a new bar only once within a bar
      if (ExtPatternDetected && ExtConfirmed)
        Print(ExtPatternInfo);
    } else {
      //--- error getting the status, retry on the next tick
      return;
    }
  }

  //--- Phase 2 - if there is a signal and no position in this direction
  if (ExtSignalOpen && !PositionExist(ExtSignalOpen)) {
    Print("\r\nSignal to open position ", ExtDirection);
    PositionOpen();
    if (PositionExist(ExtSignalOpen))
      ExtSignalOpen = SIGNAL_NOT;
  }

  //--- Phase 3 - close if there is a signal to close
  if (ExtSignalClose && PositionExist(ExtSignalClose)) {
    Print("\r\nSignal to close position ", ExtDirection);
    CloseBySignal(ExtSignalClose);
    if (!PositionExist(ExtSignalClose))
      ExtSignalClose = SIGNAL_NOT;
  }

  //--- Phase 4 - close upon expiration
  if (ExtCloseByTime && PositionExpiredByTimeExist()) {
    CloseByTime();
    ExtCloseByTime = PositionExpiredByTimeExist();
  }
}
//+------------------------------------------------------------------+
//|  Get the current environment and check for a pattern             |
//+------------------------------------------------------------------+
bool CheckEquityLossExceeded() {
  double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  double limitEquity   = startingBalance * (1.0 - (MaxLossPercent / 100.0f));
  return currentEquity <= limitEquity;
}

void ClearAllPositionsAndOrders() {
  // Close all open positions
  int positions = PositionsTotal();
  if (positions > 0) {
    for (int i = positions - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (ticket != 0) {
        string symbol = PositionGetString(POSITION_SYMBOL);
        long   magic  = PositionGetInteger(POSITION_MAGIC);
        if (symbol == Symbol() && magic == InpMagicNumber) {
          ExtTrade.PositionClose(ticket, InpSlippage);
        }
      }
    }
  }
  // Delete all pending orders only if there are any
  int orders = OrdersTotal();
  if (orders > 0) {
    for (int i = orders - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (ticket != 0) {
        string symbol = OrderGetString(ORDER_SYMBOL);
        long   magic  = OrderGetInteger(ORDER_MAGIC);
        if (symbol == Symbol() && magic == InpMagicNumber) {
          ExtTrade.OrderDelete(ticket);
        }
      }
    }
  }
  ExpertRemove();
}
// Apply trailing stop to all open positions of this EA
void ApplyTrailingStop(uint trailingStopPoints) {
  // int positions = PositionsTotal();
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket != 0) {
      string symbol = PositionGetString(POSITION_SYMBOL);
      // long   magic  = PositionGetInteger(POSITION_MAGIC);
      if (symbol == Symbol() && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl        = PositionGetDouble(POSITION_SL);
        double price     = 0.0;
        double newSL     = 0.0;
        int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
        double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
        long   type      = PositionGetInteger(POSITION_TYPE);
        if (type == POSITION_TYPE_BUY) {
          price = SymbolInfoDouble(symbol, SYMBOL_BID);
          newSL = price - trailingStopPoints * point;
          if ((sl == 0.0 || newSL > sl) && (price - openPrice) > trailingStopPoints * point) {
            newSL = NormalizeDouble(newSL, digits);
            if (!ExtTrade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
              PrintFormat("Failed to modify trailing stop for BUY position #%I64u, error=%d", ticket, GetLastError());
          }
        } else if (type == POSITION_TYPE_SELL) {
          price = SymbolInfoDouble(symbol, SYMBOL_ASK);
          newSL = price + trailingStopPoints * point;
          if ((sl == 0.0 || newSL < sl) && (openPrice - price) > trailingStopPoints * point) {
            newSL = NormalizeDouble(newSL, digits);
            if (!ExtTrade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
              PrintFormat("Failed to modify trailing stop for SELL position #%I64u, error=%d", ticket, GetLastError());
          }
        }
      }
    }
  }
}

bool CheckState() {
  //--- check if there is a pattern
  if (!CheckPattern()) {
    Print("Error, failed to check pattern");
    return (false);
  }

  //--- check for confirmation
  if (!CheckConfirmation()) {
    Print("Error, failed to check pattern confirmation");
    return (false);
  }
  //--- if there is no confirmation, cancel the signal
  if (!ExtConfirmed)
    ExtSignalOpen = SIGNAL_NOT;

  //--- check if there is a signal to close a position
  if (!CheckCloseSignal()) {
    Print("Error, failed to check the closing signal");
    return (false);
  }

  //--- if positions are to be closed after certain holding time in bars
  if (InpDuration)
    ExtCloseByTime = true;  // set flag to close upon expiration

  //--- all checks done
  return (true);
}

double CalculateTrailingStopLossPrice(int signalType, double price, double point, double spread, int digits) {
  double stoploss = 0.0;
  if (InpTrailingStopPoints > 0) {
    if (signalType == SIGNAL_BUY) {
      if (spread >= InpTrailingStopPoints * point) {
        PrintFormat("StopLoss (%d points) <= current spread = %.0f points. Spread value will be used", InpTrailingStopPoints, spread / point);
        stoploss = NormalizeDouble(price - spread, digits);
      } else
        stoploss = NormalizeDouble(price - InpTrailingStopPoints * point, digits);

    } else if (signalType == SIGNAL_SELL) {
      if (spread >= InpTrailingStopPoints * point) {
        PrintFormat("StopLoss (%d points) <= current spread = %.0f points. Spread value will be used", InpTrailingStopPoints, spread / point);
        stoploss = NormalizeDouble(price + spread, digits);
      } else
        stoploss = NormalizeDouble(price + InpTrailingStopPoints * point, digits);
    }
  }
  return stoploss;
}

//+------------------------------------------------------------------+
//| Open a position in the direction of the signal                   |
//+------------------------------------------------------------------+
bool PositionOpen() {
  ExtSymbolInfo.Refresh();
  ExtSymbolInfo.RefreshRates();

  double price = 0;
  //--- Stop Loss and Take Profit are not set by default
  double stoploss   = 0.0;
  double takeprofit = 0.0;

  int    digits = ExtSymbolInfo.Digits();
  double point  = ExtSymbolInfo.Point();
  double spread = ExtSymbolInfo.Ask() - ExtSymbolInfo.Bid();

  //--- uptrend
  if (ExtSignalOpen == SIGNAL_BUY) {
    price = NormalizeDouble(ExtSymbolInfo.Ask(), digits);
    if (enableTrailingStop) {
      stoploss = CalculateTrailingStopLossPrice(SIGNAL_BUY, price, point, spread, digits);
      if (!ExtTrade.Buy(InpLot, Symbol(), price, stoploss, 0.0)) {
        PrintFormat("Failed %s buy %G at %G (sl=%G tp=%G) failed. Ask=%G error=%d",
                    Symbol(), InpLot, price, stoploss, takeprofit, ExtSymbolInfo.Ask(), GetLastError());
        return (false);
      }
    } else {
      //--- if Stop Loss is set
      if (InpSL > 0) {
        if (spread >= InpSL * point) {
          PrintFormat("StopLoss (%d points) <= current spread = %.0f points. Spread value will be used", InpSL, spread / point);
          stoploss = NormalizeDouble(price - spread, digits);
        } else
          stoploss = NormalizeDouble(price - InpSL * point, digits);
      }
      //--- if Take Profit is set
      if (InpTP > 0) {
        if (spread >= InpTP * point) {
          PrintFormat("TakeProfit (%d points) < current spread = %.0f points. Spread value will be used", InpTP, spread / point);
          takeprofit = NormalizeDouble(price + spread, digits);
        } else
          takeprofit = NormalizeDouble(price + InpTP * point, digits);
      }

      if (!ExtTrade.Buy(InpLot, Symbol(), price, stoploss, takeprofit)) {
        PrintFormat("Failed %s buy %G at %G (sl=%G tp=%G) failed. Ask=%G error=%d",
                    Symbol(), InpLot, price, stoploss, takeprofit, ExtSymbolInfo.Ask(), GetLastError());
        return (false);
      }
    }
  }

  //--- downtrend
  if (ExtSignalOpen == SIGNAL_SELL) {
    price = NormalizeDouble(ExtSymbolInfo.Bid(), digits);
    if (enableTrailingStop) {
      stoploss = CalculateTrailingStopLossPrice(SIGNAL_SELL, price, point, spread, digits);
      if (!ExtTrade.Sell(InpLot, Symbol(), price, stoploss, 0.0)) {
        PrintFormat("Failed %s sell at %G (sl=%G tp=%G) failed. Bid=%G error=%d",
                    Symbol(), price, stoploss, 0.0, ExtSymbolInfo.Bid(), GetLastError());
        ExtTrade.PrintResult();
        Print("   ");
        return (false);
      }
    } else {
      //--- if Stop Loss is set
      if (InpSL > 0) {
        if (spread >= InpSL * point) {
          PrintFormat("StopLoss (%d points) <= current spread = %.0f points. Spread value will be used", InpSL, spread / point);
          stoploss = NormalizeDouble(price + spread, digits);
        } else
          stoploss = NormalizeDouble(price + InpSL * point, digits);
      }
      //--- if Take Profit is set
      if (InpTP > 0) {
        if (spread >= InpTP * point) {
          PrintFormat("TakeProfit (%d points) < current spread = %.0f points. Spread value will be used", InpTP, spread / point);
          takeprofit = NormalizeDouble(price - spread, digits);
        } else
          takeprofit = NormalizeDouble(price - InpTP * point, digits);
      }

      if (!ExtTrade.Sell(InpLot, Symbol(), price, stoploss, takeprofit)) {
        PrintFormat("Failed %s sell at %G (sl=%G tp=%G) failed. Bid=%G error=%d",
                    Symbol(), price, stoploss, takeprofit, ExtSymbolInfo.Bid(), GetLastError());
        return (false);
      }
    }
  }

  //---
  return (true);
}
//+------------------------------------------------------------------+
//|  Close a position based on the specified signal                  |
//+------------------------------------------------------------------+
void CloseBySignal(int type_close) {
  //--- if there is no signal to close, return successful completion
  if (type_close == SIGNAL_NOT)
    return;
  //--- if there are no positions opened by our EA
  if (PositionExist(ExtSignalClose) == 0)
    return;

  //--- closing direction
  long type;
  switch (type_close) {
    case CLOSE_SHORT:
      type = POSITION_TYPE_SELL;
      break;
    case CLOSE_LONG:
      type = POSITION_TYPE_BUY;
      break;
    default:
      Print("Error! Signal to close not detected");
      return;
  }

  //--- check all positions and close ours based on the signal
  int positions = PositionsTotal();
  for (int i = positions - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket != 0) {
      //--- get the name of the symbol and the position id (magic)
      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      //--- if they correspond to our values
      if (symbol == Symbol() && magic == InpMagicNumber) {
        if (PositionGetInteger(POSITION_TYPE) == type) {
          ExtTrade.PositionClose(ticket, InpSlippage);
          ExtTrade.PrintResult();
          Print("   ");
        }
      }
    }
  }
}
//+------------------------------------------------------------------+
//|  Close positions upon holding time expiration in bars            |
//+------------------------------------------------------------------+
void CloseByTime() {
  //--- if there are no positions opened by our EA
  if (PositionExist(ExtSignalOpen) == 0)
    return;

  //--- check all positions and close ours based on the holding time in bars
  int positions = PositionsTotal();
  for (int i = positions - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket != 0) {
      //--- get the name of the symbol and the position id (magic)
      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      //--- if they correspond to our values
      if (symbol == Symbol() && magic == InpMagicNumber) {
        //--- position opening time
        datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
        //--- check position holding time in bars
        if (BarsHold(open_time) >= (int)InpDuration) {
          Print("\r\nTime to close position #", ticket);
          ExtTrade.PositionClose(ticket, InpSlippage);
          ExtTrade.PrintResult();
          Print("   ");
        }
      }
    }
  }
}
//+------------------------------------------------------------------+
//| Returns true if there are open positions                         |
//+------------------------------------------------------------------+
bool PositionExist(int signal_direction) {
  bool check_type = (signal_direction != SIGNAL_NOT);

  //--- what positions to search
  ENUM_POSITION_TYPE search_type = WRONG_VALUE;
  if (check_type)
    switch (signal_direction) {
      case SIGNAL_BUY:
        search_type = POSITION_TYPE_BUY;
        break;
      case SIGNAL_SELL:
        search_type = POSITION_TYPE_SELL;
        break;
      case CLOSE_LONG:
        search_type = POSITION_TYPE_BUY;
        break;
      case CLOSE_SHORT:
        search_type = POSITION_TYPE_SELL;
        break;
      default:
        //--- entry direction is not specified; nothing to search
        return (false);
    }

  //--- go through the list of all positions
  for (int i = 0; i < PositionsTotal(); i++) {
    if (PositionGetTicket(i) != 0) {
      //--- if the position type does not match, move on to the next one
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if (check_type && (type != search_type))
        continue;
      //--- get the name of the symbol and the expert id (magic number)
      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      //--- if they correspond to our values
      if (symbol == Symbol() && magic == InpMagicNumber) {
        //--- yes, this is the right position, stop the search
        return (true);
      }
    }
  }

  //--- open position not found
  return (false);
}
//+------------------------------------------------------------------+
//| Returns true if there are open positions with expired time       |
//+------------------------------------------------------------------+
bool PositionExpiredByTimeExist() {
  //--- go through the list of all positions
  int positions = PositionsTotal();
  for (int i = 0; i < positions; i++) {
    if (PositionGetTicket(i) != 0) {
      //--- get the name of the symbol and the expert id (magic number)
      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      //--- if they correspond to our values
      if (symbol == Symbol() && magic == InpMagicNumber) {
        //--- position opening time
        datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
        //--- check position holding time in bars
        int check = BarsHold(open_time);
        //--- id the value is -1, the check completed with an error
        if (check == -1 || (BarsHold(open_time) >= (int)InpDuration))
          return (true);
      }
    }
  }

  //--- open position not found
  return (false);
}

//+------------------------------------------------------------------+
//| Checks position closing time in bars                             |
//+------------------------------------------------------------------+
int BarsHold(datetime open_time) {
  //--- first run a basic simple check
  if (TimeCurrent() - open_time < PeriodSeconds(_Period)) {
    //--- opening time is inside the current bar
    return (0);
  }
  //---
  MqlRates bars[];
  if (CopyRates(_Symbol, _Period, open_time, TimeCurrent(), bars) == -1) {
    Print("Error. CopyRates() failed, error = ", GetLastError());
    return (-1);
  }
  //--- check position holding time in bars
  return (ArraySize(bars));
}
//+------------------------------------------------------------------+
//| Returns the open price of the specified bar                      |
//+------------------------------------------------------------------+
double Open(int index) {
  double val = iOpen(_Symbol, _Period, index);
  //--- if the current check state was successful and an error was received
  if (ExtCheckPassed && val == 0)
    ExtCheckPassed = false;  // switch the status to failed

  return (val);
}
//+------------------------------------------------------------------+
//| Returns the close price of the specified bar                     |
//+------------------------------------------------------------------+
double Close(int index) {
  double val = iClose(_Symbol, _Period, index);
  //--- if the current check state was successful and an error was received
  if (ExtCheckPassed && val == 0)
    ExtCheckPassed = false;  // switch the status to failed

  return (val);
}
//+------------------------------------------------------------------+
//| Returns the low price of the specified bar                       |
//+------------------------------------------------------------------+
double Low(int index) {
  double val = iLow(_Symbol, _Period, index);
  //--- if the current check state was successful and an error was received
  if (ExtCheckPassed && val == 0)
    ExtCheckPassed = false;  // switch the status to failed

  return (val);
}
//+------------------------------------------------------------------+
//| Returns the high price of the specified bar                      |
//+------------------------------------------------------------------+
double High(int index) {
  double val = iHigh(_Symbol, _Period, index);
  //--- if the current check state was successful and an error was received
  if (ExtCheckPassed && val == 0)
    ExtCheckPassed = false;  // switch the status to failed

  return (val);
}
//+------------------------------------------------------------------+
//| Returns the middle body price for the specified bar              |
//+------------------------------------------------------------------+
double MidPoint(int index) {
  return (High(index) + Low(index)) / 2.;
}
//+------------------------------------------------------------------+
//| Returns the middle price of the range for the specified bar      |
//+------------------------------------------------------------------+
double MidOpenClose(int index) {
  return ((Open(index) + Close(index)) / 2.);
}
//+------------------------------------------------------------------+
//| Returns the average candlestick body size for the specified bar  |
//+------------------------------------------------------------------+
double AvgBody(int index) {
  double sum = 0;
  for (int i = index; i < index + ExtAvgBodyPeriod; i++) {
    sum += MathAbs(Open(i) - Close(i));
  }
  return (sum / ExtAvgBodyPeriod);
}
//+------------------------------------------------------------------+
//| Returns true in case of successful pattern check                 |
//+------------------------------------------------------------------+
bool CheckPattern() {
  ExtPatternDetected = false;
  //--- check if there is a pattern
  ExtSignalOpen  = SIGNAL_NOT;
  ExtPatternInfo = "\r\nPattern not detected";
  ExtDirection   = "";

  //--- check Bearish Engulfing
  if ((Open(2) < Close(2)) &&               // previous candle is bearish
      (Open(1) - Close(1) > AvgBody(1)) &&  // body of the candle is higher than average value of the body
      (Close(1) < Open(2)) &&               // close price of the bearish candle is lower than open price of the bullish candle
      (MidOpenClose(2) > CloseAvg(2)) &&    // uptrend
      (Open(1) > Close(2)))                 // Open price of the bearish candle is higher than close price of the bullish candle
  {
    ExtPatternDetected = true;
    ExtSignalOpen      = SIGNAL_SELL;
    ExtPatternInfo     = "\r\nBearish Engulfing detected";
    ExtDirection       = "Sell";
    return (true);
  }

  //--- check Bullish Engulfing
  if ((Open(2) > Close(2)) &&               // previous candle is bearish
      (Close(1) - Open(1) > AvgBody(1)) &&  // body of the bullish candle is higher than average value of the body
      (Close(1) > Open(2)) &&               // close price of the bullish candle is higher than open price of the bearish candle
      (MidOpenClose(2) < CloseAvg(2)) &&    // downtrend
      (Open(1) < Close(2)))                 // open price of the bullish candle is lower than close price of the bearish
  {
    ExtPatternDetected = true;
    ExtSignalOpen      = SIGNAL_BUY;
    ExtPatternInfo     = "\r\nBullish Engulfing detected";
    ExtDirection       = "Buy";
    return (true);
  }

  //--- result of checking
  return (ExtCheckPassed);
}
//+------------------------------------------------------------------+
//| Returns true in case of successful confirmation check            |
//+------------------------------------------------------------------+
bool CheckConfirmation() {
  ExtConfirmed = false;
  //--- if there is no pattern, do not search for confirmation
  if (!ExtPatternDetected)
    return (true);

  //   //--- get the value of the stochastic indicator to confirm the signal
  //   double signal = StochSignal(1);
  //   if (signal == EMPTY_VALUE) {
  //     //--- failed to get indicator value, check failed
  //     return (false);
  //   }
  double kSignal = stoRsi(kLine, 1);
  if (kSignal == EMPTY_VALUE) {  //--- failed to get indicator value, check failed
    PrintFormat("Failed to copy data from the K line, error code: %d", GetLastError());
    return (false);
  }
  double dSignal = stoRsi(dLine, 1);
  if (dSignal == EMPTY_VALUE) {  //--- failed to get indicator value, check failed
    PrintFormat("Failed to copy data from the D line, error code %d", GetLastError());
    return (false);
  }

  //--- check the Buy signal
  //   if (ExtSignalOpen == SIGNAL_BUY && (signal < 30)) {
  //     ExtConfirmed = true;
  //     ExtPatternInfo += "\r\n   Confirmed: StochSignal<30";
  //   }
  //   if (ExtSignalOpen == SIGNAL_BUY) {
  if (ExtSignalOpen == SIGNAL_BUY && kSignal < 20 && dSignal < 20) {  // K & D are below 20
                                                                      // if (ExtSignalOpen == SIGNAL_BUY && kSignal < 30 /*&& dSignal < 20*/) {  // K & D are below 20
    ExtConfirmed = true;
    ExtPatternInfo += "\r\n   Confirmed: K crossed above D and < 20";
  }
  //--- check the Sell signal
  //   if (ExtSignalOpen == SIGNAL_SELL && (signal > 70)) {
  //     ExtConfirmed = true;
  //     ExtPatternInfo += "\r\n   Confirmed: StochSignal>70";
  //   }
  // if (ExtSignalOpen == SIGNAL_SELL) {
  if (ExtSignalOpen == SIGNAL_SELL && kSignal > 80 && dSignal > 80) {  // K & D are above 80
                                                                       // if (ExtSignalOpen == SIGNAL_SELL && kSignal > 70 /*&& dSignal > 80*/) {  // K & D are above 80
    ExtConfirmed = true;
    ExtPatternInfo += "\r\n   Confirmed: K crossed below D and > 80";
  }

  //--- successful completion of the check
  return (true);
}
//+------------------------------------------------------------------+
//| Check if there is a signal to close                              |
//+------------------------------------------------------------------+
bool CheckCloseSignal() {
  ExtSignalClose = false;
  //--- if there is a signal to enter the market, do not check the signal to close
  if (ExtSignalOpen != SIGNAL_NOT)
    return (true);

  //   //--- check if there is a signal to close a long position
  //   if (((StochSignal(1) < 80) && (StochSignal(2) > 80)) ||  // 80 crossed downwards
  //       ((StochSignal(1) < 20) && (StochSignal(2) > 20)))    // 20 crossed downwards
  //   {
  //     //--- there is a signal to close a long position
  //     ExtSignalClose = CLOSE_LONG;
  //     ExtDirection   = "Long";
  //   }

  //   //--- check if there is a signal to close a short position
  //   if ((((StochSignal(1) > 20) && (StochSignal(2) < 20)) ||  // 20 crossed upwards
  //        ((StochSignal(1) > 80) && (StochSignal(2) < 80))))   // 80 crossed upwards
  //   {
  //     //--- there is a signal to close a short position
  //     ExtSignalClose = CLOSE_SHORT;
  //     ExtDirection   = "Short";
  //   }

  double currK = stoRsi(kLine, 1);
  double preK  = stoRsi(kLine, 2);
  double currD = stoRsi(dLine, 1);
  double preD  = stoRsi(dLine, 2);

  //--- check if there is a signal to close a long position
  // if (currK > 80 && currD > 80 && preK > 80 && preD > 80) {  // K & D are above 80
  // if (currK < 80 && preK > 80 && currD < 80 && preD > 80) {  // K & D crossed downwards 80
  if (((currK < 80) && (preK > 80)) || ((currK < 20) && (preK > 20))) {  // K crossed downwards 80 or 20
                                                                         // if (currK < currD && preK >= preD) {
    //--- there is a signal to close a long position
    ExtSignalClose = CLOSE_LONG;
    ExtDirection   = "Long";
    // }
  }

  //--- check if there is a signal to close a short position
  // if (currK < 20 && currD < 20 && preK < 20 && preD < 20) {  // K & D are below 20
  // if (currK > 20 && preK < 20 && currD > 20 && preD < 20) {  // K & D crossed 20
  if (((currK > 20) && (preK < 20)) || ((currK > 80) && (preK < 80))) {  // K crossed upwards 20 or 80
                                                                         // if (currK > currD && preK <= preD) {
    //--- there is a signal to close a short position
    ExtSignalClose = CLOSE_SHORT;
    ExtDirection   = "Short";
    // }
  }

  //--- successful completion of the check
  return (true);
}
//+------------------------------------------------------------------+
//| Stochastic indicator value at the specified bar                  |
//+------------------------------------------------------------------+
// double StochSignal(int index) {
//   double indicator_values[];
//   if (CopyBuffer(ExtIndicatorHandle, SIGNAL_LINE, index, 1, indicator_values) < 0) {
//     //--- if the copying fails, report the error code
//     PrintFormat("Failed to copy data from the iStochastic indicator, error code %d", GetLastError());
//     return (EMPTY_VALUE);
//   }
//   return (indicator_values[0]);
// }

double stoRsi(int line, int bar) {
  double indicator_values[];
  if (CopyBuffer(stoRsiHandle, line, bar, 1, indicator_values) < 0) {
    PrintFormat("Failed to copy data from the iStochastic indicator, error code %d", GetLastError());
    return (EMPTY_VALUE);
  }
  return (indicator_values[0]);
}

//+------------------------------------------------------------------+
//| SMA value at the specified bar                                   |
//+------------------------------------------------------------------+
double CloseAvg(int index) {
  double indicator_values[];
  if (CopyBuffer(ExtTrendMAHandle, 0, index, 1, indicator_values) < 0) {
    //--- if the copying fails, report the error code
    PrintFormat("Failed to copy data from the Simple Moving Average indicator, error code %d", GetLastError());
    return (EMPTY_VALUE);
  }
  return (indicator_values[0]);
}
//+------------------------------------------------------------------+
