# Paper run on a Hetzner server

A Stonkfly worker is a single long-running process, not a hosted service. A
small cloud VPS keeps it observing while your laptop sleeps. Nothing here
enables live trading: the unit installed below runs paper mode, holds no
credentials, and cannot submit a real order.

## Server size

The peak is the one-off `prepare` import, not the steady-state run. Size the
server for the import and the worker takes care of itself.

| Resource | Needed | Note |
| --- | --- | --- |
| RAM | 16 GB comfortable; 4 GB works with swap | Only `prepare` needs it; the running worker holds a few hundred MB |
| Disk | 25 GB, plus 8 GB if the installer adds swap | ~1.1 GB download, derived arrays, dependencies, checkpoints |
| CPU | 2 vCPU is enough | One decision per 60 s; the neural step is single-worker |
| OS | Ubuntu 24.04 or Debian 12 | Python >= 3.11 and a C++17 compiler |

A Hetzner **CX42** (8 vCPU / 16 GB / 160 GB) runs `prepare` without swap. A
**CX22** (2 vCPU / 4 GB / 40 GB) has been observed to complete the import and
run the paper worker, using the 8 GB swap file the installer adds below 12 GB
of RAM; the import leans on that swap and is correspondingly slower. Small
instances trade setup time for cost, not capability. Leave the swap in place:
every later `prepare` needs it again.

## Install

On a fresh server, as root:

```sh
apt-get update && apt-get install -y git
mkdir -p /var/repositories
git clone https://github.com/chmiela11-cyber/stonkfly-fork /var/repositories/stonkfly-fork
bash /var/repositories/stonkfly-fork/deploy/install.sh
```

The script installs build tooling and Python, adds swap when RAM is tight,
creates a `stonkfly` system user, builds a virtualenv, downloads and
checksum-verifies MaleCNS v1.0, runs three offline fixture ticks as a smoke
test, and installs a systemd unit. Expect 15-40 minutes, mostly download and
graph import. It is idempotent: re-running it updates the checkout and skips
completed steps. Because it rewrites the checkout it is started from, it
continues from a temporary copy of itself.

Code and mutable state live apart:

| Path | Holds | Writable by the service |
| --- | --- | --- |
| `/var/repositories/stonkfly-fork` | the git checkout | no |
| `/opt/stonkfly/venv` | virtualenv | no |
| `/opt/stonkfly/data` | MaleCNS arrays, compiled neural kernel | yes |
| `/opt/stonkfly/runs/paper` | ledger, checkpoints, logs | yes |

The unit runs under `ProtectSystem=strict` with `/opt/stonkfly` as the only
writable path, so a run cannot modify its own source.

Useful overrides: `REPO_REF` (branch or tag), `APP` (checkout path), `PREFIX`
(state path), `SERVICE_USER`, `PRODUCTS` (`"BTC-USDC ETH-USDC"`),
`ADD_SWAP=yes|no`.

To update later, pull and re-run the installer, then `systemctl restart
stonkfly-paper`.

Changing tracked source files or settings changes the run's provenance hash, and
an existing run directory then refuses to resume, by design. Start a fresh
measurement by pointing the unit at a new directory:

```sh
systemctl edit stonkfly-paper     # [Service] / Environment=STONKFLY_RUN=tuned
systemctl restart stonkfly-paper
```

The previous directory is left intact for comparison. Do not delete a ledger to
get past the refusal.

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
flag. These are steps you perform deliberately, per
[operations.md](operations.md). Do not put a key on the server until a paper run
has convinced you the worker behaves. If you do, keep `coinbase-key.json` at
`chmod 600`, owned by the service user, and outside the repository checkout.
