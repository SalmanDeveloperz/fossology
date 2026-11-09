#!/bin/bash
# FOSSology Kubernetes entrypoint
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Roles:
#   migrate         - create or upgrade the database schema (one Job per release)
#   wait-migration  - init container: block until that Job has succeeded
#   scheduler       - SSH client setup, [HOSTS] from $FOSSOLOGY_HOSTS, waits for
#                     every remote host, then fo_scheduler
#   authorized-keys - init container: derive a worker's authorized_keys from the
#                     scheduler key, so the worker never mounts the private key
#   worker          - sshd only; the scheduler starts agents here over SSH
#   web             - Apache UI and REST API

set -o errexit -o nounset -o pipefail

FO_SYSCONFDIR=/usr/local/etc/fossology
FO_REPO=/srv/fossology/repository
FOSSY_HOME=/home/fossy
SSH_KEY_DIR=/etc/fossology-ssh-key
AUTHORIZED_KEYS_DIR=/etc/fossology-ssh
SA_DIR=/var/run/secrets/fossology-k8s

DB_HOST="${FOSSOLOGY_DB_HOST:-localhost}"
DB_NAME="${FOSSOLOGY_DB_NAME:-fossology}"
DB_USER="${FOSSOLOGY_DB_USER:-fossy}"
DB_PASSWORD="${FOSSOLOGY_DB_PASSWORD:-fossy}"

prepare_repository() {
  mkdir -p "$FO_REPO"
  chown fossy:fossy "$FO_REPO"
  chmod 2770 "$FO_REPO"
}

write_db_conf() {
  cat > "$FO_SYSCONFDIR/Db.conf" <<EOM
dbname=$DB_NAME;
host=$DB_HOST;
user=$DB_USER;
password=$DB_PASSWORD;
EOM
}

wait_for_db() {
  until PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
      -c 'SELECT 1' >/dev/null 2>&1; do
    echo "Waiting for PostgreSQL at $DB_HOST..."
    sleep 2
  done
}

image_version() {
  sed -n 's/^VERSION="\(.*\)"$/\1/p' "$FO_SYSCONFDIR/VERSION"
}

run_migrate() {
  local version
  version="$(image_version)"
  # fossinit.php only records Release when the build has a version; without
  # it every later run replays legacy migrations and aborts.
  if [[ -z "$version" ]]; then
    echo "ERROR: image was built without a version (clone lacks git tags);" \
         "refusing to migrate" >&2
    exit 1
  fi
  echo "Migrating database for FOSSology $version"
  prepare_repository
  write_db_conf
  wait_for_db
  exec /usr/local/lib/fossology/fo-postinstall --common --database --licenseref
}

# Uses a projected, init-container-only service account token that may only
# read this one Job.
run_wait_migration() {
  local job="${FOSSOLOGY_MIGRATION_JOB:?FOSSOLOGY_MIGRATION_JOB is not set}"
  local ns token url status
  ns="$(cat "$SA_DIR/namespace")"
  token="$(cat "$SA_DIR/token")"
  url="https://kubernetes.default.svc/apis/batch/v1/namespaces/$ns/jobs/$job"
  while true; do
    if status="$(curl -fsS --cacert "$SA_DIR/ca.crt" \
                   -H "Authorization: Bearer $token" "$url")"; then
      if grep -q '"succeeded": *[1-9]' <<< "$status"; then
        echo "Migration job $job has succeeded"
        return 0
      fi
      if grep -q '"type": *"Failed", *"status": *"True"' <<< "$status"; then
        echo "ERROR: migration job $job failed; see: kubectl -n $ns logs job/$job" >&2
        exit 1
      fi
    fi
    echo "Waiting for migration job $job..."
    sleep 3
  done
}

install_fossy_ssh_file() {
  install -d -m 700 -o fossy -g fossy "$FOSSY_HOME/.ssh"
  install -m 600 -o fossy -g fossy "$1" "$FOSSY_HOME/.ssh/$2"
}

