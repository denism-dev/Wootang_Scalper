//+------------------------------------------------------------------+
//| Wootang Scalper v8.1 — MT5                                       |
//| Copyright © 2026, wootang Technologies Inc                       |
//| https://www.mql5.com/en                                          |
//+------------------------------------------------------------------+
//  Fixes applied on top of the v8 draft:
//
//  - CRITICAL: the "one trade at a time" lock (formerly HasAnyOrder())
//    counted pending orders as blocking, which made the "clean stale
//    pendings before every new entry" logic unreachable: whenever a
//    pending order was already resting, the lock returned early and
//    DeleteAllPending() never ran, permanently stalling the EA on any
//    unfilled pending order. The lock now only checks OPEN POSITIONS
//    (HasOpenPosition()). A resting pending order no longer blocks the
//    EA — it is cleaned out the moment a fresh signal wants to place a
//    new one, which is exactly what DeleteAllPending() already did;
//    it just needed to be reachable.
//  - Removed Sar_period, Step, Acceleration — leftover inputs from an
//    earlier Parabolic-SAR version. The strategy runs entirely on
//    Bollinger Bands and never referenced them.
//  - Max_Spread is now enforced: entries are skipped while the spread
//    exceeds it.
//  - TrailingStop is now enforced on open positions via PositionModify.
//  - Added minimum-stop-distance validation (SYMBOL_TRADE_STOPS_LEVEL)
//    before sending pending orders and before trailing, and Print()
//    logging on every failed trade/order/modify call so failures are
//    no longer silent.
//  - Daily profit is now accumulated incrementally in
//    OnTradeTransaction instead of re-scanning the full day's deal
//    history on every tick.
//  - Trade entry conditions themselves are untouched.
//+------------------------------------------------------------------+

#property copyright "Copyright © 2026, wootang Technologies Inc"
#property link      "https://www.mql5.com/en"
#property version   "8.1"
#property description "Wootang Scalper MT5 — one trade at a time with TP/SL"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- core inputs
input int    Max_Spread    = 20;
input int    Magic         = 1111111;

input string trisk         = "== Risk Management ==";          // ————————————————
input int    StopLoss      = 500;                               // Stop Loss (points)
input int    TakeProfit    = 500;                               // Take Profit (points)
input int    TrailingStop  = 25;                                 // Trailing Stop (points, 0 = off)

input string tdaily        = "== Daily Profit Target ==";      // ————————————————
input bool   DailyTarget_On    = true;                         // Enable daily target
input double DailyProfitTarget = 200;                           // Stop trading when daily profit reaches ($)

input string tvolumen      = "== Volume Calculation ==";       // ————————————————
input bool   UsFixedLot    = true;                             // Use fixed lot size
input double uLotsValue    = 0.2;                             // Lot size / equity %

//--- trade objects
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

//--- indicator handle
int g_BandsHandle = INVALID_HANDLE;

//--- bar tracker — prevents multiple signals on the same bar
int g_LastBars = 0;

//--- daily profit tracking
double g_DailyProfit = 0;
int    g_LastDay     = -1;

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
//| Used by the daily profit target.                                 |
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

    double trail   = MathMax(TrailingStop * _Point, GetMinStopDistance());
    double ask     = GetAsk();
    double bid     = GetBid();

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
//| Lot size calculation                                              |
//+------------------------------------------------------------------+
double LotsCalculation()
{
    if(UsFixedLot) return uLotsValue;

    double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
    double marginFor1 = 0;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, GetAsk(), marginFor1) || marginFor1 <= 0)
        return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double mcPercent = (marginFor1 / freeMargin) * 100;
    double lots      = NormalizeDouble(uLotsValue / mcPercent, 2);
    double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
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

    g_LastBars    = 0;
    g_DailyProfit = 0;
    g_LastDay     = -1;

    Print("Wootang Scalper v8 started. TP=", TakeProfit, "pts  SL=", StopLoss,
          "pts  Trail=", TrailingStop, "pts");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_BandsHandle != INVALID_HANDLE)
        IndicatorRelease(g_BandsHandle);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — accumulate realised daily profit as deals   |
//| close, instead of re-scanning the whole day's history every tick.|
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
    g_DailyProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- daily profit target check
    if(DailyTarget_On)
    {
        CheckDayRollover();

        if(g_DailyProfit >= DailyProfitTarget)
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

    //--- spread filter — skip entries while the market is too wide
    if(GetSpreadPoints() > Max_Spread) return;

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

        double lots  = LotsCalculation();
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

        double lots  = LotsCalculation();
        if(!trade.SellStop(lots, price, _Symbol, sl, tp,
                            ORDER_TIME_GTC, 0, "Wootang Scalper v8"))
            Print("Wootang v8: SellStop failed err=", GetLastError());
    }
    g_LastBars = currentBars;
}
