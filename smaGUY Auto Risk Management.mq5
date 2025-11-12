//+------------------------------------------------------------------+
//|                                                      ProjectName |
//|                                      Copyright 2020, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                            SimpleTradeManager.mq5 |
//|                v14 Linear, planned+executed weighted TP/RR (full) |
//+------------------------------------------------------------------+
#property copyright "Simple Trade Manager"
#property version   "14.00"
#property strict

#include <Trade\Trade.mqh>

// ===============================
// Inputs
// ===============================
input group "=== Stop Loss & Take Profit ==="
input double InpStopLoss = 1000;           // Stop Loss (points)
input double InpTakeProfit = 5000;        // Take Profit (points)
input double InpSlippageMargin = 100;      // Break-even offset (points)

input group "=== Position Management ==="
input bool   InpShowLines = true;         // Show BE/Partial Levels
input bool   InpCombinePositions = true; // Combine positions as one pool

input group "=== Auto Break-Even ==="
input bool   InpEnableBE = true;        // Enable Auto Break-Even
input double InpBEPoints = 3000;           // BE Trigger (points in profit)

input group "=== Auto Partials ==="
input bool InpEnablePartials = true;   // Enable Auto Partials
input int    InpMaxPartials = 5;        // Maximum partial steps

input group "=== Dashboard Settings ==="
input bool InpEnableDashboard = true;   // Enable dashboard display
enum ENUM_DASHBOARD_CORNER
  {
   DASH_CORNER_LEFT_UPPER = 0,
   DASH_CORNER_LEFT_LOWER = 1,
   DASH_CORNER_RIGHT_UPPER = 2,
   DASH_CORNER_RIGHT_LOWER = 3
  };
input ENUM_DASHBOARD_CORNER InpCorner = DASH_CORNER_LEFT_LOWER;
input int    InpXDistance = 30;
input int    InpYDistance = 30;
input int    InpLineSpacing = 18;
input string InpFontName = "Courier New";
input int    InpFontSize = 16;
input int    InpPriceDecimals = 2;
input int    InpMoneyDecimals = 2;
input bool   InpSingleLineMode = true;
input bool   InpCenterLine = true;


// ===============================
// Globals & state
// ===============================
CTrade trade;
int last_millisecond = 0;
int last_dashboard_update = 0;

string currencySymbol;
bool isDarkTheme;
color colorText, colorProfit, colorLoss, colorSL, colorTP;

struct PartialPlan { double level; double volume; };

struct PartialInfo
  {
   int               partials_done;       // Completed partial steps
   double            original_volume;     // Volume at position initialization
   bool              be_applied;
   double            tracked_tp;          // Last tracked TP

   // Executed partials tracking
   double            exec_pxvol;          // sum(executed price * executed volume)
   double            exec_vol;            // sum(executed volume)

   // Planned partials (levels + volumes at creation or reconstructed)
   PartialPlan       planned_partials[];
  };
PartialInfo position_states[];
ulong position_tickets[];
int states_count = 0;

struct PositionGroup
  {
   double            total_volume;        // Current total volume
   double            weighted_entry;      // Sum(entry * vol)
   double            weighted_tp;         // Sum(tp * vol, tp>0)
   double            weighted_sl;         // Sum(sl * vol, sl>0)
   double            original_volume;     // Sum of original_volume
   ulong             tickets[];
   int               ticket_count;
  };

