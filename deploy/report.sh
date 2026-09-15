#!/usr/bin/env bash
# Put a run's result next to the baselines that make it interpretable: not
# trading at all, holding the capital, and holding the same average size the
# run actually carried. Read-only.
#
#   bash deploy/report.sh                    # the active run
#   bash deploy/report.sh tuned tuned-d2ae9fe  # compare run directories
set -euo pipefail

PREFIX="${PREFIX:-/opt/stonkfly}"
UNIT="${UNIT:-stonkfly-paper}"
RUNS=("$@")

if [ ${#RUNS[@]} -eq 0 ]; then
  active="$(systemctl show -p Environment --value "$UNIT" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^STONKFLY_RUN=//p')"
  RUNS=("${active:-paper}")
fi

PY="$PREFIX/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

paths=()
for r in "${RUNS[@]}"; do
  case "$r" in
    /*) paths+=("$r") ;;
    *) paths+=("$PREFIX/runs/$r") ;;
  esac
done

"$PY" - "${paths[@]}" <<'PYCODE'
import json, signal, sys
from decimal import Decimal
from pathlib import Path

signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def duration(seconds):
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h {s % 3600 // 60}m"
    return f"{s // 86400}d {s % 86400 // 3600}h"


def report(out):
    print(f"run           {out}")
    path = out / "events.jsonl"
    if not path.exists():
        print("              no observations recorded\n")
        return
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    if len(rows) < 2:
        print(f"              {len(rows)} observation, too few to measure\n")
        return

    fills = [r for r in rows if r["execution"]["status"] == "FILLED"]
    fees = sum(Decimal(r["execution"]["fee"]) for r in fills)
    # Equity is recorded before that observation's own trade.
    start, end = Decimal(rows[0]["equity_usdc"]), Decimal(rows[-1]["equity_usdc"])
    result = end - start
    market = result + fees
    bid0, bid1 = Decimal(rows[0]["quote"]["bid"]), Decimal(rows[-1]["quote"]["bid"])
    ask0 = Decimal(rows[0]["quote"]["ask"])
    span = rows[-1]["wall_time"] - rows[0]["wall_time"]

    # Rebuild the position from the fills, then average the size actually
    # carried through each interval between observations.
    position, carried = Decimal(0), []
    filled = {r["tick"]: r for r in fills}
    for r in rows[:-1]:
        f = filled.get(r["tick"])
        if f:
            base = Decimal(f["execution"]["base"])
            position += base if r["neural"]["side"] == "BUY" else -base
        carried.append(position * Decimal(r["quote"]["bid"]))
    exposure = sum(carried) / len(carried) if carried else Decimal(0)

    rate = (Decimal(fills[0]["execution"]["fee"]) / Decimal(fills[0]["execution"]["quote"])
            if fills else Decimal("0.006"))
    hold_value = start / (1 + rate)
    hold_end = hold_value / ask0 * bid1
    hold = hold_end - start
    passive = exposure * (bid1 / bid0 - 1)

    print(f"window        {len(rows)} observations over {duration(span)}, "
          f"{rows[0]['product']}")
    print(f"price         {bid0:.2f} -> {bid1:.2f}  ({(bid1 / bid0 - 1) * 100:+.2f}%)")
    print(f"\nresult        equity {start:.4f} -> {end:.4f}   "
          f"{result:+.4f} USDC ({result / start * 100:+.2f}%)")
    print(f"  fees        {-fees:+.4f}")
    print(f"  market      {market:+.4f}")
    print("\nbaselines over the same window")
    print(f"  no trading           {Decimal(0):+.4f}   cash only")
    print(f"  buy and hold         {hold:+.4f}   all {start:.0f} USDC in at the first ask")
    print(f"  passive at same size {passive:+.4f}   {exposure:.2f} USDC held throughout")
    print(f"\ntiming                {market - passive:+.4f}   "
          f"what the entries added over holding that same size")
    buys = sum(1 for r in fills if r["neural"]["side"] == "BUY")
    holds = sum(1 for r in rows if r["neural"]["side"] == "HOLD")
    vetoes = sum(1 for r in rows if r["execution"]["status"] == "VETO")
    print(f"\ntrading       {len(fills)} fill{'' if len(fills) == 1 else 's'} "
          f"({buys} buy, {len(fills) - buys} sell), "
          f"{vetoes} vetoed, hold rate {100 * holds / len(rows):.0f}%")
    if fills:
        print(f"              fee budget at the 24/day cap: "
              f"{-24 * fees / len(fills):.4f} USDC per day")
    if len(rows) < 200 or span < 6 * 3600:
        print(f"\nCAUTION       {len(rows)} observations over {duration(span)} cannot "
              f"measure a strategy.\n              At this sample the result is fees "
              f"plus noise. Let one run\n              go for a day or more before "
              f"reading anything into it.")
    print()


for arg in sys.argv[1:]:
    out = Path(arg)
    if not out.is_dir():
        print(f"run           {out}\n              no such directory\n")
        continue
    report(out)
PYCODE
