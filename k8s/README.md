<!-- SPDX-FileCopyrightText: © 2026 Muhammad Salman

     SPDX-License-Identifier: GPL-2.0-only
-->
# FOSSology on Kubernetes

A Helm chart that runs FOSSology on Kubernetes and scales scanning across
**SSH agent workers**, reusing the scheduler's existing remote-host mechanism
instead of replacing it.

```
k8s/
├── image/                 one image for every role (stock image + sshd)
├── charts/fossology/      Helm chart
├── kind/                  local cluster config and values
└── scripts/               up.sh (build + install), verify.sh (end-to-end check)
```

## How it works

For any `[HOSTS]` entry whose address is not `localhost`, `agent_spawn()` in
`src/scheduler/agent/agent.c` runs

```
/usr/bin/ssh <address> <agent_dir>/mods-enabled/<agent>/agent/<cmd> --userID=.. --groupID=.. --jobId=..
```

and talks to the agent over the SSH session. The chart renders one `[HOSTS]`
line per worker pod, using its stable StatefulSet DNS name:

```
[HOSTS]
fossology-worker-0 = fossology-worker-0.fossology-worker.<ns>.svc /usr/local/etc/fossology 10
```

With workers enabled there is no `localhost` entry, so every agent run, including
the startup self-test of every agent, happens on a worker.

| Component | Kind | Notes |
|---|---|---|
| `<release>-db` | StatefulSet | PostgreSQL 16; disable for an external server |
| `<release>-migrate-<hash>` | Job | schema create/upgrade, see below |
| `<release>-scheduler` | Deployment, 1 replica, Recreate | `fo_scheduler`, SSH client |
| `<release>-worker` | StatefulSet + headless Service | `sshd` only; agents run here |
| `<release>-web` | Deployment + Service (+ Ingress) | Apache UI and REST API |
| `<release>-repository` | PVC | shared `/srv/fossology/repository` |

All roles use one image, selected by the entrypoint argument
(`migrate | wait-migration | scheduler | authorized-keys | worker | web`).

### Database migration

`fo-postinstall --database --licenseref` runs in a Job, not on every scheduler
start. Scheduler and web init containers wait until that Job has succeeded,
using a projected token that only the init container sees and that may only
`get` that one Job.

It is deliberately not a Helm hook: a `post-install` hook runs only after
`helm install --wait` sees every pod ready, and the scheduler cannot become ready
before the schema exists. Instead the Job is named after a hash of its own pod
template, so it re-runs only when the image or database target changes;
scaling workers or changing other values does not migrate again.

## Quick start (kind)

Prerequisites: Docker, `kind`, `kubectl`, `helm`, and the stock image built
from the repo root. The clone **must have the upstream release tags**: the build
version comes from `git describe --tags`, and a version-less build never records
`Release` in the database, so every later migration replays legacy steps and
aborts (`install/fossinit.php`). `up.sh` and the migration Job both refuse such
images.

```bash
git fetch --tags https://github.com/fossology/fossology.git
docker compose build
bash k8s/scripts/up.sh
```

UI: http://localhost:8082/repo (user `fossy`, password `fossy`).

Extra arguments go to `helm upgrade --install`:

```bash
bash k8s/scripts/up.sh --set workers.replicas=3
```

### On another machine