// ===============================
// Utilities
// ===============================
int VolumePrecision(double lot_step)
  {
   int digits = 0;
   double step = lot_step;
   if(step<=0.0)
      return 2;
   while(step < 1.0 && digits < 8)
     {
      step *= 10.0;
      digits++;
     }
   return digits;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeToStep(double vol, double lot_step, int vol_digits)
  {
   if(lot_step<=0.0)
      return NormalizeDouble(vol, vol_digits);
   double steps = MathFloor(vol / lot_step + 1e-8);
   return NormalizeDouble(steps * lot_step, vol_digits);
  }
double Clamp(double v, double a, double b) { if(v<a) return a; if(v>b) return b; return v; }

// ===============================
// Linear distribution
// ===============================
void GeneratePartialLevels(double entry, double tp, int N, ENUM_POSITION_TYPE direction, double &levels[])
  {
   ArrayResize(levels, N);
   double dir = (direction==POSITION_TYPE_BUY ? 1.0 : -1.0);
   double total_distance = MathAbs(tp - entry);
   if(total_distance <= 0.0)
     {
      for(int i=0;i<N;i++)
         levels[i]=entry;
      return;
     }
   double step = total_distance / N;
   for(int i=0;i<N;i++)
     {
      double d = step * (i+1);
      levels[i] = entry + dir * d;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void GeneratePartialSizes(double total_volume, int N, double &sizes_out[], double lot_step, int vol_digits)
  {
   ArrayResize(sizes_out, N);
   double step_vol = total_volume / N;
   for(int i=0;i<N;i++)
      sizes_out[i] = NormalizeToStep(step_vol, lot_step, vol_digits);
  }

// ===============================
// Planned partials builder (for new or already-open positions)
// ===============================
void EnsurePlannedPartials(int s, double entry, double tp, double volume, ENUM_POSITION_TYPE type)
  {
   if(ArraySize(position_states[s].planned_partials) > 0)
      return;
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int vol_digits  = VolumePrecision(lot_step);
   int N = InpMaxPartials; // user input = number of partials beside final TP
   if(N < 1)
      N = 1;
   double dir = (type==POSITION_TYPE_BUY ? 1.0 : -1.0);
   double total_distance = MathAbs(tp - entry);
   double step = total_distance / (N+1);
   ArrayResize(position_states[s].planned_partials, N);
   double step_vol = volume / (N+1);
   for(int i=0;i<N;i++)
     {
      double d = step * (i+1);
      position_states[s].planned_partials[i].level  = entry + dir * d;
      position_states[s].planned_partials[i].volume = NormalizeToStep(step_vol, lot_step, vol_digits);
     }
  }


// ===============================
// Weighted TP & Reward (planned + executed)
// ===============================
double PlannedAndExecutedWeightedTP_ByIndex(int s, double entry, double final_tp, double remain, ENUM_POSITION_TYPE type)
  {
   if(!InpEnablePartials)
      return final_tp;
   EnsurePlannedPartials(s, entry, final_tp, position_states[s].original_volume, type);
   double sum_pxvol = position_states[s].exec_pxvol;
   double sum_vol   = position_states[s].exec_vol;
// Remaining planned partials
   for(int i=position_states[s].partials_done; i<ArraySize(position_states[s].planned_partials); i++)
     {
      sum_pxvol += position_states[s].planned_partials[i].level * position_states[s].planned_partials[i].volume;
      sum_vol   += position_states[s].planned_partials[i].volume;
     }
// Residual volume goes to final TP
   double final_vol = MathMax(0.0, position_states[s].original_volume - sum_vol);
   if(final_vol > 0.0)
     {
      sum_pxvol += final_tp * final_vol;
      sum_vol   += final_vol;
     }
   return (sum_vol>0.0) ? (sum_pxvol/sum_vol) : final_tp;
  }


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double PositionPlannedAndExecutedReward(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return 0.0;
   int s = GetPositionStateIndex(ticket);
   if(s<0)
      return 0.0;
   double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
   double final_tp = PositionGetDouble(POSITION_TP);
   double remain   = PositionGetDouble(POSITION_VOLUME);
   bool isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   ENUM_POSITION_TYPE type = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double wexit = InpEnablePartials
                  ? PlannedAndExecutedWeightedTP_ByIndex(s, entry, final_tp, remain, type)
                  : final_tp;
   double diff = isBuy ? (wexit - entry) : (entry - wexit);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (diff/point) * pointValue * position_states[s].original_volume;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double OverallWeightedTP_PlannedAndExecuted()
  {
   double sum_pxvol = 0.0;
   double sum_vol   = 0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      int s = GetPositionStateIndex(ticket);
      if(s<0)
         continue;
      double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      double final_tp = PositionGetDouble(POSITION_TP);
      double remain   = PositionGetDouble(POSITION_VOLUME);
      bool isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      ENUM_POSITION_TYPE type = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      double wexit  = PlannedAndExecutedWeightedTP_ByIndex(s, entry, final_tp, remain, type);
      double weight = position_states[s].original_volume;
      if(wexit<=0.0 || weight<=0.0)
         continue;
      sum_pxvol += wexit * weight;
      sum_vol   += weight;
     }
   return (sum_vol>0.0) ? (sum_pxvol/sum_vol) : 0.0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double TotalReward_PlannedAndExecuted()
  {
   double total = 0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      total += PositionPlannedAndExecutedReward(ticket);
     }
   return total;
  }

// ===============================
// Init / Deinit
// ===============================
int InpEffectivePartials;
int OnInit()
  {
   Print("=== SimpleTradeManager v14.00 Initialized ===");
   InpEffectivePartials = InpMaxPartials + 1; // always include final TP
   Print("Combine: ", InpCombinePositions ? "Yes":"No", " | Partials: Linear Auto (Planned+Executed Weighted TP/RR)");
   if(InpStopLoss < 0 || InpTakeProfit < 0)
     {
      Print("ERROR: SL/TP cannot be negative!");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEnablePartials && InpEffectivePartials < 1)
     {
      Print("ERROR: Max Partials must be at least 2!");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEnableDashboard)
      InitializeDashboard();
   if(InpEnableDashboard && InpEnableBE)
      EventSetMillisecondTimer(100);
   ProcessAllTrades();
   Print("=== Initialization Successful ===");
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("=== EA Removed - Reason: ", reason, " ===");
   if(InpEnableDashboard && InpEnableBE)
      EventKillTimer();
   if(InpEnableDashboard)
      DeleteAllVisuals();
  }

// ===============================
// Dashboard visuals
// ===============================
void InitializeDashboard()
  {
   string acc = AccountInfoString(ACCOUNT_CURRENCY);
   if(acc == "USD")
      currencySymbol = "$";
   else
      if(acc == "EUR")
         currencySymbol = "€";
      else
         if(acc == "GBP")
            currencySymbol = "£";
         else
            currencySymbol = acc + " ";
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int brightness = ((bg & 0xFF) + ((bg >> 8) & 0xFF) + ((bg >> 16) & 0xFF)) / 3;
   isDarkTheme = (brightness < 128);
   if(isDarkTheme)
     {
      colorText = clrWhite;
      colorProfit = clrLime;
      colorLoss = clrRed;
      colorSL = clrOrange;
      colorTP = clrDodgerBlue;
     }
   else
     {
      colorText = clrBlack;
      colorProfit = clrGreen;
      colorLoss = clrDarkRed;
      colorSL = clrDarkOrange;
      colorTP = clrBlue;
     }
   if(InpSingleLineMode)
     {
      CreateDashboardLabel("Line1_Pos", 0);
      CreateDashboardLabel("Line1_PnL", 0);
      CreateDashboardLabel("Line1_SL", 0);
      CreateDashboardLabel("Line1_TP", 0);
     }
   else
     {
      CreateDashboardLabel("Line1", 0);
      CreateDashboardLabel("Line2", 1);
      CreateDashboardLabel("Line3", 2);
      CreateDashboardLabel("Line4", 3);
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CreateDashboardLabel(string name, int lineIndex)
  {
   string objName = "TM_" + name;
   ENUM_BASE_CORNER corner;
   switch(InpCorner)
     {
      case DASH_CORNER_LEFT_UPPER:
         corner = CORNER_LEFT_UPPER;
         break;
      case DASH_CORNER_LEFT_LOWER:
         corner = CORNER_LEFT_LOWER;
         break;
      case DASH_CORNER_RIGHT_UPPER:
         corner = CORNER_RIGHT_UPPER;
         break;
      case DASH_CORNER_RIGHT_LOWER:
         corner = CORNER_RIGHT_LOWER;
         break;
      default:
         corner = CORNER_LEFT_LOWER;
     }
   int yPos = InpYDistance + (InpSingleLineMode ? 0 : ((corner==CORNER_LEFT_LOWER||corner==CORNER_RIGHT_LOWER)? (3 - lineIndex) : lineIndex) * InpLineSpacing);
   int anchor = (corner == CORNER_LEFT_UPPER || corner == CORNER_RIGHT_UPPER) ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER;
   ENUM_BASE_CORNER altCorner = corner;
   if(InpSingleLineMode && (corner == CORNER_RIGHT_LOWER || corner == CORNER_RIGHT_UPPER))
      altCorner = (corner == CORNER_RIGHT_LOWER) ? CORNER_LEFT_LOWER : CORNER_LEFT_UPPER;
   ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, altCorner);
   ObjectSetInteger(0, objName, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, InpXDistance);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, yPos);
   ObjectSetString(0, objName, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetTextPixelWidth(string text) { return (int)(StringLen(text) * InpFontSize * 0.75) + 15; }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetDashText(string name, string text, color clr)
  {
   string objName = "TM_" + name;
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
  }

// ===============================
// Trade events
// ===============================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_POSITION)
     {
      if(PositionSelectByTicket(trans.position))
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(symbol == _Symbol)
           {
            SetPositionSLTP(trans.position, symbol);
            InitializePositionState(trans.position);
           }
        }
     }
   else
      if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
        {
         if(OrderSelect(trans.order))
           {
            string symbol = OrderGetString(ORDER_SYMBOL);
            if(symbol == _Symbol)
               SetOrderSLTP(trans.order, symbol);
           }
        }
  }

// ===============================
// Tick loop
// ===============================
void OnTick()
  {
   if(InpEnablePartials)
      ManagePartialClose();
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpEnableBE)
      ManageBreakEven();
   if(InpEnableDashboard)
     {
      UpdateDashboard();
      if(InpShowLines && InpEnablePartials)
         UpdateLines();
     }
  }

// ===============================
// Scan all trades
// ===============================
void ProcessAllTrades()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(symbol == _Symbol)
           {
            SetPositionSLTP(ticket, symbol);
            InitializePositionState(ticket);
           }
        }
     }
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
        {
         string symbol = OrderGetString(ORDER_SYMBOL);
         if(symbol == _Symbol)
            SetOrderSLTP(ticket, symbol);
        }
     }
  }

