//+------------------------------------------------------------------+
//|                              smaGUY Auto Risk Management.mq5.mq5 |
//|                      Refactored: Always Combine, Fixed Partials  |
//+------------------------------------------------------------------+
#property copyright "Simple Trade Manager v15"
#property version   "15.00"
#property strict

#include <Trade\Trade.mqh>

// ===============================
// Inputs
// ===============================
input group "=== Stop Loss & Take Profit ==="
input double InpStopLoss = 1000;           // Stop Loss (points)
input double InpTakeProfit = 5000;         // Take Profit (points)
input double InpSlippageMargin = 100;      // Break-even offset (points)
input bool   InpShowSLLevel = true;        // Show SL level line

input group "=== Auto Partials ==="
input bool InpEnablePartials = false;      // Enable Auto Partials
input int  InpMaxPartials = 5;             // Maximum partial steps (excluding final TP)
input bool InpShowPartialLevels = true;    // Show partial level lines

input group "=== Auto Break-Even ==="
input bool   InpEnableBE = false;          // Enable Auto Break-Even
input double InpBEPoints = 3000;           // BE Trigger (points in profit)
input bool   InpShowBELevel = true;        // Show BE level line

input group "=== Auto Trailing Stop ==="
input bool   InpEnableTrailing = false;    // Enable trailing stop
input double InpTrailTrigger = 3000;       // Trigger level (points in profit)
input double InpTrailDistance = 1000;      // Distance to trail (points)

input group "=== Dashboard Settings ==="
input bool InpEnableDashboard = true;      // Enable dashboard display
input bool InpSingleLineMode = true;       // Single line dashboard
enum ENUM_DASHBOARD_CORNER {
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

// ===============================
// Globals
// ===============================
CTrade trade;
string currencySymbol;
bool isDarkTheme;
color colorText, colorProfit, colorLoss, colorSL, colorTP;

// Position tracking structure
struct PositionState {
   ulong ticket;
   double original_volume;      // Initial volume when position opened
   double exec_pxvol;          // Sum(executed_price * executed_volume) for closed partials
   double exec_vol;            // Sum(executed_volume) for closed partials
   int partials_done;          // Number of partial steps completed
   bool be_applied;            // Break-even applied flag
};
PositionState position_states[];

// Combined group for net exposure
struct NetGroup {
   string direction;           // "BUY", "SELL", or "HEDG"
   double net_volume;          // Net lots (positive for buy, negative for sell)
   double total_volume;        // Total volume (for hedged positions)
   double weighted_entry;      // Volume-weighted entry price
   double weighted_sl;         // Volume-weighted SL
   double weighted_tp;         // Volume-weighted TP
   double original_volume;     // Sum of original volumes
   int step_done;             // Highest partial step completed across all positions
   ulong tickets[];
   int ticket_count;
};

// ===============================
// Utility Functions
// ===============================
double NormalizeVolume(double vol) {
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0) return NormalizeDouble(vol, 2);
   double steps = MathFloor(vol / lot_step + 1e-8);
   int digits = 0;
   double temp = lot_step;
   while(temp < 1.0 && digits < 8) { temp *= 10.0; digits++; }
   return NormalizeDouble(steps * lot_step, digits);
}

int VolumeDigits() {
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0) return 2;
   int digits = 0;
   double temp = lot_step;
   while(temp < 1.0 && digits < 8) { temp *= 10.0; digits++; }
   return digits;
}

void BuildStepVolumePlan(double total_volume, int total_steps, double &plan[]) {
   ArrayResize(plan, 0);
   if(total_steps <= 0) return;
   
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0) return;
   
   int digits = VolumeDigits();
   int total_units = (int)MathRound(total_volume / lot_step);
   if(total_units <= 0) return;
   
   if(total_steps > total_units) total_steps = total_units;
   if(total_steps <= 0) return;
   
   ArrayResize(plan, total_steps);
   
   int base_units = total_units / total_steps;
   int remainder = total_units - base_units * total_steps;
   
   double sum_plan = 0;
   for(int i = 0; i < total_steps; i++) {
      int units = base_units + ((i < remainder) ? 1 : 0);
      plan[i] = NormalizeDouble(units * lot_step, digits);
      sum_plan += plan[i];
   }
   
   double normalized_total = NormalizeDouble(total_units * lot_step, digits);
   double diff = NormalizeDouble(normalized_total - sum_plan, digits);
   if(MathAbs(diff) > 0 && ArraySize(plan) > 0) {
      plan[ArraySize(plan) - 1] = NormalizeDouble(plan[ArraySize(plan) - 1] + diff, digits);
   }
}

double ClampVolume(double vol) {
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(vol < min_lot) return 0;
   if(vol > max_lot) return max_lot;
   return vol;
}

// ===============================
// Position State Management
// ===============================
int FindStateIndex(ulong ticket) {
   for(int i = 0; i < ArraySize(position_states); i++)
      if(position_states[i].ticket == ticket) return i;
   return -1;
}

