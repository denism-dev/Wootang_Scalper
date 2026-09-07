//+------------------------------------------------------------------+
//| Wootang Scalper v8.2 — MT5                                       |
//| Copyright © 2026, wootang Technologies Inc                       |
//| https://www.mql5.com/en                                          |
//+------------------------------------------------------------------+
//  v8.2 adds a professional-grade risk layer on top of the v8.1 bug
//  fixes. None of this changes — or can change — the strategy's win
//  rate; a Bollinger-band breakout scalper wins something like 35-55%
//  of the time depending on the market, and that is normal. What
//  actually separates a survivable EA from one that blows up an
//  account is risk control around that edge, which is what this
//  revision adds:
//
//  - Risk-based position sizing: lot size is derived from % equity
//    risked per trade against the actual StopLoss distance, instead
//    of a fixed lot or a margin-percentage guess disconnected from
//    real risk.
//  - Daily loss limit: mirrors the existing daily profit target, but
//    halts trading for the day once realised losses reach it.
//  - Account drawdown kill-switch: if equity falls MaxDrawdownPercent
//    below its peak, ALL trading halts immediately and stays halted
//    (via a persistent global variable) until a human clears it —
//    this will not silently resume on its own.
//  - Losing-streak cooldown: after MaxConsecutiveLosses losses in a
//    row, new entries pause for CooldownMinutes.
//  - ATR volatility regime filter: skips entries when the market is
//    too quiet (chop/whipsaw risk) or too violent (news-spike risk).
//  - Session filter: restricts entries to a configured server-time
//    window, avoiding illiquid hours and rollover spread widening.
//
//  Trade entry conditions themselves remain unchanged from v7 — these
//  are filters and sizing on top of the existing signal, not a new
//  signal.
//+------------------------------------------------------------------+

#property copyright "Copyright © 2026, wootang Technologies Inc"
#property link      "https://www.mql5.com/en"
#property version   "8.2"
#property description "Wootang Scalper MT5 — one trade at a time with TP/SL and a risk-management layer"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- core inputs
input int    Max_Spread    = 20;                                // Max spread (points) to allow entries
input int    Magic         = 1111111;

input string trisk         = "== Risk Management ==";          // ————————————————
input int    StopLoss      = 500;                               // Stop Loss (points)
input int    TakeProfit    = 500;                               // Take Profit (points)
input int    TrailingStop  = 25;                                 // Trailing Stop (points, 0 = off)

input string tsizing       = "== Position Sizing ==";          // ————————————————
input bool   UseRiskPercent = true;                             // Size by % equity risk (recommended)
input double RiskPercent    = 1.0;                              // % equity risked per trade
input bool   UsFixedLot     = false;                            // Fallback: use fixed lot size below
input double uLotsValue     = 0.2;                              // Fixed lot size (only if UsFixedLot=true)

input string tdaily        = "== Daily Circuit Breakers ==";   // ————————————————
input bool   DailyTarget_On    = true;                          // Stop for the day at profit target
input double DailyProfitTarget = 200;                            // Daily profit target ($)
input bool   DailyLoss_On       = true;                         // Stop for the day at loss limit
input double DailyLossLimit     = 100;                          // Daily loss limit ($, positive number)

input string tdrawdown     = "== Account Drawdown Kill-Switch ==";  // ————————————————
input bool   MaxDrawdown_On     = true;                        // Enable hard drawdown halt
input double MaxDrawdownPercent = 10.0;                         // Halt ALL trading if equity falls this % below peak

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

//--- drawdown kill-switch
double g_EquityPeak  = 0;
string g_HaltVarName  = "";

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
//+------------------------------------------------------------------+
double GetBand(int buffer)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_BandsHandle, buffer, 0, 1, buf) != 1) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
//| Returns true if this EA has an OPEN POSITION — the master        |
//| one-trade lock. A resting pending order is NOT treated as an     |
//| active trade: it is replaced by DeleteAllPending() the moment a  |
//| fresh signal wants to place a new one (see OnTick), so at most   |
//| one order is ever in play without the EA ever deadlocking on a   |
//| stale pending.                                                   |
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
//| Close all market positions and cancel all pending orders.        |
//| Used by the daily circuit breakers and the drawdown kill-switch. |
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
//| Drawdown kill-switch. Uses a global variable (keyed by symbol +  |
//| magic) so the halt SURVIVES an EA reload/reattach and only clears|
//| when a human deletes it or the terminal restarts — this must not |
//| silently resume on its own.                                      |
//+------------------------------------------------------------------+
bool IsDrawdownHalted()
{
    return GlobalVariableCheck(g_HaltVarName) && GlobalVariableGet(g_HaltVarName) >= 1.0;
}

