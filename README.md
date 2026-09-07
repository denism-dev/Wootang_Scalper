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

## v8.5 — review fixes on v8.4

A further review pass found the closed-bar toggle itself had a bookkeeping
gap, plus three live-trading robustness issues:

- **Closed-bar bookkeeping now decoupled from every other gate.** The
  previous "already evaluated this bar" check only got updated from inside
  the signal branches, so an early return (open position, cooldown,
  session, spread, ATR) left it stale. Concretely: a position open at the
  start of a bar, closing mid-bar, could let the EA evaluate that bar's
  closed-bar signal several minutes late, on stale data. A separate
  tracker (`g_LastClosedEvalBars`) now marks the bar's one evaluation
  opportunity as used the instant a new bar is detected — before
  `HasOpenPosition()` or any filter runs — so the decision point is fixed
  regardless of what happens afterward.
- **Pending orders now explicitly request `ORDER_FILLING_RETURN`.**
  `SetTypeFillingBySymbol()` can select FOK or IOC depending on what the
  symbol advertises, but RETURN is the conventional filling mode for
  stop/limit-type pending orders on many brokers. `BuyStop`/`SellStop` now
  set RETURN explicitly right before sending; `CloseAll()` explicitly
  restores `SetTypeFillingBySymbol()` before closing positions, since the
  same `CTrade` object is shared between both kinds of request.
- **Trade results are now actually verified.** `BuyStop()`/`SellStop()`
  returning `true` only means the request passed local validation, not
  that the broker accepted it. Both calls now log
  `ResultRetcode()`/`ResultOrder()` via a new `LogOrderResult()` helper, so
  a rejection (bad filling mode, invalid stops, insufficient margin, market
  restrictions) shows up as a clear log line instead of looking like "no
  signal fired."
- **Drawdown halt/peak are now scoped to the account, not just shared.**
  MT5 global variables are shared by every program running in a terminal
  instance regardless of which account is logged in, so the v8.3 unscoped
  names could let a halt or equity peak from one account leak into a
  different account later logged into the same terminal. They're now keyed
  by `ACCOUNT_LOGIN`.

## v8.6 — general reliability pass

A self-review focused on error handling and edge cases found one real,
previously-undetected bug, plus a small robustness improvement:

- **Fixed a fail-OPEN gap in the SELL condition.** `GetBand()` returns `0`
  on a failed or insufficient-history read. The original SELL "no signal"
  gate was `if((20pts + upperBand) >= Bid) return;` — if `upperBand` failed
  to `0`, that check becomes `20pts >= Bid`, which is **false** for any real
  price, so the gate would silently fail to trigger and the EA would place
  a SellStop purely because the indicator read failed, not because of an
  actual signal. This was present in the original v7 comparison itself, not
  something introduced by any Wootang v8 revision — the BUY side happened
  to fail closed by coincidence of its inequality direction, so it never
  surfaced. Both bands (and, in closed-bar mode, the reference Close price,
  plus Ask/Bid in all modes) are now validated as nonzero before either
  signal is evaluated; a failed read now safely skips that tick instead of
  risking a spurious entry.
- **Removed a format-specifier dependency.** The account-scoped global
  variable names built with `StringFormat("...%I64d", login)` now use
  `IntegerToString(login)` instead, removing any reliance on that
  specifier's exact behavior.

### Other things worth knowing (not bugs, but worth understanding)

- **The drawdown halt cannot be bypassed by toggling `MaxDrawdown_On`
  off.** Once tripped, every chart running this EA — even one with
  `MaxDrawdown_On=false` — will still see the shared halt flag and close
  its own positions. Only deleting the global variable clears it. This is
  intentional: a per-chart toggle should be able to opt out of *triggering*
  the halt, never opt out of *honoring* one another instance already
  triggered.
- **`ORDER_FILLING_RETURN` is a convention, not a guarantee.** Some
  brokers/symbols may still reject it for pending orders. If that happens,
  it will now show up clearly via the v8.5 result-verification logging
  rather than failing silently — that's the signal to try
  `SetTypeFillingBySymbol()` for that symbol instead.
- **`MaintainPendingOrders()` treats a transient ATR-read failure the same
  as "ATR out of range."** A resting pending order can get cancelled on a
  single bad tick of indicator data, not just on a genuine filter breach.
  This is the deliberate cost of failing closed rather than trading blind,
  but it's worth knowing the cancellation isn't always due to a real
  volatility-regime change.

None of this has been compiled or backtested — it's a structural read of
the code, not a substitute for running it through MetaEditor and the
Strategy Tester.

## v8.7 — trade-result confirmation, deal accounting, restart persistence

An external review of v8.6 surfaced 24 findings. Most held up; here's what
changed and why:

- **`OnTradeTransaction()` now calls `HistoryDealSelect()`** before reading
  any deal property. Without it, deal properties from a ticket handed to
  the EA by the transaction event (as opposed to one obtained by
  enumerating an already-selected range) aren't reliably readable — this
  could have silently corrupted daily P/L and the losing-streak counter.