// ===============================
// Position state management
// ===============================
void InitializePositionState(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   for(int i = 0; i < states_count; i++)
      if(position_tickets[i] == ticket)
         return;
   ArrayResize(position_tickets, states_count + 1);
   ArrayResize(position_states, states_count + 1);
   position_tickets[states_count] = ticket;
   position_states[states_count].partials_done   = 0;
   position_states[states_count].original_volume = PositionGetDouble(POSITION_VOLUME);
   position_states[states_count].be_applied      = false;
   position_states[states_count].tracked_tp      = PositionGetDouble(POSITION_TP);
   position_states[states_count].exec_pxvol      = 0.0;
   position_states[states_count].exec_vol        = 0.0;
// Build planned partials for new/attached positions
   double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
   double final_tp  = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   EnsurePlannedPartials(states_count, entry, final_tp, position_states[states_count].original_volume, type);
   states_count++;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GetPositionStateIndex(ulong ticket)
  {
   for(int i = 0; i < states_count; i++)
      if(position_tickets[i] == ticket)
         return i;
   return -1;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanupStates()
  {
   for(int i = states_count - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(position_tickets[i]))
        {
         for(int j = i; j < states_count - 1; j++)
           {
            position_tickets[j] = position_tickets[j + 1];
            position_states[j]  = position_states[j + 1];
           }
         states_count--;
         ArrayResize(position_tickets, states_count);
         ArrayResize(position_states, states_count);
        }
     }
  }

// ===============================
// Group aggregation
// ===============================
PositionGroup GetPositionGroup(string symbol, ENUM_POSITION_TYPE direction)
  {
   PositionGroup group;
   group.total_volume     = 0;
   group.weighted_entry   = 0;
   group.weighted_tp      = 0;
   group.weighted_sl      = 0;
   group.original_volume  = 0;
   group.ticket_count     = 0;
   ArrayResize(group.tickets, 0);
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pos_type != direction)
         continue;
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp     = PositionGetDouble(POSITION_TP);
      double sl     = PositionGetDouble(POSITION_SL);
      group.total_volume   += volume;
      group.weighted_entry += entry * volume;
      if(tp > 0)
         group.weighted_tp += tp * volume;
      if(sl > 0)
         group.weighted_sl += sl * volume;
      int s = GetPositionStateIndex(ticket);
      if(s >= 0)
         group.original_volume += position_states[s].original_volume;
      else
         group.original_volume += volume;
      ArrayResize(group.tickets, group.ticket_count + 1);
      group.tickets[group.ticket_count] = ticket;
      group.ticket_count++;
     }
   return group;
  }

