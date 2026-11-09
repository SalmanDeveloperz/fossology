#!/bin/bash
# End-to-end check of the Kubernetes PoC through the REST API.
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Uploads a sample with known licenses, scans it, checks the findings, and
# proves the agents ran on the worker pod over SSH.

set -o errexit -o nounset -o pipefail
# Git Bash on Windows would rewrite in-container paths such as /usr/local/...
export MSYS_NO_PATHCONV=1

API="${API:-http://localhost:8082/repo/api/v1}"
NS="fossology"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
worker_pods() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}
# Prints "<pod> <accepted SSH sessions>" per worker.
ssh_sessions() {
  local pod
  for pod in $(worker_pods); do
    echo "$pod $(kubectl -n "$NS" logs "$pod" -c worker | grep -c 'Accepted publickey for fossy' || true)"
  done
}

echo "== 1. [HOSTS] has no localhost, so no agent can run inside the scheduler pod"
hosts="$(kubectl -n "$NS" exec deploy/fossology-scheduler -- \
  sed -n '/^\[HOSTS\]/,/^\[REPOSITORY\]/p' /usr/local/etc/fossology/fossology.conf)"
echo "$hosts"
echo "$hosts" | grep -q '^localhost' && fail "localhost is still an agent host"

echo "== 2. REST API health"
for _ in $(seq 1 60); do curl -fsS "$API/health" >/dev/null 2>&1 && break; sleep 5; done
curl -fsS "$API/health" || fail "API not healthy"
echo

echo "== 3. Token"
token="$(curl -fsS -X POST "$API/tokens" \
  -d username=fossy -d password=fossy \
  -d token_name="k8s-poc-$(date +%s)" -d token_scope=write \
  -d token_expire="$(date -d '+1 day' +%F)" \
  | sed -n 's/.*"Authorization": *"\([^"]*\)".*/\1/p')"
[[ -n "$token" ]] || fail "could not obtain a token"

echo "== 4. Sample archive (GPL-2.0-only + MIT)"
mkdir -p "$work/sample"
cat > "$work/sample/gpl.c" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (C) 2026 Example Author <author@example.com>
 */
int main(void) { return 0; }
EOF
cat > "$work/sample/mit.py" <<'EOF'
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Another Author
print("hello")
EOF
(cd "$work" && tar -czf sample.tar.gz sample)

sessions_before="$(ssh_sessions)"

echo "== 5. Upload and schedule nomos, ojo, monk, copyright"
resp="$(cd "$work" && curl -fsS -X POST "$API/uploads" \
  -H "Authorization: $token" -H "folderId: 1" -H "uploadType: file" \
  -H "uploadDescription: k8s-poc" \
  -F "fileInput=@sample.tar.gz" \
  -F 'scanOptions={"analysis":{"nomos":true,"ojo":true,"monk":true,"copyright_email_author":true}}')"
echo "$resp"
upload_id="$(echo "$resp" | sed -n 's/.*"message": *\([0-9][0-9]*\).*/\1/p')"
[[ -n "$upload_id" ]] || fail "no upload id in response"

echo "== 6. Waiting for upload $upload_id jobs"
for _ in $(seq 1 120); do
  jobs="$(curl -fsS "$API/jobs?upload=$upload_id" -H "Authorization: $token")"
  echo "$jobs" | grep -q '"status": *"Failed"' && { echo "$jobs"; fail "a job failed"; }
  if echo "$jobs" | grep -q '"status": *"Completed"' \
     && ! echo "$jobs" | grep -q -E '"status": *"(Processing|Queued)"'; then
    break
  fi
  sleep 5
done
echo "$jobs" | grep -q -E '"status": *"(Processing|Queued)"' && fail "jobs did not finish in time"
echo "jobs completed"

echo "== 7. License findings"
lic="$(curl -fsS "$API/uploads/$upload_id/licenses?agent=nomos,ojo,monk" \
  -H "Authorization: $token")"
echo "$lic"
echo "$lic" | grep -q 'GPL-2.0' || fail "GPL-2.0 not found"
echo "$lic" | grep -q 'MIT' || fail "MIT not found"

echo "== 7b. Copyright findings (a C++ agent; these failed over SSH before the agent.c fix)"
cr="$(curl -fsS "$API/uploads/$upload_id/copyrights" -H "Authorization: $token")"
echo "$cr"
echo "$cr" | grep -q 'Example Author' || fail "copyright agent found nothing"

echo "== 8. SSH sessions the workers accepted during the scan"
sessions_after="$(ssh_sessions)"
total=0
while read -r pod after; do
  before="$(awk -v p="$pod" '$1 == p { print $2 }' <<< "$sessions_before")"
  delta=$((after - ${before:-0}))
  total=$((total + delta))
  echo "$pod: $delta new session(s)"
done <<< "$sessions_after"
(( total > 0 )) || fail "no agent was dispatched to a worker"

echo "== 9. NetworkPolicy: the web pod must not reach worker SSH"
first_worker="$(worker_pods | head -1)"
if kubectl -n "$NS" exec deploy/fossology-web -c web -- \
     timeout 5 bash -c "</dev/tcp/$first_worker.fossology-worker/22" 2>/dev/null; then
  echo "WARNING: web reached $first_worker:22; this cluster's CNI does not enforce NetworkPolicy"
else
  echo "blocked as expected"
fi

echo
echo "PASS: upload $upload_id scanned on the worker pods over SSH"
