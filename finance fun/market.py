"""A fully self-contained, seeded fake market -- no external data, no network.

Each trading day's price move is generated from a seed derived only from
that day's index, and is only ever computed when that day is actually
advanced. Nothing here ever pre-computes or stores a future day's price, so
there is no way for a strategy to see (or for us to accidentally leak)
tomorrow's data while deciding today's trade.
"""

import json
import os
import random
from datetime import date

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
PRICES_CSV = os.path.join(DATA_DIR, "prices.csv")
MARKET_STATE_PATH = os.path.join(DATA_DIR, "market_state.json")

MASTER_SEED = 20260726

TICKERS = ["ALPH", "BETA", "GAMA", "DELT", "OMEG"]

PARAMS = {
    "ALPH": {"start": 100.0, "drift": 0.00060, "vol": 0.020},                 # high-growth, high volatility
    "BETA": {"start": 100.0, "drift": 0.00010, "vol": 0.006},                 # slow and steady
    "GAMA": {"start": 100.0, "drift": 0.00000, "vol": 0.014, "revert": 0.05}, # cyclical / mean-reverting
    "DELT": {"start": 100.0, "drift": -0.00035, "vol": 0.018},               # secular decline
    "OMEG": {"start": 100.0, "drift": 0.00030, "vol": 0.010},                 # steady bull
}


def _rng_for(day, ticker):
    idx = TICKERS.index(ticker)
    seed = MASTER_SEED * 1_000_003 + day * 97 + idx
    return random.Random(seed)


def _load_market_state():
    if not os.path.exists(MARKET_STATE_PATH):
        tickers = {t: {"price": PARAMS[t]["start"], "mean": PARAMS[t]["start"]} for t in TICKERS}
        return {"day": 0, "tickers": tickers}
    with open(MARKET_STATE_PATH) as f:
        return json.load(f)


def _save_market_state(state):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(MARKET_STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)


def _append_price_row(day, day_date, prices):
    os.makedirs(DATA_DIR, exist_ok=True)
    is_new = not os.path.exists(PRICES_CSV)
    with open(PRICES_CSV, "a") as f:
        if is_new:
            f.write("day,date," + ",".join(TICKERS) + "\n")
        f.write(f"{day},{day_date}," + ",".join(f"{prices[t]:.4f}" for t in TICKERS) + "\n")


def advance_one_day():
    """Advance the market by exactly one day and append the new closes."""
    state = _load_market_state()
    day = state["day"] + 1
    day_date = date.today().isoformat()

    new_prices = {}
    for t in TICKERS:
        p = state["tickers"][t]
        rng = _rng_for(day, t)
        shock = rng.gauss(0, PARAMS[t]["vol"])
        if "revert" in PARAMS[t]:
            new_mean = p["mean"] + rng.gauss(0, PARAMS[t]["vol"] * 0.1)
            new_price = p["price"] + PARAMS[t]["revert"] * (new_mean - p["price"]) + p["price"] * shock
            p["mean"] = new_mean
        else:
            new_price = p["price"] * (1 + PARAMS[t]["drift"] + shock)
        new_price = max(new_price, 1.0)
        p["price"] = new_price
        new_prices[t] = new_price

    state["day"] = day
    _save_market_state(state)
    _append_price_row(day, day_date, new_prices)
    return day, day_date, new_prices
