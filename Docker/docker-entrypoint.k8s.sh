#!/bin/bash
# FOSSology docker-entrypoint script for kubernetes
# SPDX-FileCopyrightText: 2021 Omar AbdelSamea <omarmohamed168@gmail.com>
# SPDX-License-Identifier: GPL-2.0
#
# Description: startup helper script for the FOSSology Docker container in Kubernetes

set -o errexit -o nounset -o pipefail

sed -i 's/address = .*/address = '"${FOSSOLOGY_SCHEDULER_HOST:-scheduler}"'/' \
    /etc/fossology/fossology.conf

if [[ "$1" != "scheduler" ]]; then
  echo '*****************************************************'
  echo 'WARNING: No database host was set and therefore the'
  echo 'internal database without persistency will be used.'
  echo 'THIS IS NOT RECOMMENDED FOR PRODUCTIVE USE!'
  echo '*****************************************************'
  bash ./fo_conf.sh db
  sleep 10
  /etc/init.d/postgresql start
  
# addeding  PostgreSQL check for web >> If DB env vars are not set, the script will skip the checks, stopping for failure cause
elif [[ "$1" == "web" ]]; then
  if [[ -z "${FOSSOLOGY_DB_HOST:-}" || -z "${FOSSOLOGY_DB_NAME:-}" || -z "${FOSSOLOGY_DB_USER:-}" || -z "${FOSSOLOGY_DB_PASSWORD:-}" ]]; then
    echo "Warning: Database environment variables not set. Skipping PostgreSQL check for web mode."
  else
    test_for_postgres() {
      PGPASSWORD="${FOSSOLOGY_DB_PASSWORD}" psql -h "${FOSSOLOGY_DB_HOST}" "${FOSSOLOGY_DB_NAME}" "${FOSSOLOGY_DB_USER}" -c '\l' >/dev/null
      return $?
    }
    until test_for_postgres; do
      >&2 echo "Postgres is unavailable - sleeping"
      sleep 1
    done
  fi
fi  

if [[ $# -eq 0 || ($# -eq 1 && "$1" == "scheduler") ]]; then
    /usr/lib/fossology/fo-postinstall --common --database --licenseref
    bash ./fo_conf.sh scheduler
fi

echo
echo 'Fossology initialisation complete; Starting up...'
echo
if [[ $# -eq 0 ]]; then
  # using cron -f &  because let it be run in forground and background
  cron -f &
  /etc/fossology/mods-enabled/scheduler/agent/fo_scheduler \
    --log /dev/stdout \
    --verbose=4095 \
    --reset &
  exec apache2 -DFOREGROUND
elif [[ $# -eq 1 && "$1" == "scheduler" ]]; then
  exec /etc/fossology/mods-enabled/scheduler/agent/fo_scheduler \
    --log /dev/stdout \
    --verbose=4095 \
    --reset
elif [[ $# -eq 1 && "$1" == "web" ]]; then
  cron -f &
  # using DFOREGROUND approach because it is optimal and and cleaner in many Debian-based
  exec apache2 -DFOREGROUND
elif [[ $# -ge 1 && "$1" == "agent" ]]; then
  bash ./fo_conf.sh agent $2
  chmod +x /usr/share/fossology/scheduler/agent/fo_cli
  /usr/share/fossology/scheduler/agent/fo_cli --host=${FOSSOLOGY_SCHEDULER_HOST:-scheduler} \
  --port=24693 --reload || echo "Scheduler is initializing or not running"
  exec tail -f /dev/null
else
  exec "$@"
fi