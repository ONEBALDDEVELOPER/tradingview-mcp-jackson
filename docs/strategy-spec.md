# Indication-Level Entry Model: Build Spec

Source of truth: `rules.json` (v4.2-GOLD, the full rulebook) and `scripts/icc-indication-strategy.pine` (the mechanical version). This file is the portable summary for building a system in any language. Instrument tested: XAUUSD, 1H (4H also checked).

## 1. Definitions

| Term | Definition |
|---|---|
| Swing high / low | Pivot with `N` bars each side (working rule N=5). Confirmed N bars after it forms. |
| Break | A candle **close** beyond a level. A wick beyond it is a sweep, not a break. |
| Failed HH (sell) | Sequence H0, L1, H1, L2, H2 with H1>H0, L2>L1, H2<H1 (HH, then HL, then a lower high). |
| Indication level | L2, the HL before price failed to make a new HH. Its break is the CHoCH. |
| CHoCH | Close below the indication level after a failed HH. |
| Liquidity pool (sell) | H2, the lower high after the HL. |
| Protected high | H1, the HH before H2. A close above it kills the sell setup. |
| Sweep | Wick above H2 during the correction. |
| Buy | Exact mirror: failed LL, indication level = the LH, sweep the HL, protected low = the LL. |

## 2. State machine (sell side; buy = negate all prices)

1. **State 0, scan.** On each confirmed pivot high, check the last five alternating pivots. If the failed-HH pattern holds, go to State 1 with `lvl=L2`, `lhP=H2`, `protP=H1`. (Only when flat.)
2. **State 1, warning.** Report "failed HH" (a warning, not a CHoCH).
   - Close > `protP`: cancel, back to 0.
   - Close < `lvl`: CHoCH, go to State 2. Record `cBar`, set `maxHi = high`, `swept=false`.
3. **State 2, post-CHoCH.** Each bar:
   - Close > `protP` or bars since CHoCH > `expireBars` (80): cancel, back to 0.
   - If high > `lhP`: `swept = true`.
   - `maxHi = max(maxHi, high)`.
   - Optional BOS flag: close below the first post-CHoCH swing low. **Supporting evidence only, not a gate.**
   - Entry allowed when `swept` and close > `lvl` (price is above the level and will come back down to it).
   - `stop = maxHi + 0.1*ATR(14)` (just beyond the last correction high).
   - `R = stop - lvl`.
   - Place a **sell stop at `lvl`**. Size = `equity * 1% / R`.
   - Take profit = `lvl - rr*R` (rr = 7 in the working config; the rule is minimum 1:3, aiming for the next swing).
4. **In trade.** Cancel any pending entry. Time exit after 80 bars.

## 3. Parameters (working config)

| Param | Value | Notes |
|---|---|---|
| swing length | 5 | 3 and 10 were also tested; 10 was tuned to the 1H and lost on the 4H |
| require sweep | true | |
| require BOS | false | The BOS gate cut about 2/3 of trades without improving results |
| expire | 80 bars | |
| stop buffer | 0.1 x ATR(14) | |
| target | 7R | Rule floor is 1:3 |
| risk | 1% of equity | |
| max hold | 80 bars | |

## 4. Rules not yet encoded (your discretionary layer)

- H4 and H1 must align first; the 15m only refines entry and never creates a trade alone.
- Daily gives the overall bias.
- Rejection candle: one wick >= 50% of the candle range, judged on close. The min range of 12 pts for gold on the 1H is **unconfirmed**.
- Entry offset tolerance around the level (e.g. 4624.26 level, 4624.51 entry) is **unconfirmed**.
- Do not trade against the 1H/4H, or enter on the first break.
- Worked example: 24 Aug to 2 Sep 2026, XAUUSD 1H. Level 4624.26, short entry 4624.51, stop about 4679.4, target about 4302.7 (about 1:5.9).

## 5. Evidence status (be honest in the system)

- Backtests were thin and tuned on the same data. One readable 5-month result (1H, swing 3, 7R): 9 trades, 44% win rate, +7.8%.
- Over the full history, shorts lost. The cause is unconfirmed. Suspects are stale CHoCH, no confirmation candle, no POI/session filter, and no H4/H1 alignment filter.
- The mechanical version did not reproduce your August short.
- Required before trusting it: forward-test 30+ setups with these exact rules.

## 6. Suggested system architecture

1. **Data**: OHLCV for D, 4H, 1H, 15m.
2. **Structure engine**: pivots, the alternating swing list, the state machine above (one instance per direction, per timeframe).
3. **Event bus**: `FAILED_HH_LL_WARNING`, `CHOCH`, `SWEEP`, `BOS`, `SETUP_EXPIRED`, `ENTRY_ARMED`.
4. **Filters** (add one at a time and test each): H4/H1 alignment, daily bias, session, rejection candle, staleness.
5. **Execution**: pending stop order at the level, stop/target as above. Start in paper mode.
6. **Logging**: store every setup (taken or skipped) with a reason, to build the 30+ forward sample.

## 7. Files to carry over

- `rules.json`: machine-readable rulebook
- `scripts/icc-indication-strategy.pine`: reference implementation
- `scripts/failed-hh-ll-alert.pine`: warning and CHoCH alerts
- `scripts/swing-liquidity.pine`: swing and session liquidity
- `scripts/rejection-candles.pine`: rejection candle detector
