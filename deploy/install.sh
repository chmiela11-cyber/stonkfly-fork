#!/usr/bin/env bash
# Provision a fresh Debian/Ubuntu server (e.g. a Hetzner Cloud VPS) for a
# Stonkfly PAPER run. Paper mode is the only thing this script configures:
# it never writes credentials, never sets STONKFLY_LIVE and never passes --live.
#
#   sudo REPO_REF=main bash deploy/install.sh
#
# Overridable: REPO_URL, REPO_REF, APP, PREFIX, SERVICE_USER, PRODUCTS, ADD_SWAP.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/chmiela11-cyber/stonkfly-fork}"
REPO_REF="${REPO_REF:-main}"
# Checkout and mutable state are deliberately separate: the code directory is
# mounted read-only by the service unit.
APP="${APP:-/var/repositories/stonkfly-fork}"
PREFIX="${PREFIX:-/opt/stonkfly}"
SERVICE_USER="${SERVICE_USER:-stonkfly}"
PRODUCTS="${PRODUCTS:-BTC-USDC}"
ADD_SWAP="${ADD_SWAP:-auto}"   # auto | yes | no

VENV="$PREFIX/venv"
DATA="$PREFIX/data"
RUNS="$PREFIX/runs"

log() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

# This script updates $APP in place. Bash reads a script incrementally, so
# rewriting the file while it runs would corrupt execution: when invoked from
# inside the checkout, continue from a copy instead.
if [ -n "${STONKFLY_SELF_COPY:-}" ]; then
  trap 'rm -f "$STONKFLY_SELF_COPY"' EXIT
else
  SELF="$(readlink -f "$0")"
  case "$SELF" in
    "$APP"/*)
      copy="$(mktemp /tmp/stonkfly-install.XXXXXX)"
      cat "$SELF" > "$copy"
      export STONKFLY_SELF_COPY="$copy"
      exec bash "$copy" "$@"
      ;;
  esac
fi

log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# build-essential stays installed: the neural kernel is compiled by `c++` on
# first run and rebuilt whenever kernel.cpp changes.
apt-get install -y --no-install-recommends \
  git ca-certificates curl build-essential python3 python3-venv python3-dev

PY="$(command -v python3.11 || command -v python3)"
"$PY" - <<'PYCHECK'
import sys
if sys.version_info < (3, 11):
    sys.exit(f"Stonkfly needs Python >= 3.11, found {sys.version.split()[0]}")
PYCHECK
log "Using $($PY --version)"

# `prepare` holds the full 25.6M-edge graph in memory. Under ~12 GB of RAM a
# swap file is the difference between a finished import and an OOM kill.
ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$ADD_SWAP" = yes ] || { [ "$ADD_SWAP" = auto ] && [ "$ram_mb" -lt 12000 ] && [ "$swap_mb" -lt 4096 ]; }; then
  if [ ! -f /swapfile ]; then
    log "RAM ${ram_mb} MB: adding an 8 GB swap file"
    fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

log "Creating $SERVICE_USER, $PREFIX and $APP"
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$PREFIX" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$PREFIX" "$DATA" "$RUNS" "$(dirname "$APP")"
chown -R "$SERVICE_USER:$SERVICE_USER" "$PREFIX"
# Later steps drop to $SERVICE_USER, which may not be able to reach root's
# current directory; work from one it owns.
cd "$PREFIX"

log "Fetching $REPO_URL ($REPO_REF) into $APP"
if [ -d "$APP/.git" ]; then
  # A bootstrap clone is usually made by root; hand it to the service user.
  chown -R "$SERVICE_USER:$SERVICE_USER" "$APP"
  sudo -u "$SERVICE_USER" git -C "$APP" fetch --depth 1 origin "$REPO_REF"
  sudo -u "$SERVICE_USER" git -C "$APP" checkout -f FETCH_HEAD
else
  [ -e "$APP" ] && { echo "$APP exists and is not a git checkout." >&2; exit 1; }
  sudo -u "$SERVICE_USER" git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$APP"
fi

log "Building the virtualenv"
sudo -u "$SERVICE_USER" "$PY" -m venv "$VENV"
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --upgrade pip
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install -e "$APP[test]"

log "Downloading and verifying MaleCNS v1.0 (~1.1 GB; several minutes)"
sudo -u "$SERVICE_USER" env STONKFLY_DATA="$DATA" "$VENV/bin/python" -m stonkfly prepare
sudo -u "$SERVICE_USER" env STONKFLY_DATA="$DATA" "$VENV/bin/python" -m stonkfly verify

log "Smoke test: 3 offline fixture ticks, no network market data, no orders"
rm -rf "$RUNS/smoke"
sudo -u "$SERVICE_USER" env STONKFLY_DATA="$DATA" OPENBLAS_NUM_THREADS=1 \
  "$VENV/bin/python" -m stonkfly run --fixture --fast --steps 3 --out "$RUNS/smoke"

log "Installing the systemd unit"
sed -e "s#/var/repositories/stonkfly-fork#$APP#g" \
    -e "s#/opt/stonkfly#$PREFIX#g" \
    -e "s#^User=stonkfly#User=$SERVICE_USER#" \
    -e "s#^Group=stonkfly#Group=$SERVICE_USER#" \
    -e "s#--products BTC-USDC#--products $PRODUCTS#" \
    "$APP/deploy/stonkfly-paper.service" > /etc/systemd/system/stonkfly-paper.service
systemctl daemon-reload

cat <<MSG

Done. Paper mode is installed but not started. Start it with:

  sudo systemctl enable --now stonkfly-paper
  journalctl -u stonkfly-paper -f

Check the balance at any time:

  sudo -u $SERVICE_USER $VENV/bin/python -m stonkfly status --out $RUNS/paper

Stop it:

  sudo systemctl stop stonkfly-paper

Paper mode uses real public prices and a simulated \$100 balance. It holds no
credentials and cannot place a real order. Live trading is a separate, manual
decision documented in docs/operations.md.
MSG
