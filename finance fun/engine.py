"""Daily driver: advance the market one day, let every agent trade, log
everything, and refresh the leaderboard in README.md.

Order of operations matters for avoiding look-ahead bias:
  1. Read price history as it stood BEFORE today (days 1..day-1 only).
  2. Ask each agent to decide, using only that history.
  3. Advance the market to generate today's (day N) new closing prices.
  4. Execute each agent's decision AT today's price.
No agent's decision function ever sees the price it's about to trade at.
"""

import csv
import json
import os

import agents as agents_module
import market
from market import TICKERS

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
STATE_DIR = os.path.join(DATA_DIR, "state")
LEDGER_DIR = os.path.join(DATA_DIR, "ledger")
PORTFOLIO_HISTORY = os.path.join(DATA_DIR, "portfolio_history.csv")
PRICES_CSV = os.path.join(DATA_DIR, "prices.csv")
README = os.path.join(BASE_DIR, "README.md")

STARTING_CASH = 10_000.0
TRADE_FEE_BPS = 5  # 0.05% per trade, just for a touch of realism


def _slug(name):
    return name.lower().replace(" ", "_").replace("&", "and")


def _load_price_history():
    history = {t: [] for t in TICKERS}
    if not os.path.exists(PRICES_CSV):
        return history
    with open(PRICES_CSV) as f:
        for row in csv.DictReader(f):
            for t in TICKERS:
                history[t].append(float(row[t]))
    return history


def _load_state(agent):
    path = os.path.join(STATE_DIR, f"{_slug(agent.name)}.json")
    if not os.path.exists(path):
        return {"cash": STARTING_CASH, "holdings": {t: 0.0 for t in TICKERS}}
    with open(path) as f:
        return json.load(f)


def _save_state(agent, state):
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"{_slug(agent.name)}.json")
    with open(path, "w") as f:
        json.dump(state, f, indent=2)


def _log_trade(agent, day, day_date, ticker, action, shares, price):
    os.makedirs(LEDGER_DIR, exist_ok=True)
    path = os.path.join(LEDGER_DIR, f"{_slug(agent.name)}.csv")
    is_new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if is_new:
            w.writerow(["day", "date", "ticker", "action", "shares", "price"])
        w.writerow([day, day_date, ticker, action, f"{shares:.4f}", f"{price:.4f}"])


def _rebalance(agent, state, target_weights, prices, day, day_date):
    if target_weights is None:
        return
    total_value = state["cash"] + sum(state["holdings"][t] * prices[t] for t in TICKERS)
    for t in TICKERS:
        target_value = total_value * target_weights.get(t, 0.0)
        target_shares = target_value / prices[t]
        delta = target_shares - state["holdings"][t]
        trade_value = delta * prices[t]
        if abs(trade_value) < 1.0:
            continue
        fee = abs(trade_value) * TRADE_FEE_BPS / 10_000
        state["cash"] -= trade_value + fee
        state["holdings"][t] += delta
        _log_trade(agent, day, day_date, t, "buy" if delta > 0 else "sell", abs(delta), prices[t])


def _append_portfolio_history(day, day_date, results):
    is_new = not os.path.exists(PORTFOLIO_HISTORY)
    with open(PORTFOLIO_HISTORY, "a", newline="") as f:
        w = csv.writer(f)
        if is_new:
            w.writerow(["day", "date"] + [agent.name for agent, _ in results])
        w.writerow([day, day_date] + [f"{value:.2f}" for _, value in results])


def _update_readme(day, day_date, prices, results):
    ranked = sorted(results, key=lambda r: r[1], reverse=True)
    lines = [f"_Last updated: Day {day} ({day_date})_", ""]
    lines.append("| Rank | Strategy | Portfolio Value | Return |")
    lines.append("|---|---|---|---|")
    for i, (agent, value) in enumerate(ranked, start=1):
        ret = (value / STARTING_CASH - 1) * 100
        lines.append(f"| {i} | {agent.name} | ${value:,.2f} | {ret:+.2f}% |")
    lines.append("")
    lines.append("**Today's simulated closing prices:** " + ", ".join(f"{t} ${prices[t]:.2f}" for t in TICKERS))
    leaderboard = "\n".join(lines)

    with open(README) as f:
        content = f.read()
    start_marker = "<!-- LEADERBOARD:START -->"
    end_marker = "<!-- LEADERBOARD:END -->"
    start = content.index(start_marker) + len(start_marker)
    end = content.index(end_marker)
    content = content[:start] + "\n" + leaderboard + "\n" + content[end:]
    with open(README, "w") as f:
        f.write(content)


def run_one_day():
    history_before_today = _load_price_history()
    day, day_date, prices = market.advance_one_day()

    results = []
    for agent in agents_module.AGENTS:
        state = _load_state(agent)
        weights = agent.target_weights(history_before_today, day)
        _rebalance(agent, state, weights, prices, day, day_date)
        value = state["cash"] + sum(state["holdings"][t] * prices[t] for t in TICKERS)
        _save_state(agent, state)
        results.append((agent, value))

    _append_portfolio_history(day, day_date, results)
    _update_readme(day, day_date, prices, results)
    return day, day_date, results


if __name__ == "__main__":
    day, day_date, results = run_one_day()
    print(f"Day {day} ({day_date}) complete.")
    for agent, value in sorted(results, key=lambda r: r[1], reverse=True):
        print(f"  {agent.name:<24} ${value:,.2f}")