void InitPositionState(ulong ticket) {
   if(!PositionSelectByTicket(ticket)) return;
   if(FindStateIndex(ticket) >= 0) return;
   
   int idx = ArraySize(position_states);
   ArrayResize(position_states, idx + 1);
   
   position_states[idx].ticket = ticket;
   position_states[idx].original_volume = PositionGetDouble(POSITION_VOLUME);
   position_states[idx].exec_pxvol = 0.0;
   position_states[idx].exec_vol = 0.0;
   position_states[idx].partials_done = 0;
   position_states[idx].be_applied = false;
   
   Print("Initialized state for position #", ticket, " with volume ", position_states[idx].original_volume);
}

void CleanupClosedPositions() {
   for(int i = ArraySize(position_states) - 1; i >= 0; i--) {
      if(!PositionSelectByTicket(position_states[i].ticket)) {
         // Remove closed position
         for(int j = i; j < ArraySize(position_states) - 1; j++)
            position_states[j] = position_states[j + 1];
         ArrayResize(position_states, ArraySize(position_states) - 1);
      }
   }
}

void RecordPartialExecution(ulong ticket, double closed_vol, double close_price) {
   int idx = FindStateIndex(ticket);
   if(idx < 0) return;
   
   position_states[idx].exec_pxvol += close_price * closed_vol;
   position_states[idx].exec_vol += closed_vol;
   position_states[idx].partials_done++;
   
   Print("Recorded partial for #", ticket, ": ", closed_vol, " lots at ", close_price,
         " | Total executed: ", position_states[idx].exec_vol);
}

// ===============================
// Net Group Calculation
// ===============================
NetGroup CalculateNetGroup() {
   NetGroup group;
   group.net_volume = 0;
   group.total_volume = 0;
   group.weighted_entry = 0;
   group.weighted_sl = 0;
   group.weighted_tp = 0;
   group.original_volume = 0;
   group.step_done = 0;
   group.ticket_count = 0;
   ArrayResize(group.tickets, 0);
   
   double buy_vol = 0, sell_vol = 0;
   
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp = PositionGetDouble(POSITION_TP);
      double sl = PositionGetDouble(POSITION_SL);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      
      group.total_volume += volume;
      group.weighted_entry += entry * volume;
      if(tp > 0) group.weighted_tp += tp * volume;
      if(sl > 0) group.weighted_sl += sl * volume;
      
      if(isBuy) buy_vol += volume;
      else sell_vol += volume;
      
      int idx = FindStateIndex(ticket);
      if(idx >= 0) {
         group.original_volume += position_states[idx].original_volume;
         if(position_states[idx].partials_done > group.step_done)
            group.step_done = position_states[idx].partials_done;
      } else {
         group.original_volume += volume;
      }
      
      ArrayResize(group.tickets, group.ticket_count + 1);
      group.tickets[group.ticket_count++] = ticket;
   }
   
   group.net_volume = buy_vol - sell_vol;
   
   if(group.net_volume > 0.001) group.direction = "BUY";
   else if(group.net_volume < -0.001) group.direction = "SELL";
   else group.direction = "HEDG";
   
   return group;
}

// ===============================
// Analyze positions for manual partials (different TPs)
// ===============================
struct ManualPartialInfo {
   ulong ticket;
   double tp_price;
   double current_volume;
   double original_volume;
};

void AnalyzeManualPartials(NetGroup &group, ManualPartialInfo &manual_partials[], double &auto_partial_volume) {
   ArrayResize(manual_partials, 0);
   auto_partial_volume = 0;
   
   if(group.ticket_count == 0) return;
   
   double avg_tp = (group.weighted_tp > 0 && group.total_volume > 0) ? (group.weighted_tp / group.total_volume) : 0;
   double avg_entry = (group.total_volume > 0) ? (group.weighted_entry / group.total_volume) : 0;
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   
   // Check each position's TP
   for(int i = 0; i < group.ticket_count; i++) {
      if(!PositionSelectByTicket(group.tickets[i])) continue;
      
      double pos_tp = PositionGetDouble(POSITION_TP);
      double pos_vol = PositionGetDouble(POSITION_VOLUME);
      int idx = FindStateIndex(group.tickets[i]);
      if(idx < 0) {
         InitPositionState(group.tickets[i]);
         idx = FindStateIndex(group.tickets[i]);
      }
      double orig_vol = (idx >= 0) ? position_states[idx].original_volume : pos_vol;
      
      bool is_manual = false;
      if(pos_tp > 0 && avg_tp > 0) {
         double tp_diff_percent = MathAbs(pos_tp - avg_tp) / avg_tp * 100.0;
         if(tp_diff_percent > 0.1) {
            bool is_before = isBuy ? (pos_tp < avg_tp) : (pos_tp > avg_tp);
            if(is_before) is_manual = true;
         }
      }
      
      if(is_manual) {
         int mp_idx = ArraySize(manual_partials);
         ArrayResize(manual_partials, mp_idx + 1);
         manual_partials[mp_idx].ticket = group.tickets[i];
         manual_partials[mp_idx].tp_price = pos_tp;
         manual_partials[mp_idx].current_volume = pos_vol;
         manual_partials[mp_idx].original_volume = orig_vol;
      } else {
         auto_partial_volume += pos_vol;
      }
   }
   
   auto_partial_volume = NormalizeVolume(auto_partial_volume);
}