void TriggerDrawdownHalt(double equity, double peak)
{
    GlobalVariableSet(g_HaltVarName, 1.0);
    CloseAll();
    Print("Wootang v8: *** DRAWDOWN KILL-SWITCH TRIGGERED *** equity=", equity,
          " is more than ", MaxDrawdownPercent, "% below peak=", peak,
          ". All trading halted. Delete global variable '", g_HaltVarName,
          "' (or restart the terminal) after review to resume.");
}

void UpdateDrawdownGuard()
{
    if(!MaxDrawdown_On) return;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_EquityPeak) g_EquityPeak = equity;
    if(g_EquityPeak <= 0)     return;

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
//| Risk-based lot size: sized so a full StopLoss hit loses           |
//| RiskPercent% of current equity. Falls back to a fixed lot when    |
//| UseRiskPercent is off.                                             |
//+------------------------------------------------------------------+
double CalcRiskLots(double slPoints)
{
    if(slPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * (RiskPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickValue <= 0 || tickSize <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double valuePerPoint = tickValue * (_Point / tickSize);
    double lossPerLot    = slPoints * valuePerPoint;
    if(lossPerLot <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    return riskMoney / lossPerLot;
}

double LotsCalculation(double slPoints)
{
    double lots = UseRiskPercent ? CalcRiskLots(slPoints) : uLotsValue;

    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(lotStep > 0)
        lots = MathFloor(lots / lotStep) * lotStep;
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
    trade.SetTypeFilling(ORDER_FILLING_IOC);

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
    g_DailyProfit        = 0;
    g_LastDay            = -1;
    g_ConsecutiveLosses  = 0;
    g_CooldownUntil      = 0;
    g_EquityPeak         = AccountInfoDouble(ACCOUNT_EQUITY);
    g_HaltVarName        = StringFormat("Wootang_Halt_%s_%d", _Symbol, Magic);

    if(IsDrawdownHalted())
        Print("Wootang v8: loaded with an ACTIVE drawdown halt ('", g_HaltVarName,
              "'). No new trades will be placed until it is cleared.");

    Print("Wootang Scalper v8.2 started. TP=", TakeProfit, "pts  SL=", StopLoss,
          "pts  Trail=", TrailingStop, "pts  Risk=",
          UseRiskPercent ? DoubleToString(RiskPercent, 2) + "%" : "fixed lot " + DoubleToString(uLotsValue, 2));
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
    //--- drawdown kill-switch — checked first, overrides everything else
    UpdateDrawdownGuard();
    if(IsDrawdownHalted()) return;

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
    //--- it gets replaced below the moment a fresh signal fires.
    if(HasOpenPosition()) return;

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

    // ── BUY SIGNAL ────────────────────────────────────────────────
    // Condition: Ask is below (lower band - 20 points) on a new bar
    // Entry: BuyStop placed 30 points above Ask
    // SL: StopLoss points below entry price
    // TP: TakeProfit points above entry price
    // ── ENTRY LOGIC UNCHANGED FROM v7 ────────────────────────────
    double lowerBand = GetBand(2);
    if(((lowerBand - (_Point * 20)) > Ask) && g_LastBars != currentBars)
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
        if(!trade.BuyStop(lots, price, _Symbol, sl, tp,
                           ORDER_TIME_GTC, 0, "Wootang Scalper v8"))
            Print("Wootang v8: BuyStop failed err=", GetLastError());

        g_LastBars = currentBars;
        return;
    }

    // ── SELL SIGNAL ───────────────────────────────────────────────
    // Condition: Bid is above (upper band + 20 points) on a new bar
    // Entry: SellStop placed 30 points below Bid
    // SL: StopLoss points above entry price
    // TP: TakeProfit points below entry price
    // ── ENTRY LOGIC UNCHANGED FROM v7 ────────────────────────────
    double upperBand = GetBand(1);
    if(((_Point * 20) + upperBand) >= Bid) return;
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
        if(!trade.SellStop(lots, price, _Symbol, sl, tp,
                            ORDER_TIME_GTC, 0, "Wootang Scalper v8"))
            Print("Wootang v8: SellStop failed err=", GetLastError());
    }
    g_LastBars = currentBars;
}
