#!/bin/bash
# FOSSology docker-entrypoint script for kubernetes
# SPDX-FileCopyrightText: 2021 Omar AbdelSamea <omarmohamed168@gmail.com>
# SPDX-License-Identifier: GPL-2.0
#
# Description: startup helper script for the FOSSology Docker container in Kubernetes
# Set database environment variables (override Db.conf if needed)
export FOSSOLOGY_DB_HOST=db
export FOSSOLOGY_DB_NAME=fossology
export FOSSOLOGY_DB_USER=fossy
export FOSSOLOGY_DB_PASSWORD=fossy

set -o errexit -o nounset -o pipefail

# update fossology.conf with scheduler and database host
sed -i 's/address = .*/address = '"${FOSSOLOGY_SCHEDULER_HOST:-scheduler}"'/' /etc/fossology/fossology.conf
sed -i '/\[FOSSOLOGY\]/a DB_HOST=db' /etc/fossology/fossology.conf
# wait for external database (skip for web container)
if [[ "$1" != "web" ]]; then
  test_for_postgres() {
    PGPASSWORD=$FOSSOLOGY_DB_PASSWORD psql -h "$FOSSOLOGY_DB_HOST" "$FOSSOLOGY_DB_NAME" "$FOSSOLOGY_DB_USER" -c '\l' >/dev/null 2>&1
    return $?
  }
  until test_for_postgres; do
    >&2 echo "Postgres is unavailable - sleeping"
    sleep 1
  done
fi  

# # Setup environment and add fossology.conf to etcd
if [[ $# -eq 0 || ($# -eq 1 && "$1" == "scheduler") ]]; then
    /usr/lib/fossology/fo-postinstall --common --database --licenseref
    bash ./fo_conf.sh scheduler
fi

# start Fossology
echo
echo 'Fossology initialisation complete; Starting up...'
echo
if [[ $# -eq 0 ]]; then
  /etc/init.d/cron start
  /etc/fossology/mods-enabled/scheduler/agent/fo_scheduler --log /dev/stdout --verbose=4095 --reset &
  /usr/sbin/apache2ctl -D FOREGROUND
elif [[ $# -eq 1 && "$1" == "scheduler" ]]; then
  exec /etc/fossology/mods-enabled/scheduler/agent/fo_scheduler --log /dev/stdout --verbose=4095 --reset
elif [[ $# -eq 1 && "$1" == "web" ]]; then
  # configure Apache for FOSSology
  sed -i 's/DocumentRoot \/var\/www\/html/DocumentRoot \/usr\/share\/fossology\/www\/ui/' /etc/apache2/sites-available/000-default.conf
  a2dissite 000-default.conf
  a2ensite 000-default.conf
  sed -i '/<Directory \/var\/www\/html>/,/<\/Directory>/ s/DirectoryIndex.*/DirectoryIndex index.php index.html/' /etc/apache2/mods-available/dir.conf
  a2enmod dir
  a2enmod php7.3
  service cron start
  exec /usr/sbin/apache2ctl -e info -D FOREGROUND
elif [[ $# -ge 1 && "$1" == "agent" ]]; then
  bash ./fo_conf.sh agent $2
  chmod +x /usr/share/fossology/scheduler/agent/fo_cli
  /usr/share/fossology/scheduler/agent/fo_cli --host=${FOSSOLOGY_SCHEDULER_HOST:-scheduler} --port=24693 --reload || echo "Scheduler is initializing or not running"
  exec tail -f /dev/null
else
  exec "$@"
fi