// ===============================
// Calculate feasible partials based on volume
// ===============================
int CalculateFeasiblePartials(double volume) {
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(min_lot <= 0 || lot_step <= 0 || volume < min_lot) return 0;
   
   // Maximum partials we can physically execute
   int max_possible = (int)(volume / min_lot) - 1; // -1 to leave minimum for final TP
   if(max_possible < 1) return 0;
   
   // Return the smaller of: user preference OR physically possible
   return MathMin(InpMaxPartials, max_possible);
}

// ===============================
// Weighted TP Calculation (Planned + Executed)
// ===============================
double CalculateWeightedTP(NetGroup &group, int &feasible_partials_out) {
   feasible_partials_out = 0;
   
   if(group.total_volume <= 0) return 0;
   
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_tp = (group.weighted_tp > 0) ? (group.weighted_tp / group.total_volume) : 0;
   
   ManualPartialInfo manual_partials[];
   double auto_partial_volume = 0;
   AnalyzeManualPartials(group, manual_partials, auto_partial_volume);
   
   if(!InpEnablePartials || auto_partial_volume < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
      return (group.total_volume > 0) ? (group.weighted_tp / group.total_volume) : 0;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(point <= 0 || lot_step <= 0) return 0;
   if(avg_tp <= 0) return 0;
   
   // Determine direction
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   
   // Calculate feasible partials based on auto-partial volume
   int feasible_partials = CalculateFeasiblePartials(auto_partial_volume);
   int total_units = (int)MathRound(auto_partial_volume / lot_step);
   if(total_units <= 0) return (group.total_volume > 0) ? (group.weighted_tp / group.total_volume) : 0;
   if(feasible_partials + 1 > total_units)
      feasible_partials = MathMax(0, total_units - 1);
   feasible_partials_out = feasible_partials;
   
   if(feasible_partials < 1) {
      // Not enough volume for any partials, just use final TP
      return avg_tp;
   }
   
   // Total steps = feasible partials + 1 (for final TP)
   int total_steps = feasible_partials + 1;
   double step_plan[];
   BuildStepVolumePlan(auto_partial_volume, total_steps, step_plan);
   if(ArraySize(step_plan) != total_steps) return avg_tp;
   
   // Calculate distance between entry and TP
   double total_distance = MathAbs(avg_tp - avg_entry);
   double step_distance = total_distance / total_steps;
   
   // Accumulate weighted TP price
   double sum_pxvol = 0;
   double sum_vol = 0;
   
   // Add executed partials
   for(int i = 0; i < ArraySize(position_states); i++) {
      sum_pxvol += position_states[i].exec_pxvol;
      sum_vol += position_states[i].exec_vol;
   }

   // Include manual partial positions at their TP
   for(int i = 0; i < ArraySize(manual_partials); i++) {
      if(manual_partials[i].current_volume <= 0) continue;
      sum_pxvol += manual_partials[i].tp_price * manual_partials[i].current_volume;
      sum_vol += manual_partials[i].current_volume;
   }

   int steps_completed = group.step_done;
   if(steps_completed < 0) steps_completed = 0;
   if(steps_completed > feasible_partials) steps_completed = feasible_partials;
   
   // Add remaining planned partials (only up to feasible count)
   for(int step = steps_completed; step < feasible_partials; step++) {
      double volume_for_step = step_plan[step];
      if(volume_for_step < min_lot) continue;
      double distance = step_distance * (step + 1);
      double level_price = avg_entry + (isBuy ? distance : -distance);
      sum_pxvol += level_price * volume_for_step;
      sum_vol += volume_for_step;
   }
   
   // Add final TP for remaining volume
   double final_volume = step_plan[total_steps - 1];
   if(final_volume >= min_lot) {
      sum_pxvol += avg_tp * final_volume;
      sum_vol += final_volume;
   }
   
   return (sum_vol > 0) ? (sum_pxvol / sum_vol) : avg_tp;
}

// ===============================
// Reward Calculation (Money)
// ===============================
double CalculateTotalReward(NetGroup &group, int feasible_partials) {
   int fp_temp;
   double weighted_tp = CalculateWeightedTP(group, fp_temp);
   if(weighted_tp <= 0 || group.original_volume <= 0) return 0;
   
   double avg_entry = group.weighted_entry / group.total_volume;
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   
   double diff = isBuy ? (weighted_tp - avg_entry) : (avg_entry - weighted_tp);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double point_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   return (diff / point) * point_value * group.original_volume;
}

double CalculateTotalRisk(NetGroup &group) {
   if(group.weighted_sl <= 0 || group.total_volume <= 0) return 0;
   
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_sl = group.weighted_sl / group.total_volume;
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   
   double diff = isBuy ? (avg_entry - avg_sl) : (avg_sl - avg_entry);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double point_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   return (diff / point) * point_value * group.total_volume;
}

// ===============================
// Auto Partials Management
// ===============================
void ManagePartials() {
   if(!InpEnablePartials) return;
   
   CleanupClosedPositions();
   NetGroup group = CalculateNetGroup();
   
   if(group.ticket_count == 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   if(point <= 0 || lot_step <= 0 || min_lot <= 0) return;
   
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_tp = (group.weighted_tp > 0) ? (group.weighted_tp / group.total_volume) : 0;
   if(avg_tp <= 0) return;
   
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   double current_price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Check if in profit
   double profit_points = isBuy ? (current_price - avg_entry) / point : (avg_entry - current_price) / point;
   if(profit_points <= 0) return;
   
   // Analyze manual partials
   ManualPartialInfo manual_partials[];
   double auto_partial_volume = 0;
   AnalyzeManualPartials(group, manual_partials, auto_partial_volume);
   
   if(auto_partial_volume < min_lot) return;
   
   // Calculate feasible partials based on auto-partial volume only
   int feasible_partials = CalculateFeasiblePartials(auto_partial_volume);
   if(feasible_partials < 1) return;
   
   int total_units = (int)MathRound(auto_partial_volume / lot_step);
   if(total_units <= 0) return;
   
   if(feasible_partials + 1 > total_units)
      feasible_partials = MathMax(0, total_units - 1);
   if(feasible_partials < 1) return;
   
   int total_steps = feasible_partials + 1;
   double step_plan[];
   BuildStepVolumePlan(auto_partial_volume, total_steps, step_plan);
   if(ArraySize(step_plan) != total_steps) return;
   
   int volume_digits = VolumeDigits();
   int steps_completed = group.step_done;
   if(steps_completed >= feasible_partials) return;
   
   double step_size = step_plan[steps_completed];
   if(step_size < min_lot) return;
   
   double total_distance = MathAbs(avg_tp - avg_entry);
   double step_distance = total_distance / total_steps;
   
   double next_distance = step_distance * (steps_completed + 1);
   double next_level = avg_entry + (isBuy ? next_distance : -next_distance);
   
   bool level_reached = isBuy ? (current_price >= next_level) : (current_price <= next_level);
   if(!level_reached) return;
   
   // Close partial volume from pool (only from positions without manual partials)
   double remaining_to_close = step_size;
   for(int i = 0; i < group.ticket_count && remaining_to_close >= min_lot; i++) {
      ulong ticket = group.tickets[i];
      if(!PositionSelectByTicket(ticket)) continue;
      
      // Check if this position has a manual partial TP
      bool is_manual_partial = false;
      for(int j = 0; j < ArraySize(manual_partials); j++) {
         if(manual_partials[j].ticket == ticket) {
            is_manual_partial = true;
            break;
         }
      }
      if(is_manual_partial) continue; // Skip manual partial positions
      
      double pos_vol = PositionGetDouble(POSITION_VOLUME);
      if(pos_vol < min_lot) continue;
      
      double close_vol = MathMin(pos_vol, remaining_to_close);
      close_vol = NormalizeVolume(close_vol);
      close_vol = ClampVolume(close_vol);
      
      if(close_vol >= min_lot) {
         if(trade.PositionClosePartial(ticket, close_vol)) {
            RecordPartialExecution(ticket, close_vol, current_price);
            remaining_to_close = NormalizeDouble(remaining_to_close - close_vol, volume_digits);
            if(remaining_to_close < 0) remaining_to_close = 0;
            Print("Auto-Partial TP", (steps_completed + 1), " closed ", close_vol, 
                  " lots from #", ticket, " at ", current_price);
         }
      }
   }
}

// ===============================
// Break-Even Management
// ===============================
void ManageBreakEven() {
   if(!InpEnableBE) return;
   
   CleanupClosedPositions();
   NetGroup group = CalculateNetGroup();
   
   if(group.ticket_count == 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double avg_entry = group.weighted_entry / group.total_volume;
   
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   double current_price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double profit_points = isBuy ? (current_price - avg_entry) / point : (avg_entry - current_price) / point;
   
   if(profit_points >= InpBEPoints) {
      double be_price = NormalizeDouble(avg_entry + InpSlippageMargin * point * (isBuy ? 1 : -1), digits);
      
      for(int i = 0; i < group.ticket_count; i++) {
         ulong ticket = group.tickets[i];
         if(!PositionSelectByTicket(ticket)) continue;
         
         int idx = FindStateIndex(ticket);
         if(idx >= 0 && position_states[idx].be_applied) continue;
         
         double current_sl = PositionGetDouble(POSITION_SL);
         bool should_modify = (isBuy && (current_sl == 0 || be_price > current_sl)) ||
                            (!isBuy && (current_sl == 0 || be_price < current_sl));
         
         if(should_modify) {
            if(trade.PositionModify(ticket, be_price, PositionGetDouble(POSITION_TP))) {
               if(idx >= 0) position_states[idx].be_applied = true;
               Print("BE applied to #", ticket, " at ", be_price);
            }
         }
      }
   }
}

// ===============================
// Trailing Stop Management
// ===============================
void ManageTrailingStop() {
   if(!InpEnableTrailing) return;
   
   NetGroup group = CalculateNetGroup();
   if(group.ticket_count == 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double avg_entry = group.weighted_entry / group.total_volume;
   
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   double current_price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double profit_points = isBuy ? (current_price - avg_entry) / point : (avg_entry - current_price) / point;
   
   if(profit_points >= InpTrailTrigger) {
      double new_sl = NormalizeDouble(current_price + (isBuy ? -InpTrailDistance : InpTrailDistance) * point, digits);
      
      for(int i = 0; i < group.ticket_count; i++) {
         ulong ticket = group.tickets[i];
         if(!PositionSelectByTicket(ticket)) continue;
         
         double current_sl = PositionGetDouble(POSITION_SL);
         bool should_modify = (isBuy && new_sl > current_sl) || (!isBuy && (current_sl == 0 || new_sl < current_sl));
         
         if(should_modify)
            trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
      }
   }
}

// ===============================
// SL/TP Setting
// ===============================
void SetPositionSLTP(ulong ticket) {
   if(!PositionSelectByTicket(ticket)) return;
   
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   if(current_sl != 0 && current_tp != 0) return;
   
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double new_sl = current_sl;
   double new_tp = current_tp;
   
   if(current_sl == 0 && InpStopLoss > 0)
      new_sl = NormalizeDouble(entry + (isBuy ? -1 : 1) * InpStopLoss * point, digits);
   
   if(current_tp == 0 && InpTakeProfit > 0)
      new_tp = NormalizeDouble(entry + (isBuy ? 1 : -1) * InpTakeProfit * point, digits);
   
   if(new_sl != current_sl || new_tp != current_tp)
      trade.PositionModify(ticket, new_sl, new_tp);
}

void SetOrderSLTP(ulong ticket) {
   if(!OrderSelect(ticket)) return;
   
   double current_sl = OrderGetDouble(ORDER_SL);
   double current_tp = OrderGetDouble(ORDER_TP);
   if(current_sl != 0 && current_tp != 0) return;
   
   double price = OrderGetDouble(ORDER_PRICE_OPEN);
   ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   bool isBuy = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double new_sl = current_sl;
   double new_tp = current_tp;
   
   if(current_sl == 0 && InpStopLoss > 0)
      new_sl = NormalizeDouble(price + (isBuy ? -1 : 1) * InpStopLoss * point, digits);
   
   if(current_tp == 0 && InpTakeProfit > 0)
      new_tp = NormalizeDouble(price + (isBuy ? 1 : -1) * InpTakeProfit * point, digits);
   
   if(new_sl != current_sl || new_tp != current_tp)
      trade.OrderModify(ticket, price, new_sl, new_tp, ORDER_TIME_GTC, 0);
}

// ===============================
// Dashboard Functions
// ===============================
void InitializeDashboard() {
   string acc = AccountInfoString(ACCOUNT_CURRENCY);
   if(acc == "USD") currencySymbol = "$";
   else if(acc == "EUR") currencySymbol = "€";
   else if(acc == "GBP") currencySymbol = "£";
   else currencySymbol = acc + " ";
   
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int brightness = ((bg & 0xFF) + ((bg >> 8) & 0xFF) + ((bg >> 16) & 0xFF)) / 3;
   isDarkTheme = (brightness < 128);
   
   if(isDarkTheme) {
      colorText = clrWhite; colorProfit = clrLime; colorLoss = clrRed;
      colorSL = clrOrange; colorTP = clrDodgerBlue;
   } else {
      colorText = clrBlack; colorProfit = clrGreen; colorLoss = clrDarkRed;
      colorSL = clrDarkOrange; colorTP = clrBlue;
   }
   
   if(InpSingleLineMode) {
      CreateLabel("Line1_Pos", 0); CreateLabel("Line1_PnL", 0);
      CreateLabel("Line1_SL", 0); CreateLabel("Line1_TP", 0);
   } else {
      CreateLabel("Line1", 0); CreateLabel("Line2", 1);
      CreateLabel("Line3", 2); CreateLabel("Line4", 3);
   }
}

void CreateLabel(string name, int lineIndex) {
   string objName = "TM_" + name;
   ENUM_BASE_CORNER corner = (InpCorner == DASH_CORNER_RIGHT_UPPER || InpCorner == DASH_CORNER_RIGHT_LOWER) ? 
                             ((InpCorner == DASH_CORNER_RIGHT_UPPER) ? CORNER_RIGHT_UPPER : CORNER_RIGHT_LOWER) :
                             ((InpCorner == DASH_CORNER_LEFT_UPPER) ? CORNER_LEFT_UPPER : CORNER_LEFT_LOWER);
   
   bool isBottom = (corner == CORNER_LEFT_LOWER || corner == CORNER_RIGHT_LOWER);
   int yPos = InpYDistance + (InpSingleLineMode ? 0 : (isBottom ? (3 - lineIndex) : lineIndex) * InpLineSpacing);
   
   ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, objName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, InpXDistance);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, yPos);
   ObjectSetString(0, objName, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
}

void SetLabelText(string name, string text, color clr) {
   ObjectSetString(0, "TM_" + name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, "TM_" + name, OBJPROP_COLOR, clr);
}

int GetTextWidth(string text) { return (int)(StringLen(text) * InpFontSize * 0.75) + 15; }

void UpdateDashboard() {
   NetGroup group = CalculateNetGroup();
   
   if(group.ticket_count == 0) {
      DisplayNoPositions();
      return;
   }
   
   double totalPnL = 0;
   for(int i = 0; i < group.ticket_count; i++) {
      if(PositionSelectByTicket(group.tickets[i]))
         totalPnL += PositionGetDouble(POSITION_PROFIT);
   }
   
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_sl = (group.weighted_sl > 0) ? (group.weighted_sl / group.total_volume) : 0;
   
   // Get weighted TP and feasible partials
   int feasible_partials = 0;
   double weighted_tp = CalculateWeightedTP(group, feasible_partials);
   double total_reward = CalculateTotalReward(group, feasible_partials);
   double total_risk = CalculateTotalRisk(group);
   
   string currentRR = "∞", targetRR = "∞";
   if(total_risk > 0.001) {
      currentRR = DoubleToString(MathAbs(totalPnL) / total_risk, 1);
      if(total_reward > 0.001) targetRR = DoubleToString(total_reward / total_risk, 1);
   }
   
   int priceDec = (InpPriceDecimals < 0) ? (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) : InpPriceDecimals;
   int moneyDec = (InpMoneyDecimals < 0) ? 0 : InpMoneyDecimals;
   
   string pnlText = ((totalPnL >= 0) ? "+" : "-") + currencySymbol + DoubleToString(MathAbs(totalPnL), moneyDec);
   string entryStr = DoubleToString(avg_entry, priceDec);
   string slStr = (avg_sl > 0) ? DoubleToString(avg_sl, priceDec) + " " + currencySymbol + DoubleToString(total_risk, moneyDec) : "Not Set";
   
   // Show weighted TP with partial info
   string tpStr;
   if(weighted_tp > 0) {
      tpStr = DoubleToString(weighted_tp, priceDec) + " " + currencySymbol + DoubleToString(total_reward, moneyDec);
      if(InpEnablePartials && feasible_partials > 0) {
         tpStr += " (" + IntegerToString(feasible_partials) + "P)";
      }
   } else {
      tpStr = "Not Set";
   }
   
   double display_lots = (group.direction == "HEDG") ? group.total_volume : MathAbs(group.net_volume);
   
   if(InpSingleLineMode) {
      string posStr = group.direction + " " + DoubleToString(display_lots, 2) + " @" + entryStr;
      string pnlStr = " | P&L=" + pnlText + " RR(" + currentRR + "/" + targetRR + ")";
      string slFullStr = " | SL@" + slStr;
      string tpFullStr = " | TP@" + tpStr;
      
      color pnlColor = (totalPnL >= 0) ? colorProfit : colorLoss;
      int posW = GetTextWidth(posStr);
      int pnlW = GetTextWidth(pnlStr);
      int slW = GetTextWidth(slFullStr);
      int tpW = GetTextWidth(tpFullStr);
      int totalW = posW + pnlW + slW + tpW;
      int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int baseX = (chartW - totalW) / 2;
      
      SetLabelText("Line1_Pos", posStr, colorText);
      ObjectSetInteger(0, "TM_Line1_Pos", OBJPROP_XDISTANCE, baseX);
      SetLabelText("Line1_PnL", pnlStr, pnlColor);
      ObjectSetInteger(0, "TM_Line1_PnL", OBJPROP_XDISTANCE, baseX + posW);
      SetLabelText("Line1_SL", slFullStr, colorSL);
      ObjectSetInteger(0, "TM_Line1_SL", OBJPROP_XDISTANCE, baseX + posW + pnlW);
      SetLabelText("Line1_TP", tpFullStr, colorTP);
      ObjectSetInteger(0, "TM_Line1_TP", OBJPROP_XDISTANCE, baseX + posW + pnlW + slW);
   } else {
      SetLabelText("Line1", group.direction + " " + DoubleToString(display_lots, 2) + " @" + entryStr, colorText);
      SetLabelText("Line2", "P&L=" + pnlText + " (" + currentRR + "/" + targetRR + ")RR", (totalPnL >= 0) ? colorProfit : colorLoss);
      SetLabelText("Line3", "SL@" + slStr, colorSL);
      SetLabelText("Line4", "TP@" + tpStr, colorTP);
   }
}

void DisplayNoPositions() {
   if(InpSingleLineMode) {
      string posStr = "No Open Positions";
      int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int baseX = (chartW - GetTextWidth(posStr)) / 2;
      SetLabelText("Line1_Pos", posStr, colorText);
      ObjectSetInteger(0, "TM_Line1_Pos", OBJPROP_XDISTANCE, baseX);
      SetLabelText("Line1_PnL", " ", colorText);
      SetLabelText("Line1_SL", " ", colorSL);
      SetLabelText("Line1_TP", " ", colorTP);
   } else {
      SetLabelText("Line1", "No Open Positions", colorText);
      SetLabelText("Line2", "P&L " + currencySymbol + "0.00", colorText);
      SetLabelText("Line3", "SL  Not Set", colorSL);
      SetLabelText("Line4", "TP  Not Set", colorTP);
   }
}

// ===============================
// Visual Lines (Partials & BE)
// ===============================
void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, string label) {
   if(ObjectFind(0, name) >= 0) {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
      ObjectSetString(0, name, OBJPROP_TEXT, label);
      return;
   }
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
}

void UpdateLines() {
   NetGroup group = CalculateNetGroup();
   
   if(group.ticket_count == 0) {
      DeleteAllLines();
      return;
   }
   
   string active_lines[];
   int active_count = 0;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double avg_entry = group.weighted_entry / group.total_volume;
   double avg_tp = (group.weighted_tp > 0) ? (group.weighted_tp / group.total_volume) : 0;
   double avg_sl = (group.weighted_sl > 0) ? (group.weighted_sl / group.total_volume) : 0;
   bool isBuy = (group.direction == "BUY" || (group.direction == "HEDG" && group.net_volume >= 0));
   
   // Draw SL line with risk info
   if(InpShowSLLevel && avg_sl > 0) {
      double total_risk = CalculateTotalRisk(group);
      string sl_label = "SL " + DoubleToString(group.total_volume, 2) + "@" + 
                       DoubleToString(avg_sl, digits) + " " + 
                       currencySymbol + DoubleToString(total_risk, 2);
      DrawHLine("TM_Line_SL", avg_sl, colorSL, STYLE_DOT, sl_label);
      ArrayResize(active_lines, active_count + 1);
      active_lines[active_count++] = "TM_Line_SL";
   }
   
   // Draw BE line (entry price with volume)
   if(InpShowBELevel) {
      double be_price = avg_entry + InpSlippageMargin * point * (isBuy ? 1 : -1);
      string be_label = group.direction + " " + DoubleToString(group.total_volume, 2) + "@" + 
                       DoubleToString(avg_entry, digits);
      DrawHLine("TM_Line_BE", be_price, clrYellow, STYLE_DOT, be_label);
      ArrayResize(active_lines, active_count + 1);
      active_lines[active_count++] = "TM_Line_BE";
   }
   
   // Draw partial lines with detailed info
   if(InpShowPartialLevels && InpEnablePartials && avg_tp > 0) {
      // Analyze manual partials
      ManualPartialInfo manual_partials[];
      double auto_partial_volume = 0;
      AnalyzeManualPartials(group, manual_partials, auto_partial_volume);
      
      // Calculate feasible auto-partials
      int feasible_partials = CalculateFeasiblePartials(auto_partial_volume);
      double lot_step_local = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(lot_step_local <= 0) lot_step_local = 0.01;
      int total_units = (int)MathRound(auto_partial_volume / lot_step_local);
      if(feasible_partials + 1 > total_units)
         feasible_partials = MathMax(0, total_units - 1);
      
      if(feasible_partials > 0 || ArraySize(manual_partials) > 0) {
         int total_tp_count = 0;
         
         // Draw manual partial lines first
         for(int i = 0; i < ArraySize(manual_partials); i++) {
            total_tp_count++;
            string line_name = "TM_Line_TP" + IntegerToString(total_tp_count);
            double reward = 0;
            if(isBuy) reward = (manual_partials[i].tp_price - avg_entry) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * manual_partials[i].current_volume;
            else reward = (avg_entry - manual_partials[i].tp_price) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * manual_partials[i].current_volume;
            
            string label = "TP" + IntegerToString(total_tp_count) + " " + 
                          DoubleToString(manual_partials[i].current_volume, 2) + "@" + 
                          DoubleToString(manual_partials[i].tp_price, digits) + " " + 
                          currencySymbol + DoubleToString(reward, 2);
            DrawHLine(line_name, manual_partials[i].tp_price, clrCyan, STYLE_DOT, label);
            ArrayResize(active_lines, active_count + 1);
            active_lines[active_count++] = line_name;
         }
         
         // Draw auto-partial lines
         if(feasible_partials > 0 && auto_partial_volume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
            int total_steps = feasible_partials + 1;
            double step_plan[];
            BuildStepVolumePlan(auto_partial_volume, total_steps, step_plan);
            if(ArraySize(step_plan) != total_steps) total_steps = 0;
            
            double total_distance = MathAbs(avg_tp - avg_entry);
            double step_distance = (total_steps > 0) ? (total_distance / total_steps) : 0;
            int steps_completed = group.step_done;
            if(steps_completed < 0) steps_completed = 0;
            if(steps_completed > feasible_partials) steps_completed = feasible_partials;
            
            // Only draw remaining auto-partials (not yet executed)
            for(int step = steps_completed; step < feasible_partials && total_steps > 0; step++) {
               total_tp_count++;
               double distance = step_distance * (step + 1);
               double level_price = avg_entry + (isBuy ? distance : -distance);
               double step_volume = step_plan[step];
               
               double reward = 0;
               if(isBuy) reward = (level_price - avg_entry) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * step_volume;
               else reward = (avg_entry - level_price) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * step_volume;
               
               string line_name = "TM_Line_TP" + IntegerToString(total_tp_count);
               string label = "TP" + IntegerToString(total_tp_count) + " " + 
                             DoubleToString(step_volume, 2) + "@" + 
                             DoubleToString(level_price, digits) + " " + 
                             currencySymbol + DoubleToString(reward, 2);
               
               DrawHLine(line_name, level_price, clrGray, STYLE_DOT, label);
               ArrayResize(active_lines, active_count + 1);
               active_lines[active_count++] = line_name;
            }
            
            // Draw final TP line (same volume as other steps)
            total_tp_count++;
            double final_volume = (total_steps > 0) ? step_plan[total_steps - 1] : auto_partial_volume;
            double final_reward = 0;
            if(isBuy) final_reward = (avg_tp - avg_entry) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * final_volume;
            else final_reward = (avg_entry - avg_tp) / point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * final_volume;
            
            string line_name = "TM_Line_TP" + IntegerToString(total_tp_count);
            string label = "TP" + IntegerToString(total_tp_count) + " " + 
                          DoubleToString(final_volume, 2) + "@" + 
                          DoubleToString(avg_tp, digits) + " " + 
                          currencySymbol + DoubleToString(final_reward, 2);
            
            DrawHLine(line_name, avg_tp, clrLimeGreen, STYLE_DOT, label);
            ArrayResize(active_lines, active_count + 1);
            active_lines[active_count++] = line_name;
         }
      }
   }
   
   // Clean up lines that are no longer active
   for(int i = ObjectsTotal(0, 0, OBJ_HLINE) - 1; i >= 0; i--) {
      string name = ObjectName(0, i, 0, OBJ_HLINE);
      if(StringFind(name, "TM_Line_") == 0) {
         bool keep = false;
         for(int j = 0; j < active_count; j++) {
            if(name == active_lines[j]) {
               keep = true;
               break;
            }
         }
         if(!keep) ObjectDelete(0, name);
      }
   }
}

void DeleteAllLines() {
   for(int i = ObjectsTotal(0, 0, OBJ_HLINE) - 1; i >= 0; i--) {
      string name = ObjectName(0, i, 0, OBJ_HLINE);
      if(StringFind(name, "TM_Line_") == 0)
         ObjectDelete(0, name);
   }
}

void DeleteAllVisuals() {
   ObjectDelete(0, "TM_Line1");
   ObjectDelete(0, "TM_Line2");
   ObjectDelete(0, "TM_Line3");
   ObjectDelete(0, "TM_Line4");
   ObjectDelete(0, "TM_Line1_Pos");
   ObjectDelete(0, "TM_Line1_PnL");
   ObjectDelete(0, "TM_Line1_SL");
   ObjectDelete(0, "TM_Line1_TP");
   DeleteAllLines();
}

// ===============================
// Event Handlers
// ===============================
int OnInit() {
   Print("=== SimpleTradeManager v15.00 Initialized ===");
   Print("Partials: ", InpEnablePartials ? "Enabled" : "Disabled", 
         " | BE: ", InpEnableBE ? "Enabled" : "Disabled",
         " | Trailing: ", InpEnableTrailing ? "Enabled" : "Disabled");
   
   if(InpStopLoss < 0 || InpTakeProfit < 0) {
      Print("ERROR: SL/TP cannot be negative!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpEnablePartials && InpMaxPartials < 1) {
      Print("ERROR: Max Partials must be at least 1!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpEnableDashboard)
      InitializeDashboard();
   
   EventSetMillisecondTimer(100);
   
   // Process existing positions
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         SetPositionSLTP(ticket);
         InitPositionState(ticket);
      }
   }
   
   // Process existing orders
   for(int i = 0; i < OrdersTotal(); i++) {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         SetOrderSLTP(ticket);
   }
   
   Print("=== Initialization Complete ===");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   Print("=== EA Removed - Reason: ", reason, " ===");
   EventKillTimer();
   if(InpEnableDashboard)
      DeleteAllVisuals();
}

void OnTick() {
   if(InpEnablePartials)
      ManagePartials();
}

void OnTimer() {
   if(InpEnableBE)
      ManageBreakEven();
   
   if(InpEnableTrailing)
      ManageTrailingStop();
   
   if(InpEnableDashboard) {
      UpdateDashboard();
      UpdateLines();
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_POSITION) {
      if(PositionSelectByTicket(trans.position)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            SetPositionSLTP(trans.position);
            InitPositionState(trans.position);
         }
      }
   } else if(trans.type == TRADE_TRANSACTION_ORDER_ADD) {
      if(OrderSelect(trans.order)) {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol)
            SetOrderSLTP(trans.order);
      }
   }
}
//+------------------------------------------------------------------+
