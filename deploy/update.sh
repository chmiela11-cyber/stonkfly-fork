#!/usr/bin/env bash
# Update an existing paper deployment to the current branch head and restart it.
#
#   sudo bash deploy/update.sh [--run NAME] [--ref BRANCH] [--skip-verify]
#
# This does NOT re-run `prepare`. The MaleCNS graph is already built and its
# checksums are re-checked below; rebuilding it costs many minutes of swap
# traffic on a small instance and nothing in a code update invalidates it.
#
# Changing tracked source or settings changes the run's provenance, and an
# existing run directory then refuses to resume. When that applies, this script
# starts a new directory named after the commit and leaves the old one intact.
set -euo pipefail

REPO_REF="${REPO_REF:-claude/bitcoin-trading-bot-hetzner-7sjyxa}"
APP="${APP:-/var/repositories/stonkfly-fork}"
PREFIX="${PREFIX:-/opt/stonkfly}"
SERVICE_USER="${SERVICE_USER:-stonkfly}"
PRODUCTS="${PRODUCTS:-BTC-USDC}"
UNIT="${UNIT:-stonkfly-paper}"
RUN=""
VERIFY=yes

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    --ref) REPO_REF="$2"; shift 2 ;;
    --skip-verify) VERIFY=no; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

VENV="$PREFIX/venv"
RUNS="$PREFIX/runs"
log() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

# This script rewrites the checkout it is started from, and bash reads a script
# incrementally, so continue from a copy when invoked from inside APP.
if [ -n "${STONKFLY_SELF_COPY:-}" ]; then
  trap 'rm -f "$STONKFLY_SELF_COPY"' EXIT
else
  SELF="$(readlink -f "$0")"
  case "$SELF" in
    "$APP"/*)
      copy="$(mktemp /tmp/stonkfly-update.XXXXXX)"
      cat "$SELF" > "$copy"
      export STONKFLY_SELF_COPY="$copy"
      exec bash "$copy" "$@"
      ;;
  esac
fi

for path in "$APP/.git" "$VENV/bin/python"; do
  [ -e "$path" ] || { echo "Missing $path. Run deploy/install.sh first." >&2; exit 1; }
done
systemctl cat "$UNIT" >/dev/null 2>&1 || {
  echo "Unit $UNIT is not installed. Run deploy/install.sh first." >&2; exit 1; }

cd "$PREFIX"

current="$(systemctl show -p Environment --value "$UNIT" \
  | tr ' ' '\n' | sed -n 's/^STONKFLY_RUN=//p')"
current="${current:-paper}"

log "Current run directory: $RUNS/$current"
if [ -f "$RUNS/$current/ledger.sqlite" ]; then
  sudo -u "$SERVICE_USER" "$VENV/bin/python" -m stonkfly status --out "$RUNS/$current" \
    || echo "(status unavailable)"
fi

log "Fetching $REPO_REF"
before="$(sudo -u "$SERVICE_USER" git -C "$APP" rev-parse HEAD)"
sudo -u "$SERVICE_USER" git -C "$APP" fetch --depth 1 origin "$REPO_REF"
sudo -u "$SERVICE_USER" git -C "$APP" checkout -f FETCH_HEAD
after="$(sudo -u "$SERVICE_USER" git -C "$APP" rev-parse HEAD)"
commit="$(sudo -u "$SERVICE_USER" git -C "$APP" rev-parse --short HEAD)"
log "Now at $commit"

# A run records a hash of every tracked .py/.cpp file and refuses to resume when
# it changes. Docs and deployment files are not part of that hash. A shallow
# clone can lack the old tree, and git then errors rather than reporting no
# diff, which correctly counts as changed.
code_changed=yes
if [ "$before" = "$after" ]; then
  code_changed=no
elif sudo -u "$SERVICE_USER" git -C "$APP" diff --quiet "$before" "$after" \
     -- ':(glob)stonkfly/**/*.py' ':(glob)stonkfly/**/*.cpp' 2>/dev/null; then
  code_changed=no
fi

log "Syncing dependencies"
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install -q -e "$APP[test]"

if [ "$VERIFY" = yes ]; then
  log "Re-checking the prepared dataset (no download, no rebuild)"
  sudo -u "$SERVICE_USER" env STONKFLY_DATA="$PREFIX/data" \
    "$VENV/bin/python" -m stonkfly verify
fi

# A run directory only resumes when the stored settings signature still matches.
if [ -z "$RUN" ]; then
  verdict="$(sudo -u "$SERVICE_USER" env PYTHONPATH="$APP" "$VENV/bin/python" - \
      "$RUNS/$current/ledger.sqlite" "$PRODUCTS" <<'PY'
import json, sqlite3, sys
from pathlib import Path
from stonkfly.config import Settings

db = Path(sys.argv[1])
if not db.exists():
    print("fresh")
    raise SystemExit
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    stored = {k: json.loads(v) for k, v in con.execute("SELECT key,value FROM meta")}
except Exception:
    print("unreadable")
    raise SystemExit
wanted = Settings(products=tuple(sys.argv[2].split())).signature()
print("compatible" if stored.get("settings") == wanted else "incompatible")
PY
)"
  if [ "$code_changed" = no ] && [ "$verdict" != incompatible ]; then
    RUN="$current"
  else
    RUN="${current%%-*}-$commit"
  fi
  log "Settings: $verdict. Tracked sources changed: $code_changed. Run: '$RUN'"
fi

log "Installing the unit and pointing it at '$RUN'"
sed -e "s#/var/repositories/stonkfly-fork#$APP#g" \
    -e "s#/opt/stonkfly#$PREFIX#g" \
    -e "s#^User=stonkfly#User=$SERVICE_USER#" \
    -e "s#^Group=stonkfly#Group=$SERVICE_USER#" \
    -e "s#--products BTC-USDC#--products $PRODUCTS#" \
    "$APP/deploy/stonkfly-paper.service" > "/etc/systemd/system/$UNIT.service"
mkdir -p "/etc/systemd/system/$UNIT.service.d"
printf '[Service]\nEnvironment=STONKFLY_RUN=%s\n' "$RUN" \
  > "/etc/systemd/system/$UNIT.service.d/run.conf"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$RUNS/$RUN"
systemctl daemon-reload
systemctl restart "$UNIT"

log "Restarted"
systemctl --no-pager --lines=0 status "$UNIT" || true
cat <<MSG

Run directory : $RUNS/$RUN
Previous run  : $RUNS/$current (left intact for comparison)

Follow it:
  journalctl -u $UNIT -f

Expect roughly one observation every 65 s, no "Order cooldown" vetoes on
consecutive proposals, and "stimulus": "none" far more often than before: a
pulse now needs a real price move, not just a booked fee.
MSG
