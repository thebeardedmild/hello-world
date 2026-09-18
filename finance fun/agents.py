"""Trading strategies ('sub-agents') competing against each other.

Every strategy is handed price `history` containing only days strictly
before the one about to be traded -- never the day it's about to trade at.
That's what guarantees no look-ahead bias: a strategy literally cannot see
data that didn't exist yet when it made its call.
"""

import random

from market import TICKERS

RANDOM_WALKER_SEED = 20260726 * 7919


def _sma(values, window):
    if not values:
        return None
    window = min(window, len(values))
    return sum(values[-window:]) / window


def _trailing_return(values, window):
    if len(values) <= window:
        return 0.0
    return values[-1] / values[-1 - window] - 1


class Agent:
    name = "base"
    description = ""

    def target_weights(self, history, day):
        """Return {ticker: weight} (weights sum to <= 1; the rest sits in
        cash), or None to mean 'leave current holdings untouched'."""
        raise NotImplementedError


class BuyAndHold(Agent):
    name = "Buy & Hold"
    description = "Buys an equal-weight basket on day 1 and never touches it again."

    def target_weights(self, history, day):
        if day > 1:
            return None
        return {t: 1 / len(TICKERS) for t in TICKERS}


class Momentum(Agent):
    name = "Momentum"
    description = (
        "Goes all-in on the best trailing 10-day return -- but only when that leader is "
        "actually rising and is clearly ahead of the runner-up. Otherwise sits in the basket."
    )

    #: the leader must have risen at least this much over the trailing window
    MIN_TRAILING_RETURN = 0.0
    #: ...and beat the runner-up by at least this margin, so a near-tie doesn't
    #: count as a signal. Without these two guards the agent will happily stay
    #: parked in a ticker that has gone flat, simply because nothing overtook it.
    MIN_MARGIN = 0.01

    def target_weights(self, history, day):
        scores = {t: _trailing_return(history[t], 10) for t in TICKERS}
        ranked = sorted(scores.values(), reverse=True)
        best = max(scores, key=scores.get)
        margin = ranked[0] - ranked[1] if len(ranked) > 1 else ranked[0]
        if scores[best] <= self.MIN_TRAILING_RETURN or margin < self.MIN_MARGIN:
            return {t: 1 / len(TICKERS) for t in TICKERS}
        return {best: 1.0}


class MeanReversion(Agent):
    name = "Mean Reversion"
    description = (
        "Buys a ticker only once it trades a clear band below its 20-day moving average, "
        "and steps back out to the basket as soon as that gap closes -- the dip buyer."
    )

    #: how far below the 20-day average a ticker must fall before it is a "dip".
    #: A plain argmin has no such floor, so it locks onto whatever is in secular
    #: decline -- permanently below its own average -- and never rotates again.
    ENTRY_GAP = 0.02

    def target_weights(self, history, day):
        gaps = {}
        for t in TICKERS:
            sma = _sma(history[t], 20)
            last = history[t][-1] if history[t] else None
            gaps[t] = (sma - last) / sma if sma and last else 0.0
        best = max(gaps, key=gaps.get)
        # Below the band -- either never entered, or the dip has reverted. Either
        # way, hold the basket rather than the falling knife.
        if gaps[best] < self.ENTRY_GAP:
            return {t: 1 / len(TICKERS) for t in TICKERS}
        return {best: 1.0}


class EqualWeightRebalancer(Agent):
    name = "Equal Weight Rebalancer"
    description = "Rebalances back to an equal-weight basket across all tickers every single day."

    def target_weights(self, history, day):
        return {t: 1 / len(TICKERS) for t in TICKERS}


class RandomWalker(Agent):
    name = "Random Walker"
    description = "Picks a random allocation every day. The baseline chaos monkey."

    def target_weights(self, history, day):
        rng = random.Random(RANDOM_WALKER_SEED + day)
        raw = [rng.random() for _ in TICKERS]
        cash_slice = rng.random()
        total = sum(raw) + cash_slice
        return {t: w / total for t, w in zip(TICKERS, raw)}


AGENTS = [BuyAndHold(), Momentum(), MeanReversion(), EqualWeightRebalancer(), RandomWalker()]
