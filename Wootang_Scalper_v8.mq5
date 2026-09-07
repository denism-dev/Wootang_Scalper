//+------------------------------------------------------------------+
//| Wootang Scalper v8.4 — MT5                                       |
//| Copyright © 2026, wootang Technologies Inc                       |
//| https://www.mql5.com/en                                          |
//+------------------------------------------------------------------+
//  v8.3 fixes a review pass on the v8.2 risk layer:
//
//  - Pending orders are now re-validated EVERY tick against spread,
//    ATR, session and cooldown, and expire after PendingExpiryBars
//    bars unfilled — regardless of whether a fresh signal has fired.
//    Previously a resting GTC order could still execute even after
//    the filters that would have blocked a *new* entry turned
//    against it (e.g. spread widened, ATR went out of range, session
//    ended, cooldown started) because the cleanup code only ran from
//    inside a fresh-signal branch.
//  - The drawdown kill-switch is now genuinely account-wide: the halt
//    flag and the equity peak are shared global variables (not keyed
//    by symbol/magic), so every chart running this EA sees the same
//    halt and the same peak, while each instance only ever closes its
//    own (symbol+magic) trades directly.
//  - The equity peak is now persisted across EA/terminal restarts —
//    previously it reset to current equity on every OnInit, which
//    quietly lowered the drawdown bar after any restart.
//  - Corrected the halt message: MT5 global variables survive a
//    terminal restart, so restarting does NOT clear the halt. Only
//    deleting the global variable does.
//  - Risk-based sizing now SKIPS the trade when the calculated size
//    rounds below the broker's minimum lot, instead of forcing it up
//    to the minimum (which was silently risking more than requested).
//  - Replaced the two independent UseRiskPercent/UsFixedLot booleans
//    with a single SizingMode choice so they can't disagree.
//  - Switched to SetTypeFillingBySymbol() instead of a hardcoded IOC,
//    since some brokers/symbols reject IOC.
//  - Corrected the header claim about win rate: position sizing alone
//    can't change it, but the ATR/session filters, the cooldown, and
//    the trailing stop all change which trades are taken and how they
//    exit — they can and are expected to shift the observed win rate
//    and payoff distribution. That's something to measure while
//    testing, not something to promise in advance.
//
//  v8.4 adds EvaluateOnBarCloseOnly (default OFF) as an explicit A/B
//  toggle for the intrabar-vs-closed-bar question raised in review:
//  originally, `g_LastBars != currentBars` only enforced "at most once
//  per bar", not "only at bar open" — the signal could fire at any
//  point intrabar. With the toggle OFF (default), that intrabar
//  behaviour is preserved exactly, keeping entry conditions unchanged
//  from v7. With it ON, the signal is evaluated once per bar using the
//  last CLOSED bar's band and close price instead of the live/forming
//  ones; order placement still uses live Ask/Bid either way. This
//  materially changes trade timing/frequency versus v7 and is meant to
//  be A/B tested in the Strategy Tester, not left on by default.
//+------------------------------------------------------------------+

#property copyright "Copyright © 2026, wootang Technologies Inc"
#property link      "https://www.mql5.com/en"
#property version   "8.4"
#property description "Wootang Scalper MT5 — one trade at a time with TP/SL and a risk-management layer"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

enum ENUM_SIZING_MODE
{
    SIZING_RISK_PERCENT, // Risk % of equity per trade (recommended)
    SIZING_FIXED_LOT     // Fixed lot size
};

//--- core inputs
input int    Max_Spread    = 20;                                // Max spread (points) to allow entries
input int    Magic         = 1111111;

input string trisk         = "== Risk Management ==";          // ————————————————
input int    StopLoss      = 500;                               // Stop Loss (points)
input int    TakeProfit    = 500;                               // Take Profit (points)
input int    TrailingStop  = 25;                                 // Trailing Stop (points, 0 = off)
input int    PendingExpiryBars = 2;                              // Cancel unfilled pending orders after N bars (0=never by age)
input bool   EvaluateOnBarCloseOnly = false;                     // Evaluate the signal once on bar close instead of intrabar (see header notes)