- **Every trade-modifying call now verifies `ResultRetcode()`**, not just
  `BuyStop`/`SellStop`. `OrderDelete`, `PositionClose`, and
  `PositionModify` all route through a shared `ConfirmTradeResult()`
  helper, so a server-side rejection (e.g. the daily/drawdown breaker
  believing a position closed when the broker actually rejected it) is
  visible instead of assumed successful.
- **`GetBand()`/`VolatilityOk()` now explicitly reject `EMPTY_VALUE`**
  (`~1.8e308`, an indicator's "not calculated yet" sentinel). The v8.6 fix
  only checked for `0`, which doesn't catch this — an uncalculated
  Bollinger Band value could still have spuriously triggered a BUY.
  Same class of gap in the ATR filter, now also closed.
- **Daily P/L and the losing-streak counter are now computed per
  fully-closed position**, not per exit deal. `OnTradeTransaction` waits
  until `PositionSelectByTicket` confirms no volume remains, then sums
  every deal for that `DEAL_POSITION_ID` (via `HistorySelectByPosition`)
  — entry deal included. This captures entry-side commission a
  per-exit-deal read would miss, and treats a partially-filled close as
  one trade result instead of several.
- **Fixed a broken resume path.** Deleting only the halt global variable
  left the old (high) peak in place — since equity is virtually always
  still below that peak right after a halt, the very next tick could
  retrigger it immediately. Clearing the halt now automatically rebases
  the peak to current equity.
- **The drawdown kill-switch now closes everything immediately.**
  `CloseAllForMagicAccountWide()` closes every position and cancels every
  pending order for this Magic number across *all* symbols the instant the
  breach is detected, instead of waiting for every other chart to notice
  the shared halt flag on its own next tick.
- **Cooldown/streak state is now persisted** (keyed by symbol+magic, via
  global variables), so a restart mid-cooldown doesn't silently resume
  trading.
- **Balance/credit deals now shift the equity peak by the same amount.** A
  withdrawal no longer looks like a trading drawdown, and a deposit
  doesn't silently widen the drawdown cushion until equity organically
  grows into it.
- **Risk-based sizing now uses `OrderCalcProfit()`** instead of manual
  tick-value math, which is more accurate on instruments where contract
  specs make that math non-linear.
- **Entry/SL/TP/trailing prices now normalize to
  `SYMBOL_TRADE_TICK_SIZE`**, not just `_Digits` — some symbols have a
  tick size that's a multiple of the point size and would reject a price
  that merely looks correctly rounded.
- **Pending-order age is now measured in real bar indices** (`iBarShift`),
  not wall-clock seconds divided by the period — the old math overcounted
  "bars" across a weekend or other market closure.
- **Added `OnInit()` input validation** (returns
  `INIT_PARAMETERS_INCORRECT` on an invalid combination) and seeded
  `g_LastClosedEvalBars` to the current bar count instead of `0`, so
  attaching mid-candle in closed-bar mode doesn't evaluate a
  partially-elapsed bar.

### Reviewed and NOT changed — here's why

- **"The daily breaker isn't an explicit sticky latch."** In this specific
  control flow it already behaves as one: once triggered, no new trades
  can occur (entries are gated behind the same breaker check), so
  `g_DailyProfit` cannot move back under the threshold on its own, and it
  self-heals correctly across a restart via the history reseed in
  `GetDailyProfitFromHistory()`. Adding an explicit latch would be
  redundant state tracking the same thing this control flow already
  guarantees.

### Accepted, documented limitations (not fixed — disproportionate effort)

- **Shared equity-peak updates aren't perfectly atomic.** Two instances
  reading-then-writing the peak within the same instant could theoretically
  let a lower value clobber a higher one. MQL5 has no compare-and-swap for
  global variables; a real fix needs lock-like machinery for a failure mode
  that's rare, low-impact (understates the peak by a small amount for at
  most one tick), and self-corrects on the very next tick.
- **Two chart instances with the same symbol+Magic will interfere** with
  each other's pending orders and positions. This is a configuration
  mistake to avoid (use a unique Magic per instance), not something the
  code can safely detect and lock against without real heartbeat
  machinery.

### Open decisions — not changed, need your call

These are real points, but each one changes actual trading/risk semantics
rather than fixing a defect, so I'm not deciding them for you:

- **Points vs. pips.** All offsets (`StopLoss`, `TakeProfit`,
  `TrailingStop`, the 20/30/50-point signal offsets) are in raw points,
  which represent different real amounts on different symbol digit
  conventions. `OnInit` now logs the symbol's digits/point size so this is
  at least visible, but converting the entry logic itself to pip-equivalent
  would change v7's entry conditions, which every revision so far has
  deliberately preserved.
- **Daily limits are per symbol+Magic, not account-wide.** Running this on
  four charts means up to four independent $200 targets / $100 limits, not
  one shared account-wide pair. The drawdown kill-switch was made
  account-wide because that was requested explicitly; the daily breakers
  were never discussed the same way.
- **1% risk is per trade, not total account exposure.** Four simultaneous
  positions across four instances could put ~4% at risk, not 1%. A
  portfolio-level open-risk cap needs the same kind of shared-state
  coordination as the drawdown halt — worth building only if you actually
  run multiple instances at once.