Works on Linux, macOS and Windows (Git Bash) with Docker running and about
8 GB of RAM free for Docker. Install
[kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation),
[kubectl](https://kubernetes.io/docs/tasks/tools/) and
[helm](https://helm.sh/docs/intro/install/), then:

```bash
git clone -b feat/k8s-native-deployment https://github.com/SalmanDeveloperz/fossology.git
cd fossology
git fetch --tags https://github.com/fossology/fossology.git
docker compose build
bash k8s/scripts/up.sh --set workers.replicas=2
bash k8s/scripts/verify.sh
```

The first build compiles FOSSology from source and takes 15-30 minutes.

## Verify

```bash
bash k8s/scripts/verify.sh
```

It confirms `[HOSTS]` has no `localhost`, uploads a sample (GPL-2.0-only + MIT)
through the REST API with nomos, ojo, monk and copyright, waits for every job,
checks the license and copyright findings, reports the new SSH sessions per
worker, and checks that the web pod cannot reach worker SSH.

## Key values

| Value | Default | Purpose |
|---|---|---|
| `workers.enabled` | `true` | `false` runs agents inside the scheduler pod |
| `workers.replicas` | `1` | worker pods; each becomes a `[HOSTS]` entry |
| `workers.maxAgents` | `10` | concurrent agents per worker |
| `postgresql.enabled` | `true` | `false` + `database.host` for an external server |
| `database.existingSecret` | `""` | Secret with key `password` |
| `repository.persistence.accessMode` | `ReadWriteOnce` | use `ReadWriteMany` on multi-node clusters |
| `ssh.existingSecret` | `""` | Secret with key `id_rsa`; generated otherwise |
| `ingress.enabled` | `false` | expose `/repo` through an Ingress |
| `networkPolicy.enabled` | `true` | worker SSH from scheduler only; DB from release pods only |

`values.schema.json` rejects unknown keys and invalid values.

## Security notes

- The scheduler key is generated once and kept across upgrades. Workers derive
  `authorized_keys` in an init container, so the running worker never mounts
  the private key.
- `sshd` allows key login for `fossy` only: no passwords, no root, no forwarding.
- Host-key checking is off on the scheduler side because worker pods are
  ephemeral; pin host keys or use an SSH CA for stricter setups.
- Containers run as root, as the stock image requires (Apache on port 80,
  `sshd`, repository ownership).

## Bugs found and fixed along the way

1. **Remote hosts could never run C++ agents** (`src/scheduler/agent/agent.c`).
   `meta_agent_init()` stores `raw_cmd = "<cmd> --scheduler_start"`. The local
   path drops that trailing token in `shell_parse()` and appends it once, but
   the SSH path pasted `raw_cmd` verbatim and appended `--scheduler_start`
   again. C agents (`getopt`) tolerate the duplicate; every
   `boost::program_options` agent (copyright, ecc, keyword, ipra, ojo,
   compatibility) answered "wrong command line arguments" and was invalidated
   at startup.
2. **`sshd` dropped the scheduler's startup burst.** The scheduler self-tests
   every agent at once; OpenSSH's default `MaxStartups 10:30:100` (plus
   `PerSourcePenalties` in OpenSSH >= 9.8) reset most of those connections.
3. **Version-less builds crash-loop on restart.** See the prerequisite above.
4. **`/api/v1/health` returns 503 while the scheduler is unreachable**, so the
   web probes use `/repo/` instead; otherwise every scheduler restart would take
   the UI offline.
5. **Agents sharing a name raced on a fresh database**
   (`src/lib/php/Dao/AgentDao.php`). The scheduler agents `spdx` and `spdx2`
   both register as agent `spdx2`; during the concurrent startup self-test both
   ran the unlocked SELECT-then-INSERT in `getCurrentAgentId()` and the
   exists-then-CREATE in `createArsTable()`, failing with
   `duplicate key ... agent_unique_name_rev` or
   `relation "spdx2_ars" already exists`. The losing agent was invalidated, so
   SPDX reports stayed unavailable until the scheduler restarted. Starting 8
   agents at once under a new name hit the race in 20 of 40 starts; both paths
   now hold a transaction-scoped advisory lock.
6. **The scheduler segfaulted when an agent failed on one host first**
   (`src/scheduler/agent/agent.c`). The agent type is shared by all hosts; once
   one host invalidated it, the version stayed `NULL` and the next host's
   `VERSION:` greeting reached `strcmp(NULL, ...)`. Impossible with one host,
   so it only appears with remote hosts.
7. **PHP agents could load a half-written DI cache**
   (`src/lib/php/common-container.php`). A fresh container has no
   `container.php`; concurrent agents rebuilt it with a non-atomic write and a
   reader failed with `Class "FossologyCachedContainer" not found`. The cache is
   now written to a temp file and renamed into place.

## Tear down

```bash
helm -n fossology uninstall fossology   # the repository PVC is kept
kind delete cluster --name fossology-dev
```

## Roadmap

| Milestone | Status |
|---|---|
| 1. kind proof of concept: scheduler dispatches agents to a worker pod over SSH | done |
| 2. Helm chart: db, migration Job, scheduler, worker StatefulSet, web, NetworkPolicy | done |
| 3. Scale workers without `helm upgrade`: config reloader + safe scale-down | next |
| 4. Per-agent-type host capabilities in `get_host()` | planned |
| 5. KEDA autoscaling on pending `jobqueue` rows | planned |
| 6. ArgoCD application and multi-environment values | planned |