input string tsizing       = "== Position Sizing ==";          // ————————————————
input ENUM_SIZING_MODE SizingMode = SIZING_RISK_PERCENT;        // How lot size is calculated
input double RiskPercent    = 1.0;                              // % equity risked per trade (SIZING_RISK_PERCENT)
input double uLotsValue     = 0.2;                              // Fixed lot size (SIZING_FIXED_LOT)

input string tdaily        = "== Daily Circuit Breakers ==";   // ————————————————
input bool   DailyTarget_On    = true;                          // Stop for the day at profit target
input double DailyProfitTarget = 200;                            // Daily profit target ($)
input bool   DailyLoss_On       = true;                         // Stop for the day at loss limit
input double DailyLossLimit     = 100;                          // Daily loss limit ($, positive number)

input string tdrawdown     = "== Account Drawdown Kill-Switch ==";  // ————————————————
input bool   MaxDrawdown_On     = true;                        // Enable hard drawdown halt (account-wide)
input double MaxDrawdownPercent = 10.0;                         // Halt if equity falls this % below its peak

input string tstreak       = "== Losing-Streak Cooldown ==";   // ————————————————
input bool   Cooldown_On          = true;                       // Enable cooldown after consecutive losses
input int    MaxConsecutiveLosses = 3;                           // Losses in a row that trigger cooldown
input int    CooldownMinutes      = 60;                          // Minutes to pause new entries after trigger

input string tvol          = "== Volatility Regime Filter (ATR) ==";  // ————————————————
input bool   UseATRFilter  = true;                              // Skip entries outside this ATR range
input int    ATRPeriod     = 14;
input double MinATRPoints  = 100;                                // Minimum ATR (points) required to trade, 0=off
input double MaxATRPoints  = 800;                                // Maximum ATR (points) allowed, 0=off

input string tsession      = "== Session Filter ==";           // ————————————————
input bool   UseSessionFilter = true;                           // Restrict trading to a server-time window
input int    SessionStartHour = 7;                               // Server time, 0-23
input int    SessionEndHour   = 20;                              // Server time, 0-23 (exclusive)

//--- trade objects
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

//--- indicator handles
int g_BandsHandle = INVALID_HANDLE;
int g_ATRHandle   = INVALID_HANDLE;

//--- bar tracker — prevents multiple signals on the same bar
int g_LastBars = 0;

//--- daily profit tracking
double g_DailyProfit = 0;
int    g_LastDay     = -1;

//--- drawdown kill-switch (account-wide: shared, unkeyed global variables)
double g_EquityPeak    = 0;
string g_HaltVarName    = "Wootang_AccountHalt";
string g_PeakVarName    = "Wootang_AccountEquityPeak";

//--- losing-streak cooldown
int      g_ConsecutiveLosses = 0;
datetime g_CooldownUntil     = 0;

//+------------------------------------------------------------------+
//| Price helpers                                                     |
//+------------------------------------------------------------------+
double GetAsk() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double GetBid() { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }

//+------------------------------------------------------------------+
//| Current spread in points                                          |
//+------------------------------------------------------------------+
double GetSpreadPoints()
{
    return (GetAsk() - GetBid()) / _Point;
}

//+------------------------------------------------------------------+
//| Broker's minimum distance (price units) between an order price   |
//| and the market / its own SL-TP.                                  |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    return stopsLevel * _Point;
}

//+------------------------------------------------------------------+
//| Read one Bollinger Band buffer value                              |
//| buffer 1 = upper band,  buffer 2 = lower band                    |
//| shift 0 = current (forming) bar, shift 1 = last closed bar       |
//+------------------------------------------------------------------+
double GetBand(int buffer, int shift = 0)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_BandsHandle, buffer, shift, 1, buf) != 1) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
//| Returns true if this EA has an OPEN POSITION — the master        |
//| one-trade lock. A resting pending order is NOT treated as an     |
//| active trade: it is replaced by DeleteAllPending() the moment a  |
//| fresh signal wants to place a new one (see OnTick), and is also  |
//| independently expired/invalidated by MaintainPendingOrders().    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(posInfo.SelectByIndex(i)
           && posInfo.Symbol() == _Symbol
           && posInfo.Magic()  == Magic)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Cancel ALL pending orders for this EA (buy and sell stops).      |
