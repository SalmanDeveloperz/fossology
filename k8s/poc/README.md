<!-- SPDX-FileCopyrightText: © 2026 Muhammad Salman

     SPDX-License-Identifier: GPL-2.0-only
-->
# Milestone 1 — FOSSology on Kubernetes (PoC)

Proves that `fo_scheduler` can dispatch agents to a **separate worker pod over
SSH across the pod network**, reusing the scheduler's existing remote-host
mechanism. The only source change is a one-line bug fix in that mechanism
(see below).

## How it works

The scheduler already supports remote agent hosts. For any `[HOSTS]` entry
whose address is not `localhost`, `agent_spawn()` in
`src/scheduler/agent/agent.c` runs:

```
/usr/bin/ssh <address> <agent_dir>/mods-enabled/<agent>/agent/<cmd> --userID=.. --groupID=.. --scheduler_start --jobId=..
```

and talks to the agent over the SSH session's stdin/stdout. This PoC points
that address at a Kubernetes Service:

```
[HOSTS]
worker0 = fossology-worker /usr/local/etc/fossology 10
```

There is deliberately **no `localhost` entry**, so every agent run (including
the startup self-test of every agent) must go through the worker pod.

| Component | Kind | Role |
|---|---|---|
| `fossology-db` | StatefulSet | PostgreSQL 16 |
| `fossology-worker` | Deployment + Service :22 | `sshd` only; agents execute here |
| `fossology-scheduler` | Deployment (Recreate) + Service :24693 | `fo_scheduler`, SSH client |
| `fossology-web` | Deployment + NodePort 30081 | Apache UI / REST API |
| `fossology-repository` | PVC | shared `/srv/fossology/repository` |

All three FOSSology roles use **one image** (`Dockerfile` here = stock image +
`openssh-server`), selected by the entrypoint argument `worker | scheduler | web`.

## Run it

Prerequisites: Docker, `kind`, `kubectl`, and the stock image built once from
the repo root. The clone **must have the upstream release tags**: the build
version comes from `git describe --tags`, and a version-less build never
records `Release` in the database, so every scheduler restart replays legacy
migrations and aborts (`install/fossinit.php`). `up.sh` refuses such images.

```bash
git fetch --tags https://github.com/fossology/fossology.git
docker compose build
```

Then:

```bash
bash k8s/poc/up.sh
```

UI: http://localhost:8082/repo (user `fossy`, password `fossy`).

## Verify SSH dispatch

```bash
bash k8s/poc/verify.sh
```

It confirms `[HOSTS]` has no `localhost`, uploads a sample (GPL-2.0-only + MIT)
through the REST API with nomos, ojo, monk and copyright, waits for every job
to complete, checks both licenses were found, and checks the worker accepted
new SSH sessions during the scan.

## Bugs found and fixed along the way

1. **Remote hosts could never run C++ agents** (`src/scheduler/agent/agent.c`).
   `meta_agent_init()` stores `raw_cmd = "<cmd> --scheduler_start"`. The local
   path drops that trailing token in `shell_parse()` and appends it once, but
   the SSH path pasted `raw_cmd` verbatim *and* appended `--scheduler_start`
   again. C agents (`getopt`) tolerate the duplicate; every
   `boost::program_options` agent (copyright, ecc, keyword, ipra, ojo,
   compatibility) answered "wrong command line arguments" and was invalidated
   at startup. Fixed by not appending the flag a second time.
2. **`sshd` dropped the scheduler's startup burst.** The scheduler self-tests
   every agent at once; OpenSSH's default `MaxStartups 10:30:100` (plus
   `PerSourcePenalties` in OpenSSH >= 9.8) reset most of those connections.
   Raised in `sshd-fossology.conf`.
3. **Version-less builds crash-loop on restart.** See the prerequisite above.

## Security notes (PoC scope)

- The scheduler key is generated at deploy time and exists only in the
  `fossology-ssh` Secret; the worker mounts only `authorized_keys`.
- `sshd` allows key login for `fossy` only (no passwords, no root, no forwarding).
- Host-key checking is disabled on the scheduler side because worker pods are
  ephemeral; a production chart should pin host keys or use an SSH CA.

## Tear down

```bash
kind delete cluster --name fossology-dev
```

## Known limits (addressed in later milestones)

- Single worker, static `[HOSTS]` → StatefulSet + config reloader (M3).
- `get_host()` ignores agent type → host capability patch (M4).
- RWO volume works only on single-node kind → RWX storage class in the Helm chart (M2).