// ===============================
// SL/TP setters
// ===============================
void SetPositionSLTP(ulong ticket, string symbol)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   if(current_sl != 0 && current_tp != 0)
      return;
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    sym_digits= (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double new_sl = current_sl, new_tp = current_tp;
   if(current_sl == 0 && InpStopLoss > 0)
      new_sl = NormalizeDouble(open_price + (type==POSITION_TYPE_BUY ? -1 : 1) * InpStopLoss * point, sym_digits);
   if(current_tp == 0 && InpTakeProfit > 0)
      new_tp = NormalizeDouble(open_price + (type==POSITION_TYPE_BUY ? 1 : -1) * InpTakeProfit * point, sym_digits);
   if(new_sl != current_sl || new_tp != current_tp)
      trade.PositionModify(ticket, new_sl, new_tp);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetOrderSLTP(ulong ticket, string symbol)
  {
   if(!OrderSelect(ticket))
      return;
   double current_sl = OrderGetDouble(ORDER_SL);
   double current_tp = OrderGetDouble(ORDER_TP);
   if(current_sl != 0 && current_tp != 0)
      return;
   double open_price = OrderGetDouble(ORDER_PRICE_OPEN);
   ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    sym_digits= (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   bool is_buy = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
   double new_sl = current_sl, new_tp = current_tp;
   if(current_sl == 0 && InpStopLoss > 0)
      new_sl = NormalizeDouble(open_price + (is_buy ? -1 : 1) * InpStopLoss * point, sym_digits);
   if(current_tp == 0 && InpTakeProfit > 0)
      new_tp = NormalizeDouble(open_price + (is_buy ? 1 : -1) * InpTakeProfit * point, sym_digits);
   if(new_sl != current_sl || new_tp != current_tp)
      trade.OrderModify(ticket, open_price, new_sl, new_tp, ORDER_TIME_GTC, 0);
  }

// ===============================
// Break-even
// ===============================
void ManageBreakEven()
  {
   CleanupStates();
   if(InpCombinePositions)
     {
      PositionGroup buy_group = GetPositionGroup(_Symbol, POSITION_TYPE_BUY);
      if(buy_group.ticket_count > 0)
         ApplyBreakEvenToGroup(buy_group, _Symbol, POSITION_TYPE_BUY);
      PositionGroup sell_group = GetPositionGroup(_Symbol, POSITION_TYPE_SELL);
      if(sell_group.ticket_count > 0)
         ApplyBreakEvenToGroup(sell_group, _Symbol, POSITION_TYPE_SELL);
     }
   else
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0)
           {
            string symbol = PositionGetString(POSITION_SYMBOL);
            if(symbol == _Symbol)
               ApplyBreakEvenSingle(ticket, symbol);
           }
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ApplyBreakEvenToGroup(PositionGroup &group, string symbol, ENUM_POSITION_TYPE direction)
  {
   if(group.total_volume == 0)
      return;
   double avg_entry = group.weighted_entry / group.total_volume;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int sym_digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double current_price = (direction == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                          : SymbolInfoDouble(symbol, SYMBOL_ASK);
   double profit_points = (direction == POSITION_TYPE_BUY) ? (current_price - avg_entry) / point
                          : (avg_entry - current_price) / point;
   if(profit_points >= InpBEPoints)
     {
      double be_price = NormalizeDouble(avg_entry + InpSlippageMargin * point * (direction == POSITION_TYPE_BUY ? 1 : -1), sym_digits);
      for(int i = 0; i < group.ticket_count; i++)
        {
         if(!PositionSelectByTicket(group.tickets[i]))
            continue;
         int s = GetPositionStateIndex(group.tickets[i]);
         if(s >= 0 && position_states[s].be_applied)
            continue;
         double current_sl = PositionGetDouble(POSITION_SL);
         bool should_modify = false;
         if(direction == POSITION_TYPE_BUY && (current_sl == 0 || be_price > current_sl))
            should_modify = true;
         else
            if(direction == POSITION_TYPE_SELL && (current_sl == 0 || be_price < current_sl))
               should_modify = true;
         if(should_modify)
           {
            if(trade.PositionModify(group.tickets[i], be_price, PositionGetDouble(POSITION_TP)))
              {
               if(s >= 0)
                  position_states[s].be_applied = true;
               Print("BE applied to #", group.tickets[i], " at ", be_price);
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ApplyBreakEvenSingle(ulong ticket, string symbol)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   int s = GetPositionStateIndex(ticket);
   if(s >= 0 && position_states[s].be_applied)
      return;
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int sym_digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                          : SymbolInfoDouble(symbol, SYMBOL_ASK);
   double profit_points = (type == POSITION_TYPE_BUY) ? (current_price - open_price) / point
                          : (open_price - current_price) / point;
   if(profit_points >= InpBEPoints)
     {
      double be_price = NormalizeDouble(open_price + InpSlippageMargin * point * (type == POSITION_TYPE_BUY ? 1 : -1), sym_digits);
      bool should_modify = false;
      if(type == POSITION_TYPE_BUY && (current_sl == 0 || be_price > current_sl))
         should_modify = true;
      else
         if(type == POSITION_TYPE_SELL && (current_sl == 0 || be_price < current_sl))
            should_modify = true;
      if(should_modify)
        {
         if(trade.PositionModify(ticket, be_price, PositionGetDouble(POSITION_TP)))
           {
            if(s >= 0)
               position_states[s].be_applied = true;
            Print("BE applied to #", ticket, " at ", be_price);
           }
        }
     }
  }

// ===============================
// Auto partials (combined pool logic, linear only)
// ===============================
int ComputeGroupStep(PositionGroup &group)
  {
   int maxd=0;
   for(int i=0;i<group.ticket_count;i++)
     {
      int s = GetPositionStateIndex(group.tickets[i]);
      if(s>=0 && position_states[s].partials_done>maxd)
         maxd = position_states[s].partials_done;
     }
   return maxd;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void MarkAdvanceStep(PositionGroup &group, int new_step)
  {
   for(int i=0;i<group.ticket_count;i++)
     {
      int s = GetPositionStateIndex(group.tickets[i]);
      if(s>=0)
         position_states[s].partials_done = new_step;
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void AccumulateExecuted(ulong ticket, double close_vol, double close_price)
  {
   int s = GetPositionStateIndex(ticket);
   if(s < 0)
      return;
   position_states[s].exec_pxvol += close_price * close_vol;
   position_states[s].exec_vol   += close_vol;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CloseFromPool(PositionGroup &group, double required_volume, double min_lot, double lot_step, int vol_digits, double exec_price)
  {
   double remaining = required_volume;
   double closed_total = 0.0;
   for(int i=0;i<group.ticket_count && remaining >= min_lot; i++)
     {
      ulong ticket = group.tickets[i];
      if(!PositionSelectByTicket(ticket))
         continue;
      double pos_vol = PositionGetDouble(POSITION_VOLUME);
      if(pos_vol < min_lot)
         continue;
      double close_vol = MathMin(pos_vol, remaining);
      close_vol = NormalizeToStep(close_vol, lot_step, vol_digits);
      if(close_vol < min_lot)
         continue;
      if(trade.PositionClosePartial(ticket, close_vol))
        {
         closed_total += close_vol;
         remaining -= close_vol;
         AccumulateExecuted(ticket, close_vol, exec_price);
        }
     }
   return closed_total;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ProcessGroupAutoPartials(PositionGroup &group, string symbol, ENUM_POSITION_TYPE direction)
  {
   if(group.total_volume <= 0.0)
      return;
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_tp    = (group.weighted_tp > 0.0) ? (group.weighted_tp / group.total_volume) : 0.0;
   if(avg_tp == 0.0)
      return;
   double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   int vol_digits  = VolumePrecision(lot_step);
   if(point<=0.0 || min_lot<=0.0 || lot_step<=0.0)
      return;
   double current_price = (direction==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                          : SymbolInfoDouble(symbol, SYMBOL_ASK);
   double profit_points = (direction==POSITION_TYPE_BUY) ? (current_price - avg_entry)/point
                          : (avg_entry - current_price)/point;
   if(profit_points <= 0.0)
      return;
   int feasible = (int)(group.total_volume / lot_step);
   if(feasible > InpEffectivePartials)
      feasible = InpEffectivePartials;
   if(feasible <= 1)
      return;
   double levels[], sizes[];
   GeneratePartialLevels(avg_entry, avg_tp, feasible, direction, levels);
   GeneratePartialSizes(group.total_volume, feasible, sizes, lot_step, vol_digits);
   int step_done = ComputeGroupStep(group);
   if(step_done >= feasible)
      return;
   double next_level_price = levels[step_done];
   bool level_reached = (direction==POSITION_TYPE_BUY) ? (current_price >= next_level_price)
                        : (current_price <= next_level_price);
   if(!level_reached)
      return;
   double required = sizes[step_done];
   required = Clamp(required, min_lot, group.total_volume);
   double closed = CloseFromPool(group, required, min_lot, lot_step, vol_digits, current_price);
   if(closed >= min_lot)
     {
      MarkAdvanceStep(group, step_done + 1);
      Print("Combined auto partial step #", (step_done+1), " closed total: ", closed,
            " lots at level ", DoubleToString(next_level_price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ManagePartialClose()
  {
   CleanupStates();
   if(InpCombinePositions)
     {
      PositionGroup buy_group = GetPositionGroup(_Symbol, POSITION_TYPE_BUY);
      if(buy_group.ticket_count > 0)
         ProcessGroupAutoPartials(buy_group, _Symbol, POSITION_TYPE_BUY);
      PositionGroup sell_group = GetPositionGroup(_Symbol, POSITION_TYPE_SELL);
      if(sell_group.ticket_count > 0)
         ProcessGroupAutoPartials(sell_group, _Symbol, POSITION_TYPE_SELL);
     }
   else
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double tp_price   = PositionGetDouble(POSITION_TP);
         double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double min_lot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double lot_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         int vol_digits    = VolumePrecision(lot_step);
         if(tp_price<=0.0 || point<=0.0 || min_lot<=0.0 || lot_step<=0.0)
            continue;
         int s = GetPositionStateIndex(ticket);
         if(s < 0)
            continue;
         double current_vol = PositionGetDouble(POSITION_VOLUME);
         if(current_vol < min_lot)
            continue;
         int feasible = (int)(current_vol / lot_step);
         if(feasible > InpEffectivePartials)
            feasible = InpEffectivePartials;
         if(feasible <= 1)
            continue;
         double levels[], sizes[];
         GeneratePartialLevels(open_price, tp_price, feasible, type, levels);
         GeneratePartialSizes(current_vol, feasible, sizes, lot_step, vol_digits);
         int step = position_states[s].partials_done;
         if(step >= feasible)
            continue;
         double current_price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double next_level = levels[step];
         bool level_reached = (type==POSITION_TYPE_BUY) ? (current_price >= next_level)
                              : (current_price <= next_level);
         if(!level_reached)
            continue;
         double req = Clamp(sizes[step], min_lot, current_vol);
         req = NormalizeToStep(req, lot_step, vol_digits);
         if(req < min_lot)
            continue;
         if(trade.PositionClosePartial(ticket, req))
           {
            position_states[s].partials_done = step + 1;
            AccumulateExecuted(ticket, req, current_price);
            Print("Position #", ticket, " auto partial step #", position_states[s].partials_done,
                  " closed: ", req, " lots at ", DoubleToString(current_price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
           }
        }
     }
  }

// ===============================
// Dashboard (planned+executed weighted TP and RR)
// ===============================
double CalculateTotalRisk()
  {
   double totalRisk = 0;
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) <= 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double lots = PositionGetDouble(POSITION_VOLUME);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(sl > 0 && point > 0)
        {
         double diff = isBuy ? (entry - sl) : (sl - entry);
         totalRisk += (diff / point) * pointValue * lots;
        }
     }
   return totalRisk;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   PositionGroup buy_group  = GetPositionGroup(_Symbol, POSITION_TYPE_BUY);
   PositionGroup sell_group = GetPositionGroup(_Symbol, POSITION_TYPE_SELL);
   if(buy_group.ticket_count == 0 && sell_group.ticket_count == 0)
     {
      DisplayNoPositions();
      return;
     }
// Aggregate PnL
   double totalPnL = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      totalPnL += PositionGetDouble(POSITION_PROFIT);
     }
// Direction and averages
   double netLots = buy_group.total_volume - sell_group.total_volume;
   string dir;
   double avgEntry, avgSL;
   if(netLots > 0.001)
     {
      dir = "BUY";
      avgEntry = buy_group.weighted_entry / buy_group.total_volume;
      avgSL    = (buy_group.weighted_sl > 0) ? (buy_group.weighted_sl / buy_group.total_volume) : 0;
     }
   else
      if(netLots < -0.001)
        {
         dir = "SELL";
         netLots = MathAbs(netLots);
         avgEntry = sell_group.weighted_entry / sell_group.total_volume;
         avgSL    = (sell_group.weighted_sl > 0) ? (sell_group.weighted_sl / sell_group.total_volume) : 0;
        }
      else
        {
         dir = "HEDG";
         double total_vol = buy_group.total_volume + sell_group.total_volume;
         avgEntry = (buy_group.weighted_entry + sell_group.weighted_entry) / total_vol;
         avgSL    = (buy_group.weighted_sl + sell_group.weighted_sl) / total_vol;
        }
// TP and Reward logic
   double overallWeightedExit = 0.0;
   double totalReward = 0.0;
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpEnablePartials)
     {
      overallWeightedExit = OverallWeightedTP_PlannedAndExecuted();
      totalReward         = TotalReward_PlannedAndExecuted();
     }
   else
     {
      double sum_tp=0.0, sum_vol=0.0;
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket<=0)
            continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         double tp    = PositionGetDouble(POSITION_TP);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double vol   = PositionGetDouble(POSITION_VOLUME);
         bool isBuy   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         if(tp>0.0 && vol>0.0)
           {
            sum_tp += tp*vol;
            sum_vol+= vol;
            double diff = isBuy ? (tp - entry) : (entry - tp);
            totalReward += (diff/point) * pointValue * vol;
           }
        }
      overallWeightedExit = (sum_vol>0.0) ? (sum_tp/sum_vol) : 0.0;
     }
   double totalRisk = CalculateTotalRisk();
// RR calculations
   string currentRR = "∞", targetRR = "∞";
   if(totalRisk > 0.001)
     {
      currentRR = DoubleToString(MathAbs(totalPnL) / totalRisk, 1);
      if(totalReward > 0.001)
         targetRR = DoubleToString(totalReward / totalRisk, 1);
     }
// Formatting
   int priceDec = (InpPriceDecimals < 0) ? (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) : InpPriceDecimals;
   int moneyDec = (InpMoneyDecimals < 0) ? 0 : ((InpMoneyDecimals > 2) ? 2 : InpMoneyDecimals);
   string pnlSign = (totalPnL >= 0) ? "+" : "-";
   string pnlText = pnlSign + currencySymbol + DoubleToString(MathAbs(totalPnL), moneyDec);
   string entryStr = DoubleToString(avgEntry, priceDec);
   string slStr    = (avgSL>0) ? DoubleToString(avgSL, priceDec) + " " + currencySymbol + DoubleToString(totalRisk, moneyDec) : "Not Set";
   string tpStr    = (overallWeightedExit>0) ? DoubleToString(overallWeightedExit, priceDec) + " " + currencySymbol + DoubleToString(totalReward, moneyDec) : "Not Set";
   DisplayDashboard(dir, netLots, entryStr, pnlText, totalPnL, currentRR, targetRR, slStr, tpStr);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DisplayNoPositions()
  {
   if(InpSingleLineMode)
     {
      string posStr = "No Open Positions";
      int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int totalW = GetTextPixelWidth(posStr);
      int baseX = InpCenterLine ? (chartW - totalW) / 2 : InpXDistance;
      SetDashText("Line1_Pos", posStr, colorText);
      ObjectSetInteger(0, "TM_Line1_Pos", OBJPROP_XDISTANCE, baseX);
      SetDashText("Line1_PnL", " ", colorText);
      SetDashText("Line1_SL", " ", colorSL);
      SetDashText("Line1_TP", " ", colorTP);
     }
   else
     {
      SetDashText("Line1", "No Open Positions", colorText);
      SetDashText("Line2", "P&L " + currencySymbol + "0.00", colorText);
      SetDashText("Line3", "SL  Not Set", colorSL);
      SetDashText("Line4", "TP  Not Set", colorTP);
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DisplayDashboard(string dir, double lots, string entry, string pnl, double pnlValue,
                      string currentRR, string targetRR, string sl, string tp)
  {
   ENUM_BASE_CORNER corner;
   switch(InpCorner)
     {
      case DASH_CORNER_LEFT_UPPER:
         corner = CORNER_LEFT_UPPER;
         break;
      case DASH_CORNER_LEFT_LOWER:
         corner = CORNER_LEFT_LOWER;
         break;
      case DASH_CORNER_RIGHT_UPPER:
         corner = CORNER_RIGHT_UPPER;
         break;
      case DASH_CORNER_RIGHT_LOWER:
         corner = CORNER_RIGHT_LOWER;
         break;
      default:
         corner = CORNER_LEFT_LOWER;
     }
   if(InpSingleLineMode)
     {
      string posStr = dir + " " + DoubleToString(MathAbs(lots), 2) + " @" + entry;
      string pnlStr = " | P&L=" + pnl + " RR(" + currentRR + "/" + targetRR + ")";
      string slFullStr = " | SL@" + sl;
      string tpFullStr = " | TP@" + tp;
      color pnlColor = (pnlValue >= 0) ? colorProfit : colorLoss;
      int posW = GetTextPixelWidth(posStr);
      int pnlW = GetTextPixelWidth(pnlStr);
      int slW  = GetTextPixelWidth(slFullStr);
      int tpW  = GetTextPixelWidth(tpFullStr);
      int totalW = posW + pnlW + slW + tpW;
      int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int baseX = InpCenterLine ? (chartW - totalW) / 2 : InpXDistance;
      int xPos = baseX;
      SetDashText("Line1_Pos", posStr, colorText);
      ObjectSetInteger(0, "TM_Line1_Pos", OBJPROP_XDISTANCE, xPos);
      xPos += posW;
      SetDashText("Line1_PnL", pnlStr, pnlColor);
      ObjectSetInteger(0, "TM_Line1_PnL", OBJPROP_XDISTANCE, xPos);
      xPos += pnlW;
      SetDashText("Line1_SL", slFullStr, colorSL);
      ObjectSetInteger(0, "TM_Line1_SL", OBJPROP_XDISTANCE, xPos);
      xPos += slW;
      SetDashText("Line1_TP", tpFullStr, colorTP);
      ObjectSetInteger(0, "TM_Line1_TP", OBJPROP_XDISTANCE, xPos);
     }
   else
     {
      string line1 = dir + " " + DoubleToString(MathAbs(lots), 2) + " @" + entry;
      string line2 = "P&L=" + pnl + " (" + currentRR + "/" + targetRR + ")RR";
      string line3 = "SL@" + sl;
      string line4 = "TP@" + tp;
      SetDashText("Line1", line1, colorText);
      SetDashText("Line2", line2, (pnlValue >= 0) ? colorProfit : colorLoss);
      SetDashText("Line3", line3, colorSL);
      SetDashText("Line4", line4, colorTP);
      int adjustedX = InpXDistance;
      if(corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER)
         adjustedX += GetTextPixelWidth(line2) + 15;
      ObjectSetInteger(0, "TM_Line1", OBJPROP_XDISTANCE, adjustedX);
      ObjectSetInteger(0, "TM_Line2", OBJPROP_XDISTANCE, adjustedX);
      ObjectSetInteger(0, "TM_Line3", OBJPROP_XDISTANCE, adjustedX);
      ObjectSetInteger(0, "TM_Line4", OBJPROP_XDISTANCE, adjustedX);
     }
  }

// ===============================
// Lines (dynamic cleanup)
// ===============================
void DrawLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width, string label)
  {
   if(ObjectFind(0, name) >= 0)
     {
      double current_price = ObjectGetDouble(0, name, OBJPROP_PRICE);
      if(MathAbs(current_price - price) > 0.00001)
         ObjectSetDouble(0, name, OBJPROP_PRICE, price);
      return;
     }
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateLines()
  {
   if(!InpEnablePartials)
      return;
   string active_lines[];
   int active_count = 0;
   if(InpCombinePositions)
     {
      PositionGroup buy_group = GetPositionGroup(_Symbol, POSITION_TYPE_BUY);
      if(buy_group.ticket_count > 0)
        {
         DrawCombinedLines(buy_group, POSITION_TYPE_BUY);
         int feasible = (int)(buy_group.total_volume / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
         feasible = MathMin(feasible, InpEffectivePartials);
         int step_done = ComputeGroupStep(buy_group);
         if(InpEnableBE)
           {
            ArrayResize(active_lines, active_count+1);
            active_lines[active_count++] = "TM_Line_Combined_BUY_BE";
           }
         for(int j = step_done; j < feasible; j++)
           {
            ArrayResize(active_lines, active_count+1);
            active_lines[active_count++] = "TM_Line_Combined_BUY_P" + IntegerToString(j+1);
           }
        }
      PositionGroup sell_group = GetPositionGroup(_Symbol, POSITION_TYPE_SELL);
      if(sell_group.ticket_count > 0)
        {
         DrawCombinedLines(sell_group, POSITION_TYPE_SELL);
         int feasible = (int)(sell_group.total_volume / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
         feasible = MathMin(feasible, InpEffectivePartials);
         int step_done = ComputeGroupStep(sell_group);
         if(InpEnableBE)
           {
            ArrayResize(active_lines, active_count+1);
            active_lines[active_count++] = "TM_Line_Combined_SELL_BE";
           }
         for(int j = step_done; j < feasible; j++)
           {
            ArrayResize(active_lines, active_count+1);
            active_lines[active_count++] = "TM_Line_Combined_SELL_P" + IntegerToString(j+1);
           }
        }
     }
   else
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         DrawPositionLines(ticket);
         string prefix = "TM_Line_" + IntegerToString(ticket) + "_";
         ArrayResize(active_lines, active_count+1);
         active_lines[active_count++] = prefix + "BE";
         if(PositionSelectByTicket(ticket))
           {
            double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double vol      = PositionGetDouble(POSITION_VOLUME);
            int feasible = (int)(vol / lot_step);
            feasible = MathMin(feasible, InpEffectivePartials);
            int s = GetPositionStateIndex(ticket);
            int step_done = (s>=0) ? position_states[s].partials_done : 0;
            for(int j=step_done;j<feasible;j++)
              {
               ArrayResize(active_lines, active_count+1);
               active_lines[active_count++] = prefix + "P" + IntegerToString(j+1);
              }
           }
        }
     }
   for(int i = ObjectsTotal(0, 0, OBJ_HLINE) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, OBJ_HLINE);
      if(StringFind(name, "TM_Line_") == 0)
        {
         bool should_keep = false;
         for(int j = 0; j < active_count; j++)
           {
            if(name == active_lines[j])
              {
               should_keep = true;
               break;
              }
           }
         if(!should_keep)
            ObjectDelete(0, name);
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawCombinedLines(PositionGroup &group, ENUM_POSITION_TYPE direction)
  {
   if(group.ticket_count == 0)
      return;
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_tp    = (group.weighted_tp > 0.0) ? (group.weighted_tp / group.total_volume) : 0.0;
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int vol_digits   = VolumePrecision(lot_step);
   string dir_str = (direction == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   string prefix  = "TM_Line_Combined_" + dir_str + "_";
   if(InpEnableBE)
     {
      double be_price = avg_entry + InpSlippageMargin * point * (direction == POSITION_TYPE_BUY ? 1 : -1);
      DrawLine(prefix + "BE", be_price, clrYellow, STYLE_DOT, 1, "BE-" + dir_str);
     }
   if(avg_tp <= 0.0 || lot_step <= 0.0 || group.total_volume <= 0.0)
      return;
   int feasible = (int)(group.total_volume / lot_step);
   if(feasible > InpEffectivePartials)
      feasible = InpEffectivePartials;
   if(feasible <= 1)
      return;
   double levels[], sizes[];
   GeneratePartialLevels(avg_entry, avg_tp, feasible, direction, levels);
   GeneratePartialSizes(group.total_volume, feasible, sizes, lot_step, vol_digits);
   int step_done = ComputeGroupStep(group);
   for(int j = step_done; j < feasible; j++)
     {
      double price_j = levels[j];
      DrawLine(prefix + "P" + IntegerToString(j+1), price_j, clrGray, STYLE_DOT, 1, "P" + IntegerToString(j+1) + "-" + dir_str);
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPositionLines(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp_price   = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int vol_digits    = VolumePrecision(lot_step);
   double current_vol= PositionGetDouble(POSITION_VOLUME);
   string prefix = "TM_Line_" + IntegerToString(ticket) + "_";
   if(InpEnableBE)
     {
      double be_price = open_price + InpSlippageMargin * point * (type == POSITION_TYPE_BUY ? 1 : -1);
      DrawLine(prefix + "BE", be_price, clrYellow, STYLE_DOT, 1, "BE");
     }
   if(tp_price <= 0.0 || lot_step <= 0.0 || current_vol <= 0.0)
      return;
   int feasible = (int)(current_vol / lot_step);
   if(feasible > InpEffectivePartials)
      feasible = InpEffectivePartials;
   if(feasible <= 1)
      return;
   double levels[], sizes[];
   GeneratePartialLevels(open_price, tp_price, feasible, type, levels);
   GeneratePartialSizes(current_vol, feasible, sizes, lot_step, vol_digits);
   int s = GetPositionStateIndex(ticket);
   int step_done = (s>=0) ? position_states[s].partials_done : 0;
   for(int j = step_done; j < feasible; j++)
     {
      double price_j = levels[j];
      DrawLine(prefix + "P" + IntegerToString(j+1), price_j, clrGray, STYLE_DOT, 1, "P" + IntegerToString(j+1));
     }
  }

// ===============================
// Visual cleanup
// ===============================
void DeleteAllVisuals()
  {
   ObjectDelete(0, "TM_Line1");
   ObjectDelete(0, "TM_Line2");
   ObjectDelete(0, "TM_Line3");
   ObjectDelete(0, "TM_Line4");
   ObjectDelete(0, "TM_Line1_Pos");
   ObjectDelete(0, "TM_Line1_PnL");
   ObjectDelete(0, "TM_Line1_SL");
   ObjectDelete(0, "TM_Line1_TP");
   for(int i = ObjectsTotal(0, 0, OBJ_HLINE) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, OBJ_HLINE);
      if(StringFind(name, "TM_Line_") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
