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
_Last updated: Day 39 (2026-09-01)_

| Rank | Strategy | Portfolio Value | Return |
|---|---|---|---|
| 1 | Mean Reversion | $10,510.26 | +5.10% |
| 2 | Buy & Hold | $10,452.18 | +4.52% |
| 3 | Equal Weight Rebalancer | $10,401.52 | +4.02% |
| 4 | Random Walker | $10,012.58 | +0.13% |
| 5 | Momentum | $9,537.57 | -4.62% |

**Today's simulated closing prices:** ALPH $93.51, BETA $105.71, GAMA $98.15, DELT $129.54, OMEG $96.95
<!-- LEADERBOARD:END -->
