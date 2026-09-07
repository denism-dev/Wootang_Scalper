# Wootang Scalper v8 (MT5)

A Bollinger-Bands-based scalping Expert Advisor for MetaTrader 5.

## v8.1 fixes

The original v8 draft claimed to clean up stale pending orders before every
new entry attempt, but the master "one trade at a time" lock also counted
pending orders, so that cleanup code was unreachable whenever a pending
order already existed — the EA would stall indefinitely on any unfilled
pending order. This revision:

- **Fixes the deadlock**: the lock now blocks new entries only while a
  position is actually open. A resting pending order no longer blocks the
  EA — it's replaced the moment a fresh signal wants to place a new one.
- Removes unused inputs left over from an earlier Parabolic SAR version
  (`Sar_period`, `Step`, `Acceleration`) that the Bollinger-Bands strategy
  never referenced.
- Enforces `Max_Spread` (previously declared but unused).
- Enforces `TrailingStop` on open positions via `PositionModify`.
- Validates pending-order and SL/TP distances against the broker's minimum
  stop distance (`SYMBOL_TRADE_STOPS_LEVEL`) before sending orders.
- Logs failures on every trade/order/modify call instead of failing
  silently.
- Tracks daily realised profit incrementally via `OnTradeTransaction`
  instead of re-scanning the full day's deal history on every tick.

Trade entry conditions themselves are unchanged from v7.
