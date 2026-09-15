#!/usr/bin/env bash
# Show what a paper run is doing: the last observation in full, recent ticks,
# execution totals and memory state. Read-only; safe while the worker runs.
#
#   bash deploy/inspect.sh              # summary of the active run
#   bash deploy/inspect.sh --tick 7     # one observation, in full
#   bash deploy/inspect.sh --follow     # live log
#   bash deploy/inspect.sh --run paper  # an older run directory
set -euo pipefail

PREFIX="${PREFIX:-/opt/stonkfly}"
UNIT="${UNIT:-stonkfly-paper}"
RUN=""
TICK=""
FOLLOW=no

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --tick) TICK="$2"; shift 2 ;;
    --follow|-f) FOLLOW=yes; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$FOLLOW" = yes ]; then
  exec journalctl -u "$UNIT" -f -o cat
fi

if [ -z "$RUN" ]; then
  RUN="$(systemctl show -p Environment --value "$UNIT" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^STONKFLY_RUN=//p')"
  RUN="${RUN:-paper}"
fi
OUT="$PREFIX/runs/$RUN"
[ -d "$OUT" ] || { echo "No such run directory: $OUT" >&2; exit 1; }

PY="$PREFIX/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

"$PY" - "$OUT" "${TICK:-}" <<'PYCODE'
import json, signal, sqlite3, sys
from decimal import Decimal
from pathlib import Path

# Die quietly when piped into head, the way ordinary tools do.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

out, want = Path(sys.argv[1]), sys.argv[2]
events = [json.loads(line) for line in (out / "events.jsonl").read_text().splitlines()] \
    if (out / "events.jsonl").exists() else []

if want:
    match = [r for r in events if str(r["tick"]) == want]
    if not match:
        sys.exit(f"No observation with tick {want} in {out}")
    print(json.dumps(match[-1], indent=2))
    raise SystemExit

print(f"run           {out}")
db = out / "ledger.sqlite"
if db.exists():
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    meta = {k: json.loads(v) for k, v in con.execute("SELECT key,value FROM meta")}
    held = ", ".join(f"{v} {k}" for k, v in (meta.get("positions") or {}).items()) or "none"
    print(f"mode          {meta.get('mode')}   tick {meta.get('tick')}")
    print(f"cash          {meta.get('cash')} of {meta.get('initial_cash')}")
    print(f"holdings      {held}")
    print(f"halted        {meta.get('halted') or 'no'}")
    pending = con.execute(
        "SELECT COUNT(*) FROM orders WHERE status NOT IN ('SETTLED','REJECTED')").fetchone()[0]
    if pending:
        print(f"UNRESOLVED    {pending} order(s) -- reconcile before restarting")
if (out / "STOP").exists():
    print("STOP file     present (no new decisions)")
if (out / "error.json").exists():
    err = json.loads((out / "error.json").read_text())
    print(f"\nSTOPPED       {err['type']}: {err['reason']}")
    for where in err.get("locations", [])[-4:]:
        print(f"              at {where}")
    print("              review this, then: bash deploy/resume.sh")

if not events:
    print("\nNo observations recorded yet.")
    raise SystemExit

last = events[-1]
n = last["neural"]
print(f"\nlast observation  tick {last['tick']}  {last['product']}  {last['mode']}")
print(f"  decoder       DNp20 L {n['left_hz']} Hz / R {n['right_hz']} Hz"
      f"  diff {n['difference_hz']:+} Hz -> {n['side']}")
print(f"  gate          DNpe017 {n['gate_spikes']} spikes"
      + ("  (no gate spikes forces HOLD)" if not n["gate_spikes"] else ""))
print(f"  execution     {last['execution']['status']}"
      + (f"  {last['execution'].get('reason', '')}" if last["execution"].get("reason") else ""))
print(f"  equity        {Decimal(last['equity_usdc']):.4f} USDC"
      f"   change {Decimal(last['pnl_delta_usdc']):+.4f}")
print(f"  stimulus      {n['stimulus']}  ({n['stimulus_ms']} ms pulse)"
      f"   reward spikes {n['reward_spikes']}, aversive {n['aversive_spikes']}")
print(f"  activity      KC {n['KC_spikes']} spikes, {n['total_spikes']} network total")
print(f"  integration   {n['compute_seconds']:.1f} s of wall time, brain at {n['brain_ms']} ms")
m = n["memory"]
print(f"  memory        {m['changed_edges']} of {m['plastic_edges']} plastic edges off baseline"
      f"  ({100 * m['changed_edges'] / m['plastic_edges']:.0f}%)")
print(f"                efficacy mean {m['mean_efficacy']:.4f}, min {m['minimum_efficacy']:.4f}"
      f"   (bounds 0.1-2.0; at a bound means saturated, not converged)")

print(f"\nlast {min(10, len(events))} observations")
print("  tick  side  execution  equity        change     stimulus  changed edges")
for r in events[-10:]:
    print(f"  {r['tick']:>4}  {r['neural']['side']:<4}  {r['execution']['status']:<9}"
          f"  {Decimal(r['equity_usdc']):>11.4f}  {Decimal(r['pnl_delta_usdc']):>+9.4f}"
          f"  {r['neural']['stimulus']:<8}  {r['neural']['memory']['changed_edges']}")

fills = [r for r in events if r["execution"]["status"] == "FILLED"]
fees = sum(Decimal(r["execution"]["fee"]) for r in fills)
first, last_eq = Decimal(events[0]["equity_usdc"]), Decimal(events[-1]["equity_usdc"])
print(f"\ntotals over {len(events)} observations")
print(f"  fills         {len(fills)}  ({sum(1 for r in fills if r['neural']['side'] == 'BUY')} buy,"
      f" {sum(1 for r in fills if r['neural']['side'] == 'SELL')} sell)")
print(f"  fees booked   {fees:.4f} USDC")
print(f"  equity        {first:.4f} -> {last_eq:.4f}   ({last_eq - first:+.4f})")
print(f"  of which fees {-fees:+.4f}, market {last_eq - first + fees:+.4f}")
holds = sum(1 for r in events if r["neural"]["side"] == "HOLD")
print(f"  hold rate     {holds}/{len(events)} ({100 * holds / len(events):.0f}%)")
vetoes = {}
for r in events:
    if r["execution"]["status"] == "VETO":
        vetoes[r["execution"]["reason"]] = vetoes.get(r["execution"]["reason"], 0) + 1
for reason, count in sorted(vetoes.items(), key=lambda kv: -kv[1]):
    print(f"  veto x{count:<3}     {reason}")
PYCODE

cat <<MSG

files in $OUT
  latest.json        the last observation in full
  latest-input.png   what the retina was shown
  events.jsonl       every observation, one JSON object per line
  provenance.json    exact code, graph and parameter hashes for this run
  brain-{0,1}.npz    alternating neural checkpoints
MSG
