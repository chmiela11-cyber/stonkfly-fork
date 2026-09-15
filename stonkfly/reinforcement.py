from .config import D


def reinforcement(equity, anchor, deadband):
    """Incremental marked-to-bid portfolio P&L, including booked trading fees.
    The broker rejects external deposits/withdrawals before this is evaluated.
    This is an engineered stimulus, not a statement that a fly understands money.

    The deadband exceeds one order's maximum booked fee, so a fill alone cannot
    cross the threshold. A pulse therefore reports a price move, not the cost of
    having traded. Fees still enter the delta and still bias it downward.
    """
    delta = D(equity) - D(anchor)
    threshold = D(deadband)
    kind = (
        "reward"
        if delta >= threshold
        else "aversive"
        if delta <= -threshold
        else "none"
    )
    return kind, delta
