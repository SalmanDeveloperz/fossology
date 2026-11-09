#!/bin/bash
# FOSSology Kubernetes PoC entrypoint
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Roles:
#   worker    - sshd only; the scheduler runs agents here over SSH
#   scheduler - installs the SSH client key, rewrites [HOSTS], waits for
#               every remote host to accept SSH, then starts fo_scheduler
#   web       - Apache UI (delegates to the stock entrypoint)

set -o errexit -o nounset -o pipefail

FO_SYSCONFDIR=/usr/local/etc/fossology
FO_REPO=/srv/fossology/repository
SSH_SECRET_DIR=/etc/fossology-ssh
FOSSY_HOME=/home/fossy

prepare_repository() {
  mkdir -p "$FO_REPO"
  chown fossy:fossy "$FO_REPO"
  chmod 2770 "$FO_REPO"
}

write_db_conf() {
  cat > "$FO_SYSCONFDIR/Db.conf" <<EOM
dbname=${FOSSOLOGY_DB_NAME:-fossology};
host=${FOSSOLOGY_DB_HOST:-localhost};
user=${FOSSOLOGY_DB_USER:-fossy};
password=${FOSSOLOGY_DB_PASSWORD:-fossy};
EOM
}

install_fossy_ssh_file() {
  install -d -m 700 -o fossy -g fossy "$FOSSY_HOME/.ssh"
  install -m 600 -o fossy -g fossy "$SSH_SECRET_DIR/$1" "$FOSSY_HOME/.ssh/$2"
}

# Replace the body of [HOSTS] with $FOSSOLOGY_HOSTS (one "name = address dir max" per line).
configure_hosts() {
  [[ -z "${FOSSOLOGY_HOSTS:-}" ]] && return 0
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

# The scheduler tests every agent on every host at startup, so a host that is
# not reachable yet would mark agents as invalid.
wait_for_remote_hosts() {
  local name eq addr rest tries
  while read -r name eq addr rest; do
    [[ -z "${addr:-}" || "$addr" == "localhost" ]] && continue
    tries=0
    until su -s /bin/bash fossy -c "ssh $addr true"; do
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

run_worker() {
  prepare_repository
  write_db_conf
  install_fossy_ssh_file authorized_keys authorized_keys
  mkdir -p /run/sshd
  ssh-keygen -A
  exec /usr/sbin/sshd -D -e
}

run_scheduler() {
  prepare_repository
  install_fossy_ssh_file id_ed25519 id_ed25519
  # LogLevel ERROR keeps ssh warnings out of the agent pipe the scheduler parses.
  cat > "$FOSSY_HOME/.ssh/config" <<'EOM'
Host *
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 10
EOM
  chown fossy:fossy "$FOSSY_HOME/.ssh/config"
  chmod 600 "$FOSSY_HOME/.ssh/config"
  configure_hosts
  wait_for_remote_hosts
  exec /fossology/docker-entrypoint.sh scheduler
}

run_web() {
  prepare_repository
  exec /fossology/docker-entrypoint.sh web
}

case "${1:-}" in
  worker)    run_worker ;;
  scheduler) run_scheduler ;;
  web)       run_web ;;
  *)         exec /fossology/docker-entrypoint.sh "$@" ;;
esac
