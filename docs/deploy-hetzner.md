# Paper run on a Hetzner server

A Stonkfly worker is a single long-running process, not a hosted service. A
small cloud VPS keeps it observing while your laptop sleeps. Nothing here
enables live trading: the unit installed below runs paper mode, holds no
credentials, and cannot submit a real order.

## Server size

| Resource | Needed | Note |
| --- | --- | --- |
| RAM | 16 GB recommended, 8 GB + swap workable | `prepare` holds the full 25.6M-edge graph in memory |
| Disk | 25 GB or more | ~1.1 GB download, derived arrays, dependencies, checkpoints |
| CPU | 2 vCPU is enough | One decision per 60 s; the neural step is single-worker |
| OS | Ubuntu 24.04 or Debian 12 | Python >= 3.11 and a C++17 compiler |

A Hetzner **CX42** (8 vCPU / 16 GB / 160 GB) runs `prepare` comfortably. A
**CX32** (4 vCPU / 8 GB) works once the installer adds swap; the import is
slower. Anything below 8 GB is not worth attempting.

## Install

On a fresh server, as root:

```sh
apt-get update && apt-get install -y git
git clone https://github.com/chmiela11-cyber/stonkfly-fork /opt/stonkfly-src
bash /opt/stonkfly-src/deploy/install.sh
```

The script installs build tooling and Python, adds swap when RAM is tight,
creates a `stonkfly` system user under `/opt/stonkfly`, builds a virtualenv,
downloads and checksum-verifies MaleCNS v1.0, runs three offline fixture ticks
as a smoke test, and installs a systemd unit. Expect 15-40 minutes, mostly
download and graph import. It is idempotent: re-running it updates the checkout
and skips completed steps.

Useful overrides: `REPO_REF` (branch or tag), `PREFIX`, `SERVICE_USER`,
`PRODUCTS` (`"BTC-USDC ETH-USDC"`), `ADD_SWAP=yes|no`.

## Run

```sh
systemctl enable --now stonkfly-paper     # start, and start again after reboot
journalctl -u stonkfly-paper -f           # one JSON line per decision
systemctl stop stonkfly-paper             # stop; state is preserved
```

Progress and the simulated balance:

```sh
sudo -u stonkfly /opt/stonkfly/venv/bin/python -m stonkfly status --out /opt/stonkfly/runs/paper
cat /opt/stonkfly/runs/paper/latest.json
```

`/opt/stonkfly/runs/paper/` holds the SQLite ledger, `events.jsonl`, two
alternating brain checkpoints, the last sensory image, and provenance hashes.
Restarting uses the same directory and resumes the neural state.

Paper fills use observed bid/ask plus a 0.6% fee per side against a simulated
$100 balance. They do not model depth, queue position or market impact, so the
resulting P&L is a plumbing and neural-integration check, **not** evidence that
the controller trades profitably. See [model.md](model.md) and
[validation.md](validation.md).

## When it stops on its own

An error halts the ledger and writes `runs/paper/error.json`; the unit exits
cleanly rather than restarting into the same failure. Read that file, then
recover as described in [operations.md](operations.md). A drawdown or fee stop
cannot be cleared with `--resume-reviewed`.

## Going live is separate

Live execution needs a dedicated Coinbase Advanced portfolio, a portfolio-scoped
ECDSA key with View + Trade and no Transfer, a local `.env`, and the `--live`
flag — steps you perform deliberately, per
[operations.md](operations.md). Do not put a key on the server until a paper run
has convinced you the worker behaves. If you do, keep `coinbase-key.json` at
`chmod 600`, owned by the service user, and outside the repository checkout.
