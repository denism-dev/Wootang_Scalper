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

## v8.2 risk-management layer

No EA can guarantee a win rate — a Bollinger-band breakout scalper wins
somewhere in the 35-55% range depending on the market, and that's normal.
What v8.2 adds is the risk control that determines whether an account
survives the losing streaks that are guaranteed to happen along the way:

- **Risk-based position sizing** (`UseRiskPercent`, `RiskPercent`): lot size
  is derived from % equity risked against the actual `StopLoss` distance,
  replacing the old margin-percentage guess that wasn't tied to real risk.
  `UsFixedLot` remains as a fallback.
- **Daily loss limit** (`DailyLoss_On`, `DailyLossLimit`): halts trading for
  the day once realised losses reach the limit, mirroring the existing
  daily profit target.
- **Account drawdown kill-switch** (`MaxDrawdown_On`, `MaxDrawdownPercent`):
  if equity falls the configured % below its peak, all trading halts
  immediately via a persistent global variable (`Wootang_Halt_<symbol>_<magic>`)
  and stays halted — including across an EA reload — until a human deletes
  that global variable or restarts the terminal. It will not silently
  resume on its own.
- **Losing-streak cooldown** (`Cooldown_On`, `MaxConsecutiveLosses`,
  `CooldownMinutes`): pauses new entries for a cooldown period after N
  losses in a row.
- **ATR volatility regime filter** (`UseATRFilter`, `MinATRPoints`,
  `MaxATRPoints`): skips entries when the market is too quiet (chop/whipsaw
  risk) or too violent (news-spike risk).
- **Session filter** (`UseSessionFilter`, `SessionStartHour`,
  `SessionEndHour`): restricts entries to a configured server-time window.

These are filters and sizing layered on top of the existing signal — the
entry conditions themselves are still untouched from v7.
