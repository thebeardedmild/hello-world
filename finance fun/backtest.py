"""Replay the whole simulation from day 1 against the same seeded prices.

`engine.py` advances the market one day at a time and can never go back. This
replays days 1..N in memory so a rule change can be judged over the entire
history instead of only from today forward.

Two things keep the replay honest:

  * Prices are regenerated from `market`'s own seeded generator and then
    checked against the recorded `data/prices.csv`. The run aborts if they
    differ, so a replay can never quietly score agents against a market that
    never happened. (Agents never influence prices, so the path is identical
    no matter what the strategies do.)
  * Each day, agents see only days strictly before it -- the same guarantee
    `engine.py` makes -- and trade at that day's close.

Nothing here writes to `data/`; the live ledgers and state files are left
exactly as the daily driver last wrote them.
"""

import csv
import os
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

import market
from market import PARAMS, TICKERS

DATA_DIR = os.path.join(BASE_DIR, "data")
PRICES_CSV = os.path.join(DATA_DIR, "prices.csv")
PORTFOLIO_HISTORY = os.path.join(DATA_DIR, "portfolio_history.csv")

STARTING_CASH = 10_000.0
TRADE_FEE_BPS = 5


def regenerate_prices(days):
    """Re-derive closes for days 1..`days` exactly as `market.advance_one_day` would."""
    state = {t: {"price": PARAMS[t]["start"], "mean": PARAMS[t]["start"]} for t in TICKERS}
    out = []
    for day in range(1, days + 1):
        row = {}
        for t in TICKERS:
            p = state[t]
            rng = market._rng_for(day, t)
            shock = rng.gauss(0, PARAMS[t]["vol"])
            if "revert" in PARAMS[t]:
                new_mean = p["mean"] + rng.gauss(0, PARAMS[t]["vol"] * 0.1)
                new_price = p["price"] + PARAMS[t]["revert"] * (new_mean - p["price"]) + p["price"] * shock
                p["mean"] = new_mean
            else:
                new_price = p["price"] * (1 + PARAMS[t]["drift"] + shock)
            new_price = max(new_price, 1.0)
            p["price"] = new_price
            row[t] = new_price
        out.append(row)
    return out


def read_recorded_prices():
    with open(PRICES_CSV) as f:
        rows = list(csv.DictReader(f))
    dates = [r["date"] for r in rows]
    prices = [{t: float(r[t]) for t in TICKERS} for r in rows]
    return dates, prices


def verify_prices(regenerated, recorded, tol=5e-5):
    """The recorded file holds 4dp, so compare at that precision."""
    if len(regenerated) != len(recorded):
        raise SystemExit(f"replay covers {len(regenerated)} days, prices.csv has {len(recorded)}")
    for i, (a, b) in enumerate(zip(regenerated, recorded), start=1):
        for t in TICKERS:
            if abs(a[t] - b[t]) > tol:
                raise SystemExit(f"day {i} {t}: replayed {a[t]:.4f} != recorded {b[t]:.4f}")


def replay(agent_list, prices):
    """Run `agent_list` over the whole price path. Returns per-agent results."""
    books = {
        a.name: {"cash": STARTING_CASH, "holdings": {t: 0.0 for t in TICKERS}, "trades": 0, "fees": 0.0}
        for a in agent_list
    }
    values = {a.name: [] for a in agent_list}
    history = {t: [] for t in TICKERS}

    for i, today in enumerate(prices):
        day = i + 1
        for agent in agent_list:
            book = books[agent.name]
            weights = agent.target_weights(history, day)  # only days < today
            if weights is not None:
                total = book["cash"] + sum(book["holdings"][t] * today[t] for t in TICKERS)
                for t in TICKERS:
                    target_shares = total * weights.get(t, 0.0) / today[t]
                    delta = target_shares - book["holdings"][t]
                    trade_value = delta * today[t]
                    if abs(trade_value) < 1.0:
                        continue
                    fee = abs(trade_value) * TRADE_FEE_BPS / 10_000
                    book["cash"] -= trade_value + fee
                    book["holdings"][t] += delta
                    book["trades"] += 1
                    book["fees"] += fee
            values[agent.name].append(book["cash"] + sum(book["holdings"][t] * today[t] for t in TICKERS))
        for t in TICKERS:
            history[t].append(today[t])

    return {a.name: {"values": values[a.name], **books[a.name]} for a in agent_list}


def read_recorded_values():
    with open(PORTFOLIO_HISTORY) as f:
        rows = list(csv.DictReader(f))
    names = [c for c in rows[0] if c not in ("day", "date")]
    return {n: [float(r[n]) for r in rows] for n in names}


def main():
    dates, recorded = read_recorded_prices()
    prices = regenerate_prices(len(recorded))
    verify_prices(prices, recorded)
    print(f"prices verified against data/prices.csv: {len(recorded)} days match\n")

    import agents as agents_module

    # Score against the full-precision path; prices.csv is rounded to 4dp and
    # replaying off it drifts a couple of cents over 56 days.
    results = replay(agents_module.AGENTS, prices)
    live = read_recorded_values()

    print(f"{'Strategy':<24} {'replayed':>11} {'recorded':>11} {'diff':>10} {'trades':>7}")
    for name in sorted(results, key=lambda n: -results[n]["values"][-1]):
        now = results[name]["values"][-1]
        was = live.get(name, [float('nan')])[-1]
        print(f"{name:<24} {now:>11,.2f} {was:>11,.2f} {now - was:>+10,.2f} {results[name]['trades']:>7}")
    print("\n'recorded' is what the live daily run actually produced under the rules in")
    print("force at the time; 'replayed' is the current agents.py over the same prices.")


if __name__ == "__main__":
    main()
