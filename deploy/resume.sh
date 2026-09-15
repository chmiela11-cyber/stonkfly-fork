#!/usr/bin/env bash
# Clear a halted run after you have reviewed why it stopped, and restart it.
#
#   bash deploy/resume.sh          # show the error and what resuming would do
#   bash deploy/resume.sh --yes    # clear the halt and start the worker
#
# The program itself refuses to clear a drawdown or fee-overrun stop, or a halt
# with an unresolved order behind it. This only reaches the cases that a restart
# can legitimately recover, and it never submits an order to do so.
set -euo pipefail

PREFIX="${PREFIX:-/opt/stonkfly}"
SERVICE_USER="${SERVICE_USER:-stonkfly}"
UNIT="${UNIT:-stonkfly-paper}"
RUN=""
YES=no

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --yes|-y) YES=yes; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$RUN" ]; then
  RUN="$(systemctl show -p Environment --value "$UNIT" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^STONKFLY_RUN=//p')"
  RUN="${RUN:-paper}"
fi
OUT="$PREFIX/runs/$RUN"
[ -d "$OUT" ] || { echo "No such run directory: $OUT" >&2; exit 1; }

echo "run           $OUT"
if [ -f "$OUT/error.json" ]; then
  echo "--- error.json ---"
  cat "$OUT/error.json"
  echo "------------------"
else
  echo "No error.json; the run may have stopped cleanly."
fi

# Clearing the halt returns from preflight before the provenance check, so a
# source or protocol mismatch halts again on the very next start. A separate run
# directory is the fix, not resuming this one.
if [ -f "$OUT/error.json" ] && grep -q "Run source/protocol changed" "$OUT/error.json"; then
  cat <<MSG

This run stopped because the code or settings changed under it. Resuming cannot
help: the check runs again at every start and this directory still carries the
old provenance.

Start a separate measurement instead, which leaves this one intact:
  bash deploy/update.sh --run <name>

Or let the updater pick the name:
  bash deploy/update.sh
MSG
  exit 1
fi

if [ -f "$OUT/STOP" ]; then
  cat <<MSG

A STOP file is present. That is a deliberate stop, so this script will not
remove it. Delete it yourself once you are satisfied, then run this again:
  rm $OUT/STOP
MSG
  exit 1
fi

if [ "$YES" != yes ]; then
  cat <<MSG

Read the error above first. A transient exchange or network condition is
recoverable; a checksum or accounting failure is not, and resuming will only
stop again.

When you have decided:
  bash deploy/resume.sh --yes
MSG
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo) to restart the unit." >&2; exit 1; }

echo
echo "== Stopping the unit so the run directory lock is free"
systemctl stop "$UNIT" || true

echo "== Clearing the halt (read-only preflight, no order is submitted)"
cd "$PREFIX"
sudo -u "$SERVICE_USER" env STONKFLY_DATA="$PREFIX/data" \
  "$PREFIX/venv/bin/python" -m stonkfly run --resume-reviewed --preflight-only --out "$OUT"

rm -f "$OUT/error.json"
echo "== Starting the worker"
systemctl start "$UNIT"
systemctl --no-pager --lines=0 status "$UNIT" || true
echo
echo "Follow it:  bash deploy/inspect.sh --follow"
