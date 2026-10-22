#!/bin/bash
# Installs a real Drupal site in the image, against MariaDB, and checks pages,
# drush, cron and the logs.
# Usage: tests/drupal.sh IMAGE
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

image=$1
net=drupal-test-$$
# Drupal 11 needs PHP 8.3 or later
php_version=$(docker run --rm --entrypoint php "$image" -r 'echo PHP_VERSION_ID;')
if [ "$php_version" -lt 80300 ]; then drupal=^10; else drupal=^11; fi
db=$net-db
web=$net-web

make_network "$net"
start_container "$db" --network "$net" --network-alias database \
    -e MARIADB_DATABASE=drupal -e MARIADB_USER=drupal -e MARIADB_PASSWORD=drupal \
    -e MARIADB_RANDOM_ROOT_PASSWORD=1 mariadb:11.8
start_container "$web" --network "$net" -e DRUSH_OPTIONS_URI=http://localhost \
    -e DRUSH_CRON_SCHEDULE='*/5 * * * * * *' "$image"

as_root() { docker exec "$web" "$@"; }
d() { docker exec -u www-data -e HOME=/tmp "$web" drush "$@"; }
# drush sqlq prints a blank line after the result
sql() { d sqlq "$1" 2>&1 | grep -v '^[[:space:]]*$' | tail -n 1; }

echo "Install"
for _ in $(seq 1 60); do
    docker exec "$db" healthcheck.sh --connect > /dev/null 2>&1 && break
    sleep 1
done
check "composer create-project drupal/recommended-project:$drupal" \
    as_root composer create-project "drupal/recommended-project:$drupal" . --no-interaction --no-progress
check "composer require drush/drush" as_root composer require drush/drush --no-interaction --no-progress
check "drush site:install" as_root drush site:install minimal -y --site-name=Test \
    --db-url=mysql://drupal:drupal@database/drupal
as_root chown -R www-data:www-data web/sites/default/files
check "dblog enabled" d pm:install dblog -y

echo "Site"
expect_eq "/user/login returns 200" 200 \
    "$(as_root curl -s -o /dev/null -w '%{http_code}' http://localhost/user/login)"
expect_match "drush bootstraps Drupal" "Successful" "$(d status --field=bootstrap 2>&1)"
check "drush cron" d cron
# A real project has its config exported; deploy refuses an empty import
check "drush config:export" d config:export -y
check "drush deploy" d deploy -y

echo "Database tools"
expect_match "drush sqlq" '^[0-9]+$' "$(sql 'select count(*) from users')"
check "drush sql:dump" d sql:dump --result-file=/tmp/dump.sql
expect_match "dump contains tables" "CREATE TABLE" "$(as_root cat /tmp/dump.sql)"
expect_match "drush sql:connect" "connect-ok" \
    "$(docker exec -u www-data -e HOME=/tmp "$web" bash -c '$(drush sql:connect) -N -e "select \"connect-ok\""' 2>&1)"

echo "Cron"
# The maintenance check in the crontab relies on these exact values
d state:set system.maintenance_mode 1 > /dev/null 2>&1
expect_eq "state:get prints 1 for drush state:set 1" 1 "$(d state:get system.maintenance_mode 2>/dev/null)"
d php:eval '\Drupal::state()->set("system.maintenance_mode", TRUE);' > /dev/null 2>&1
expect_match "state:get prints 1 or true for TRUE (admin form)" '^(1|true)$' "$(d state:get system.maintenance_mode 2>/dev/null)"
d watchdog:delete all -y > /dev/null 2>&1
sleep 12
expect_eq "no cron runs in maintenance mode" 0 "$(sql "select count(*) from watchdog where type = 'cron'")"
d state:set system.maintenance_mode 0 > /dev/null 2>&1
sleep 12
cron_runs=$(sql "select count(*) from watchdog where type = 'cron' and message like 'Cron run completed%'")
if [ "${cron_runs:-0}" -ge 1 ] 2> /dev/null; then pass "scheduled cron runs ($cron_runs runs)"; else fail "scheduled cron runs (got '$cron_runs')"; fi

echo "Logs and files"
expect_eq "no PHP errors or warnings in Drupal's log" 0 \
    "$(sql "select count(*) from watchdog where type = 'php' and severity <= 4")"
logs=$(docker logs "$web" 2>&1)
expect_no_match "no PHP warnings in the container log" "PHP (Warning|Fatal|Deprecated)" "$logs"
expect_eq "cron and drush leave no root-owned files" "" \
    "$(as_root find web/sites/default/files -user root)"

finish