# Replace the body of [HOSTS] with $FOSSOLOGY_HOSTS (one "name = address dir max" per line).
configure_hosts() {
  local conf="$FO_SYSCONFDIR/fossology.conf" tmp
  tmp="$(mktemp)"
  awk '
    /^\[HOSTS\]/ { print; print ENVIRON["FOSSOLOGY_HOSTS"]; print ""; skip = 1; next }
    /^\[/        { skip = 0 }
    !skip        { print }
  ' "$conf" > "$tmp"
  cat "$tmp" > "$conf"
  rm -f "$tmp"
  echo "Configured [HOSTS]:"
  sed -n '/^\[HOSTS\]/,/^\[REPOSITORY\]/p' "$conf"
}

# The scheduler self-tests every agent on every host at startup, so a host
# that is not reachable yet would get its agents invalidated.
wait_for_remote_hosts() {
  local name eq addr rest tries
  while read -r name eq addr rest; do
    [[ -z "${addr:-}" || "$addr" == "localhost" ]] && continue
    tries=0
    # ssh must not read the loop's stdin, which holds the remaining hosts.
    until su -s /bin/bash fossy -c "ssh -n $addr true" < /dev/null; do
      tries=$((tries + 1))
      if (( tries >= 150 )); then
        echo "ERROR: agent host $addr ($name) never accepted SSH" >&2
        exit 1
      fi
      echo "Waiting for agent host $addr ($name) to accept SSH..."
      sleep 2
    done
    echo "Agent host $addr ($name) is reachable over SSH"
  done <<< "${FOSSOLOGY_HOSTS:-}"
}

setup_ssh_client() {
  install_fossy_ssh_file "$SSH_KEY_DIR/id_rsa" id_rsa
  # LogLevel ERROR keeps ssh warnings out of the agent pipe the scheduler parses.
  cat > "$FOSSY_HOME/.ssh/config" <<'EOM'
Host *
  IdentityFile ~/.ssh/id_rsa
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 60
EOM
  chown fossy:fossy "$FOSSY_HOME/.ssh/config"
  chmod 600 "$FOSSY_HOME/.ssh/config"
}

run_scheduler() {
  prepare_repository
  write_db_conf
  # fo_scheduler exits on a failed first connection, e.g. while the DB restarts.
  wait_for_db
  if [[ -f "$SSH_KEY_DIR/id_rsa" ]]; then
    setup_ssh_client
  fi
  if [[ -n "${FOSSOLOGY_HOSTS:-}" ]]; then
    configure_hosts
    wait_for_remote_hosts
  fi
  exec /usr/local/share/fossology/scheduler/agent/fo_scheduler \
    --log /dev/stdout \
    --verbose="${FOSSOLOGY_SCHEDULER_VERBOSE:-3}" \
    --reset
}

run_authorized_keys() {
  ssh-keygen -y -f "$SSH_KEY_DIR/id_rsa" > "$AUTHORIZED_KEYS_DIR/authorized_keys"
  echo "Wrote $AUTHORIZED_KEYS_DIR/authorized_keys"
}

run_worker() {
  prepare_repository
  write_db_conf
  install_fossy_ssh_file "$AUTHORIZED_KEYS_DIR/authorized_keys" authorized_keys
  mkdir -p /run/sshd
  ssh-keygen -A
  exec /usr/sbin/sshd -D -e
}

run_web() {
  prepare_repository
  exec /fossology/docker-entrypoint.sh web
}

case "${1:-}" in
  migrate)         run_migrate ;;
  wait-migration)  run_wait_migration ;;
  scheduler)       run_scheduler ;;
  authorized-keys) run_authorized_keys ;;
  worker)          run_worker ;;
  web)             run_web ;;
  *)               exec /fossology/docker-entrypoint.sh "$@" ;;
esac
