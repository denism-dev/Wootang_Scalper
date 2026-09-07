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
  immediately via a persistent global variable and stays halted — including
  across an EA reload — until a human deletes that global variable. It will
  not silently resume on its own.
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

## v8.3 — review fixes on the v8.2 risk layer

A second review pass caught several gaps in v8.2 itself:

- **Pending orders now re-validated every tick.** Previously, a resting
  `ORDER_TIME_GTC` pending order could still execute even after the spread,
  ATR, session, or cooldown filters that would block a *new* entry turned
  against it, because the stale-order cleanup only ran from inside a
  fresh-signal branch. `MaintainPendingOrders()` now runs unconditionally
  every tick and cancels a resting order if it no longer satisfies those
  same filters, or has been unfilled for `PendingExpiryBars` bars.
- **Drawdown kill-switch is now genuinely account-wide.** The halt flag and
  the equity peak are shared, unkeyed global variables (`Wootang_AccountHalt`,
  `Wootang_AccountEquityPeak`) rather than per-symbol/magic ones — every
  chart running this EA sees the same halt and the same peak. Each instance
  still only ever closes its own trades directly; the shared flag is what
  propagates the halt to every other instance on its own next tick.
- **Equity peak now persists across restarts.** It previously reset to
  current equity on every `OnInit`, which quietly lowered the drawdown bar
  after any restart — defeating the point of a peak-based guard.
- **Corrected the halt message.** MT5 global variables survive a terminal
  restart; only deleting the global variable clears the halt. The old
  message incorrectly implied a restart would also clear it.
- **Risk-based sizing now skips instead of over-risking.** If the calculated
  size rounds below the broker's minimum lot, the trade is skipped rather
  than bumped up to the minimum — which could silently risk several times
  the requested `RiskPercent`.
- **Sizing is now one choice, not two conflicting booleans.** `SizingMode`
  (risk % or fixed lot) replaces the old `UseRiskPercent`/`UsFixedLot` pair.
- **Filling mode now auto-detected** via `SetTypeFillingBySymbol()` instead
  of a hardcoded `ORDER_FILLING_IOC`, which some brokers/symbols reject.
- **Corrected the win-rate claim.** Position sizing alone can't change win
  rate, but the ATR/session filters, the cooldown, and the trailing stop all
  change which trades are taken and how they exit — they can and are
  expected to shift the observed win rate and payoff distribution. That's
  something to measure while testing, not something to promise in advance.

**Deliberately not changed by default:** whether the buy/sell condition
should be evaluated only once per closed bar instead of intrabar.
`g_LastBars != currentBars` only enforces "at most once per bar," not "only
at bar open" — the signal can fire mid-candle. That materially affects
backtest results, so instead of silently picking one, v8.4 adds it as an
explicit toggle (see below).

## v8.4 — intrabar vs. closed-bar signal toggle

`EvaluateOnBarCloseOnly` (default `false`) lets you A/B test the timing
question above in the Strategy Tester instead of committing to one answer:

- **Off (default):** unchanged from v7 — the signal can fire at any point
  intrabar, checked on every tick against the live Ask/Bid and the
  still-forming bar's band values.
- **On:** the signal is evaluated once, on the first tick of a new bar,
  using the last CLOSED bar's Bollinger Band values and its Close price as
  the reference instead of the live/forming ones. Order placement still
  uses the current live Ask/Bid either way — only the decision of *whether*
  to place an order changes, not the price it's placed at.

Turning it on changes trade timing and frequency versus v7, so it's meant
to be compared against the default in testing, not assumed to be strictly
better.