//| Called unconditionally before every new entry attempt so no      |
//| stale orders from previous bars can accumulate.                  |
//+------------------------------------------------------------------+
void DeleteAllPending()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(ordInfo.SelectByIndex(i)
           && ordInfo.Symbol() == _Symbol
           && ordInfo.Magic()  == Magic)
        {
            if(!trade.OrderDelete(ordInfo.Ticket()))
                Print("Wootang v8: OrderDelete failed for #", ordInfo.Ticket(),
                      " err=", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| Close all market positions and cancel all pending orders FOR THIS|
//| SYMBOL+MAGIC instance. Used by the daily circuit breakers and by  |
//| the drawdown kill-switch (each instance closes only its own      |
//| trades; the halt flag itself is what makes the kill-switch        |
//| account-wide — see UpdateDrawdownGuard/IsDrawdownHalted).         |
//+------------------------------------------------------------------+
void CloseAll()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(posInfo.SelectByIndex(i)
           && posInfo.Symbol() == _Symbol
           && posInfo.Magic()  == Magic)
        {
            if(!trade.PositionClose(posInfo.Ticket()))
                Print("Wootang v8: PositionClose failed for #", posInfo.Ticket(),
                      " err=", GetLastError());
        }
    }
    DeleteAllPending();
}

//+------------------------------------------------------------------+
//| Trail the stop loss of any open position for this EA once price  |
//| has moved TrailingStop points in profit. SL only ever moves in   |
//| the trade's favour.                                              |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
    if(TrailingStop <= 0) return;

    double trail = MathMax(TrailingStop * _Point, GetMinStopDistance());
    double ask   = GetAsk();
    double bid   = GetBid();

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Symbol() != _Symbol || posInfo.Magic() != Magic) continue;

        ulong  ticket = posInfo.Ticket();
        double curSL  = posInfo.StopLoss();
        double tp     = posInfo.TakeProfit();

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            double newSL = NormalizeDouble(bid - trail, _Digits);
            if(newSL > curSL && newSL > posInfo.PriceOpen())
            {
                if(!trade.PositionModify(ticket, newSL, tp))
                    Print("Wootang v8: trailing PositionModify failed for #", ticket,
                          " err=", GetLastError());
            }
        }
        else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
            double newSL = NormalizeDouble(ask + trail, _Digits);
            if((curSL == 0 || newSL < curSL) && newSL < posInfo.PriceOpen())
            {
                if(!trade.PositionModify(ticket, newSL, tp))
                    Print("Wootang v8: trailing PositionModify failed for #", ticket,
                          " err=", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Validate that a pending order's price and SL/TP respect the      |
//| broker's minimum stop distance before it is sent.                |
//+------------------------------------------------------------------+
bool PendingDistancesOk(double orderPrice, double sl, double tp, double currentPrice)
{
    double minDist = GetMinStopDistance();
    if(minDist <= 0) return true;

    if(MathAbs(orderPrice - currentPrice) < minDist) return false;
    if(sl > 0 && MathAbs(orderPrice - sl) < minDist)  return false;
    if(tp > 0 && MathAbs(orderPrice - tp) < minDist)  return false;
    return true;
}

//+------------------------------------------------------------------+
//| Today's realised profit from deal history — used only to seed/  |
//| reseed g_DailyProfit on EA start and day rollover. Per-tick       |
//| tracking is incremental via OnTradeTransaction.                  |
//+------------------------------------------------------------------+
double GetDailyProfitFromHistory()
{
    datetime todayMidnight = iTime(_Symbol, PERIOD_D1, 0);
    if(!HistorySelect(todayMidnight, TimeCurrent())) return 0;

    double total = 0;
    int deals = HistoryDealsTotal();
    for(int i = deals - 1; i >= 0; i--)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket == 0) continue;
        if(HistoryDealGetString(ticket,  DEAL_SYMBOL) != _Symbol)        continue;
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != (long)Magic)    continue;
        if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;

        total += HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_SWAP)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
    }
    return total;
}

//+------------------------------------------------------------------+
//| Reset/reseed g_DailyProfit whenever the calendar day changes.    |
//+------------------------------------------------------------------+
void CheckDayRollover()
{
    MqlDateTime tm;
    TimeToStruct(TimeCurrent(), tm);
    if(tm.day != g_LastDay)
    {
        g_LastDay     = tm.day;
        g_DailyProfit = GetDailyProfitFromHistory();
    }
}

