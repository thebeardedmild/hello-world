# Finance Fun: A Year of Paper-Trading Sub-Agents

A year-long, for-fun experiment: five simple trading strategies ("agents"),
each starting with $10,000 in play money, trade once a day against a fake
simulated market. No real money, no real markets, no real financial advice --
just watching strategies compete.

## Why a fake market?

This environment can't reach real market-data APIs (no general internet
access), so instead of live prices there's a small self-contained simulator
(`market.py`): five fictional tickers, each with its own drift/volatility
personality, seeded so the whole year is reproducible from scratch.

**No look-ahead bias, by construction:** every agent decides using only
price history from days *strictly before* today, and the market only ever
generates *one new day* at a time -- there is no pre-baked path sitting in a
file that a strategy (or a bug) could peek ahead into. See `engine.py` for
the exact order of operations.

## The tickers (fake, not real companies)

| Ticker | Personality |
|---|---|
| ALPH | High-growth, high-volatility |
| BETA | Slow and steady |
| GAMA | Cyclical / mean-reverting |
| DELT | Secular decline |
| OMEG | Steady bull |

## The agents

| Agent | Strategy |
|---|---|
| Buy & Hold | Buys an equal-weight basket on day 1 and never touches it again |
| Momentum | Every day, goes all-in on whichever ticker had the best trailing 10-day return |
| Mean Reversion | Buys whichever ticker is furthest below its 20-day moving average |
| Equal Weight Rebalancer | Rebalances back to equal weight across all tickers every day |
| Random Walker | Picks a random allocation every day -- the baseline chaos monkey |

Each trade costs a flat 0.05% fee, just so "trade constantly" isn't free.

## Files

- `market.py` -- the seeded fake market
- `agents.py` -- the five strategies
- `engine.py` -- daily driver: advance the market, let every agent trade, log everything, update the leaderboard below
- `data/` -- prices, per-agent state/holdings, per-agent trade ledgers, and daily portfolio-value history (all generated, gitignored contents included on purpose so the history is visible in the repo)

Run one more simulated day with:
```
python3 "finance fun/engine.py"
```

## Leaderboard

<!-- LEADERBOARD:START -->
_Last updated: Day 29 (2026-08-22)_

| Rank | Strategy | Portfolio Value | Return |
|---|---|---|---|
| 1 | Mean Reversion | $10,326.93 | +3.27% |
| 2 | Buy & Hold | $10,247.67 | +2.48% |
| 3 | Equal Weight Rebalancer | $10,210.44 | +2.10% |
| 4 | Random Walker | $10,002.15 | +0.02% |
| 5 | Momentum | $9,734.16 | -2.66% |

**Today's simulated closing prices:** ALPH $91.88, BETA $101.76, GAMA $99.85, DELT $122.89, OMEG $97.22
<!-- LEADERBOARD:END -->
