import hashlib
import json
import math
from dataclasses import asdict, dataclass
from decimal import ROUND_DOWN, ROUND_UP, Decimal


def D(value):
    if isinstance(value, bool):
        raise ValueError("Boolean is not money")
    x = Decimal(str(value))
    if not x.is_finite():
        raise ValueError("Nonfinite quantity")
    return x


def down(value, step):
    return (D(value) / D(step)).to_integral_value(rounding=ROUND_DOWN) * D(step)


def up(value, step):
    return (D(value) / D(step)).to_integral_value(rounding=ROUND_UP) * D(step)


@dataclass(frozen=True)
class Settings:
    products: tuple[str, ...] = ("BTC-USDC",)
    capital: str = "100"
    order_limit: str = "10"
    loss_stop: str = "20"
    fee_reserve: str = "0.02"
    slippage: str = "0.005"
    spread_limit: str = "0.005"
    daily_orders: int = 24
    # Observation cadence and the minimum spacing between order attempts are
    # separate: an attempt happens after a variable neural integration, so a
    # loop period equal to the cooldown vetoes a proposal whenever the current
    # integration finishes sooner than the previous one.
    interval_seconds: float = 65
    cooldown_seconds: float = 60
    interval_margin_seconds: float = 5
    max_quote_age: float = 15
    neural_ms: float = 500
    neural_bin_ms: float = 10
    pulse_ms: float = 200
    pulse_current: float = 20
    # Must exceed the fee one paper order books, so that executing a trade
    # cannot by itself cross the threshold and stimulate an aversive pulse.
    # This default sits above that floor but below the live preview ceiling,
    # so a live run has to raise it; see live_fee_safe.
    reward_deadband: str = "0.10"
    decoder_threshold_hz: float = 2
    paper_fee: str = "0.006"
    learning: bool = True

    def __post_init__(self):
        if (
            not self.products
            or len(set(self.products)) != len(self.products)
            or not set(self.products) <= set(("BTC-USDC", "ETH-USDC", "SOL-USDC"))
        ):
            raise ValueError("Only allowlisted USDC spot pairs")
        if not 0 < D(self.capital) <= 100 or not 0 < D(self.order_limit) <= min(
            D(self.capital), D(10)
        ):
            raise ValueError("Maximum capital $100; maximum order $10")
        if not 0 < D(self.loss_stop) <= D(self.capital):
            raise ValueError("Invalid loss stop")
        if (
            not D(0) < D(self.fee_reserve) <= D(".05")
            or not 0 <= D(self.slippage) <= D(".01")
            or not 0 < D(self.spread_limit) <= D(".01")
        ):
            raise ValueError("Invalid fee/spread/slippage bounds")
        if not 0 <= D(self.paper_fee) <= D(self.fee_reserve):
            raise ValueError("Invalid paper fee")
        if (
            type(self.daily_orders) is not int
            or not 1 <= self.daily_orders <= 100
            or not math.isfinite(self.cooldown_seconds)
            or self.cooldown_seconds < 60
        ):
            raise ValueError("Rate limit: >=60 s between orders, <=100 orders/day")
        if (
            not math.isfinite(self.interval_margin_seconds)
            or self.interval_margin_seconds < 0
            or not math.isfinite(self.interval_seconds)
            or self.interval_seconds
            < self.cooldown_seconds + self.interval_margin_seconds
        ):
            raise ValueError(
                "Observation interval must clear the cooldown by the configured margin"
            )
        # One order's fee is a deterministic cost, not evidence about direction.
        # The floor is the fee a paper order actually books; a live run should
        # also clear order_limit * fee_reserve, the preview ceiling it may pay.
        if D(self.reward_deadband) <= D(self.order_limit) * D(self.paper_fee):
            raise ValueError(
                "Reinforcement deadband must exceed the fee one order books"
            )
        for x in [
            self.max_quote_age,
            self.neural_ms,
            self.neural_bin_ms,
            self.pulse_ms,
            self.pulse_current,
            self.decoder_threshold_hz,
        ]:
            if not math.isfinite(x) or x <= 0:
                raise ValueError("Positive finite parameter required")
        if self.neural_bin_ms > 10 or self.pulse_ms > self.neural_ms:
            raise ValueError(
                "Use <=10 ms neural bins; pulse must fit a decision window"
            )
        if any(
            abs(x * 10 - round(x * 10)) > 1e-7
            for x in [self.neural_ms, self.neural_bin_ms, self.pulse_ms]
        ):
            raise ValueError("Neural intervals must be multiples of 0.1 ms")

    def live_fee_safe(self):
        """A live fee can reach the preview ceiling, unlike the fixed paper fee.
        Below that, one order's fee can schedule a pulse on its own again.
        """
        return D(self.reward_deadband) > D(self.order_limit) * D(self.fee_reserve)

    def signature(self):
        return hashlib.sha256(
            json.dumps(asdict(self), sort_keys=True).encode()
        ).hexdigest()