//+------------------------------------------------------------------+
//| Drawdown kill-switch. g_HaltVarName / g_PeakVarName are shared,  |
//| UNKEYED global variables — every chart running this EA (whatever |
//| its own symbol or magic) reads the same halt flag and the same   |
//| equity peak, so the halt is genuinely account-wide. Each instance|
//| only ever closes its OWN (symbol+magic) trades via CloseAll() —  |
//| it never reaches into another instance's positions directly; the |
//| shared flag is what makes every other instance halt itself too,  |
//| on its own next tick.                                             |
//|                                                                    |
//| The halt does NOT clear on an EA reload or terminal restart — MT5|
//| global variables persist across both. Only deleting the global   |
//| variable (Terminal -> Global Variables) clears it.                |
//+------------------------------------------------------------------+
bool IsDrawdownHalted()
{
    return GlobalVariableCheck(g_HaltVarName) && GlobalVariableGet(g_HaltVarName) >= 1.0;
}

void TriggerDrawdownHalt(double equity, double peak)
{
    GlobalVariableSet(g_HaltVarName, 1.0);
    CloseAll();
    Print("Wootang v8: *** ACCOUNT DRAWDOWN KILL-SWITCH TRIGGERED *** equity=", equity,
          " is more than ", MaxDrawdownPercent, "% below peak=", peak,
          ". Trading is halted account-wide for every chart running this EA. ",
          "This does NOT clear on an EA reload or terminal restart. After review, ",
          "delete the global variable '", g_HaltVarName, "' (Terminal -> Global Variables) to resume.");
}

void UpdateDrawdownGuard()
{
    if(!MaxDrawdown_On) return;

    // Pick up a higher peak recorded by another instance/session before this tick.
    double storedPeak = GlobalVariableCheck(g_PeakVarName) ? GlobalVariableGet(g_PeakVarName) : 0;
    if(storedPeak > g_EquityPeak) g_EquityPeak = storedPeak;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_EquityPeak)
    {
        g_EquityPeak = equity;
        GlobalVariableSet(g_PeakVarName, g_EquityPeak);
    }

    if(g_EquityPeak <= 0) return;

    double ddPercent = (g_EquityPeak - equity) / g_EquityPeak * 100.0;
    if(ddPercent >= MaxDrawdownPercent && !IsDrawdownHalted())
        TriggerDrawdownHalt(equity, g_EquityPeak);
}

//+------------------------------------------------------------------+
//| Losing-streak cooldown — updated from OnTradeTransaction as each |
//| position for this EA closes.                                    |
//+------------------------------------------------------------------+
void RegisterClosedDealResult(double dealNetProfit)
{
    if(!Cooldown_On) return;

    if(dealNetProfit < 0)
    {
        g_ConsecutiveLosses++;
        if(g_ConsecutiveLosses >= MaxConsecutiveLosses)
        {
            g_CooldownUntil = TimeCurrent() + CooldownMinutes * 60;
            Print("Wootang v8: ", g_ConsecutiveLosses, " consecutive losses — new entries paused until ",
                  TimeToString(g_CooldownUntil, TIME_DATE | TIME_MINUTES));
            g_ConsecutiveLosses = 0;
        }
    }
    else if(dealNetProfit > 0)
    {
        g_ConsecutiveLosses = 0;
    }
}

bool InCooldown()
{
    return Cooldown_On && TimeCurrent() < g_CooldownUntil;
}

//+------------------------------------------------------------------+
//| Session filter — restrict entries to a server-time window.       |
//| Supports windows that wrap past midnight.                        |
//+------------------------------------------------------------------+
bool WithinSession()
{
    if(!UseSessionFilter) return true;
    if(SessionStartHour == SessionEndHour) return true; // 24h window

    MqlDateTime tm;
    TimeToStruct(TimeCurrent(), tm);

    if(SessionStartHour < SessionEndHour)
        return tm.hour >= SessionStartHour && tm.hour < SessionEndHour;

    return tm.hour >= SessionStartHour || tm.hour < SessionEndHour;
}

//+------------------------------------------------------------------+
//| ATR volatility regime filter. Fails CLOSED (skips the trade) if  |
//| the indicator buffer can't be read — better to sit out than to   |
//| trade blind on a data hiccup.                                    |
//+------------------------------------------------------------------+
bool VolatilityOk()
{
    if(!UseATRFilter) return true;

    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(g_ATRHandle, 0, 0, 1, atrBuf) != 1) return false;

    double atrPoints = atrBuf[0] / _Point;
    if(MinATRPoints > 0 && atrPoints < MinATRPoints) return false;
    if(MaxATRPoints > 0 && atrPoints > MaxATRPoints) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Cancel any resting pending order for this EA that either:        |
//|  (a) has been unfilled for PendingExpiryBars bars or more, or    |
//|  (b) no longer satisfies the same spread/ATR/session/cooldown    |
//|      conditions a brand new entry would be required to pass.     |
//| Runs every tick, independent of whether a fresh signal is firing |
//| — a resting GTC order must not be allowed to execute under       |
//| conditions the EA itself currently flags as unsafe.               |
//+------------------------------------------------------------------+
void MaintainPendingOrders()
{
    int periodSeconds = PeriodSeconds(PERIOD_CURRENT);
    bool conditionsNowInvalid = (GetSpreadPoints() > Max_Spread)
                                 || !VolatilityOk()
                                 || !WithinSession()
                                 || InCooldown();

    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(!ordInfo.SelectByIndex(i)) continue;
        if(ordInfo.Symbol() != _Symbol || ordInfo.Magic() != Magic) continue;

        bool ageExpired = false;
        if(PendingExpiryBars > 0 && periodSeconds > 0)
        {
            long ageSeconds = (long)(TimeCurrent() - ordInfo.TimeSetup());
            ageExpired = (ageSeconds / periodSeconds) >= PendingExpiryBars;
        }

        if(ageExpired || conditionsNowInvalid)
        {
            if(trade.OrderDelete(ordInfo.Ticket()))
                Print("Wootang v8: cancelled stale pending order #", ordInfo.Ticket(),
                      ageExpired ? " (age expired)" : " (filters no longer valid)");
            else
                Print("Wootang v8: OrderDelete failed for #", ordInfo.Ticket(),
                      " err=", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| Risk-based lot size: sized so a full StopLoss hit loses           |
//| RiskPercent% of current equity.                                    |
//+------------------------------------------------------------------+
double CalcRiskLots(double slPoints)
{
    if(slPoints <= 0) return 0;

    double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * (RiskPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickValue <= 0 || tickSize <= 0) return 0;

    double valuePerPoint = tickValue * (_Point / tickSize);
    double lossPerLot    = slPoints * valuePerPoint;
    if(lossPerLot <= 0) return 0;

    return riskMoney / lossPerLot;
}

//+------------------------------------------------------------------+
//| Returns 0 to mean "skip this trade" — callers must check for it. |
//| In SIZING_RISK_PERCENT mode, a size that rounds below the        |
//| broker's minimum lot is skipped rather than forced up to the     |
//| minimum, which would silently risk more than RiskPercent asks.   |
//| In SIZING_FIXED_LOT mode the user's chosen size is clamped to the |
//| broker's limits as normal.                                        |
//+------------------------------------------------------------------+
double LotsCalculation(double slPoints)
{
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(SizingMode == SIZING_RISK_PERCENT)
    {
        double lots = CalcRiskLots(slPoints);
        if(lots <= 0) return 0;
        if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

        if(lots < minLot)
        {
            Print("Wootang v8: risk-based size ", DoubleToString(lots, 2),
                  " is below broker minimum ", DoubleToString(minLot, 2),
                  " for ", DoubleToString(RiskPercent, 2), "% risk — skipping trade rather than over-risking");
            return 0;
        }
        if(lots > maxLot) lots = maxLot;
        return lots;
    }

    // SIZING_FIXED_LOT — user-specified size, clamp to broker limits
    double lots = uLotsValue;
    if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;
    if(lots < minLot) lots = minLot;
    if(lots > maxLot) lots = maxLot;
    return lots;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFillingBySymbol(_Symbol);

    g_BandsHandle = iBands(_Symbol, PERIOD_CURRENT, 20, 0, 2, PRICE_CLOSE);
    if(g_BandsHandle == INVALID_HANDLE)
    {
        Print("Wootang v8: Bollinger Bands handle creation failed");
        return INIT_FAILED;
    }

    g_ATRHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(g_ATRHandle == INVALID_HANDLE)
    {
        Print("Wootang v8: ATR handle creation failed");
        return INIT_FAILED;
    }

    g_LastBars          = 0;
    g_DailyProfit       = 0;
    g_LastDay           = -1;
    g_ConsecutiveLosses = 0;
    g_CooldownUntil     = 0;

    double storedPeak = GlobalVariableCheck(g_PeakVarName) ? GlobalVariableGet(g_PeakVarName) : 0;
    g_EquityPeak = MathMax(storedPeak, AccountInfoDouble(ACCOUNT_EQUITY));
    GlobalVariableSet(g_PeakVarName, g_EquityPeak);

    if(IsDrawdownHalted())
        Print("Wootang v8: loaded with an ACTIVE account-wide drawdown halt ('", g_HaltVarName,
              "'). No new trades will be placed until it is cleared.");

    Print("Wootang Scalper v8.4 started. TP=", TakeProfit, "pts  SL=", StopLoss,
          "pts  Trail=", TrailingStop, "pts  Sizing=",
          SizingMode == SIZING_RISK_PERCENT ? DoubleToString(RiskPercent, 2) + "% equity risk"
                                             : "fixed lot " + DoubleToString(uLotsValue, 2),
          "  SignalMode=", EvaluateOnBarCloseOnly ? "closed-bar" : "intrabar");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_BandsHandle != INVALID_HANDLE) IndicatorRelease(g_BandsHandle);
    if(g_ATRHandle   != INVALID_HANDLE) IndicatorRelease(g_ATRHandle);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — accumulate realised daily profit and track  |
//| the losing-streak cooldown as deals close, instead of             |
//| re-scanning the whole day's history every tick.                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest      &request,
                         const MqlTradeResult       &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)        return;
    if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != (long)Magic)    return;
    if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return;

    CheckDayRollover();
    double dealNetProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                          + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                          + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
    g_DailyProfit += dealNetProfit;

    RegisterClosedDealResult(dealNetProfit);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- drawdown kill-switch — checked first, overrides everything else.
    //--- Even if ANOTHER chart/instance tripped it, make sure this
    //--- instance's own trades are flat too.
    if(IsDrawdownHalted())
    {
        CloseAll();
        return;
    }
    UpdateDrawdownGuard();
    if(IsDrawdownHalted()) return; // just tripped this tick; CloseAll() already ran inside it

    //--- daily circuit breakers
    if(DailyTarget_On || DailyLoss_On)
    {
        CheckDayRollover();

        if(DailyTarget_On && g_DailyProfit >= DailyProfitTarget)
        {
            CloseAll();
            return; // halt for the rest of the day
        }
        if(DailyLoss_On && g_DailyProfit <= -MathAbs(DailyLossLimit))
        {
            CloseAll();
            return; // halt for the rest of the day
        }
    }

    //--- trail any open position regardless of whether a new entry follows
    ApplyTrailingStop();

    //--- one-trade lock: block new entries only while a position is
    //--- actually open. A resting pending order does NOT block this —
    //--- it gets replaced below the moment a fresh signal fires, and is
    //--- independently policed by MaintainPendingOrders() every tick.
    if(HasOpenPosition()) return;

    //--- unconditionally re-validate/expire any resting pending order,
    //--- regardless of whether a new entry is about to be evaluated
    MaintainPendingOrders();

    //--- losing-streak cooldown
    if(InCooldown()) return;

    //--- session filter
    if(!WithinSession()) return;

    //--- spread filter — skip entries while the market is too wide
    if(GetSpreadPoints() > Max_Spread) return;

    //--- volatility regime filter
    if(!VolatilityOk()) return;

    double Ask         = GetAsk();
    double Bid         = GetBid();
    int    currentBars = iBars(_Symbol, PERIOD_CURRENT);

    //--- EvaluateOnBarCloseOnly toggle: when on, only evaluate the signal
    //--- once, on the first tick of a new bar, using the LAST CLOSED bar's
    //--- band and close price as the reference instead of the live/forming
    //--- ones. Order placement still uses live Ask/Bid either way — this
    //--- only changes when/what decides whether to place the order. Off by
    //--- default, which preserves the original intrabar v7 behaviour
    //--- exactly (buffer shift 0, live Ask/Bid).
    if(EvaluateOnBarCloseOnly && g_LastBars == currentBars)
        return;

    double lowerBandRef = GetBand(2, EvaluateOnBarCloseOnly ? 1 : 0);
    double buyRefPrice  = EvaluateOnBarCloseOnly ? iClose(_Symbol, PERIOD_CURRENT, 1) : Ask;

    // ── BUY SIGNAL ────────────────────────────────────────────────
    // Condition: reference price is below (lower band - 20 points) —
    //   intrabar: live Ask vs the forming bar's band, checked every tick;
    //   bar-close mode: last closed bar's Close vs its own band, checked
    //   once per new bar.
    // Entry: BuyStop placed 30 points above the CURRENT live Ask
    // SL: StopLoss points below entry price
    // TP: TakeProfit points above entry price
    // ── ENTRY LOGIC UNCHANGED FROM v7 (when EvaluateOnBarCloseOnly=false) ─
    if(((lowerBandRef - (_Point * 20)) > buyRefPrice) && g_LastBars != currentBars)
    {
        // Clean any stale pending orders unconditionally before placing
        DeleteAllPending();

        double price = Ask + (_Point * 30);
        double sl    = StopLoss   > 0 ? price - (StopLoss   * _Point) : 0;
        double tp    = TakeProfit > 0 ? price + (TakeProfit * _Point) : 0;

        if(!PendingDistancesOk(price, sl, tp, Ask))
        {
            Print("Wootang v8: BuyStop skipped, price/SL/TP violate broker min stop distance");
            g_LastBars = currentBars;
            return;
        }

        double lots = LotsCalculation(StopLoss);
        if(lots <= 0)
        {
            g_LastBars = currentBars;
            return; // sizing said skip — see LotsCalculation()
        }

        if(!trade.BuyStop(lots, price, _Symbol, sl, tp,
                           ORDER_TIME_GTC, 0, "Wootang Scalper v8"))
            Print("Wootang v8: BuyStop failed err=", GetLastError());

        g_LastBars = currentBars;
        return;
    }

    // ── SELL SIGNAL ───────────────────────────────────────────────
    // Condition: reference price is above (upper band + 20 points) —
    //   same intrabar-vs-bar-close distinction as the buy signal above.
    // Entry: SellStop placed 30 points below the CURRENT live Bid
    // SL: StopLoss points above entry price
    // TP: TakeProfit points below entry price
    // ── ENTRY LOGIC UNCHANGED FROM v7 (when EvaluateOnBarCloseOnly=false) ─
    double upperBandRef = GetBand(1, EvaluateOnBarCloseOnly ? 1 : 0);
    double sellRefPrice = EvaluateOnBarCloseOnly ? iClose(_Symbol, PERIOD_CURRENT, 1) : Bid;
    if(((_Point * 20) + upperBandRef) >= sellRefPrice) return;
    if(g_LastBars == currentBars) return;

    // Clean any stale pending orders unconditionally before placing
    DeleteAllPending();

    if(Bid > (_Point * 50))
    {
        double price = Bid - (_Point * 30);
        double sl    = StopLoss   > 0 ? price + (StopLoss   * _Point) : 0;
        double tp    = TakeProfit > 0 ? price - (TakeProfit * _Point) : 0;

        if(!PendingDistancesOk(price, sl, tp, Bid))
        {
            Print("Wootang v8: SellStop skipped, price/SL/TP violate broker min stop distance");
            g_LastBars = currentBars;
            return;
        }

        double lots = LotsCalculation(StopLoss);
        if(lots <= 0)
        {
            g_LastBars = currentBars;
            return; // sizing said skip — see LotsCalculation()
        }

        if(!trade.SellStop(lots, price, _Symbol, sl, tp,
                            ORDER_TIME_GTC, 0, "Wootang Scalper v8"))
            Print("Wootang v8: SellStop failed err=", GetLastError());
    }
    g_LastBars = currentBars;
}
