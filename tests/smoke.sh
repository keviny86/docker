#!/bin/bash
# Checks the PHP setup, tools and Apache configuration of an image.
# Usage: tests/smoke.sh IMAGE [--php-only]
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

image=$1
php_only=${2:-}
# Explicit, so Docker doesn't warn when testing an arm64 image on amd64
platform=$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$image")

in_image() { docker run --rm --platform "$platform" --entrypoint bash "$image" -c "$1" 2>&1; }

echo "PHP"
expect_eq "PHP starts without warnings" "" "$(docker run --rm --platform "$platform" --entrypoint php "$image" -v 2>&1 > /dev/null)"
modules=$(in_image 'php -m')
for ext in gd pdo_mysql zip 'Zend OPcache' apcu memcached; do
    expect_match "extension $ext loaded" "^$ext\$" "$modules"
done
expect_eq "gd supports JPEG, WebP and FreeType" "111" \
    "$(in_image 'php -r "\$g = gd_info(); echo (int) \$g[\"JPEG Support\"], (int) \$g[\"WebP Support\"], (int) \$g[\"FreeType Support\"];"')"
expect_eq "no missing shared libraries" "" "$(in_image 'ldd "$(php-config --extension-dir)"/*.so | grep "not found"')"
expect_eq "build dependencies purged" "" "$(in_image 'dpkg -l libmemcached-dev libpng-dev libzip-dev 2>/dev/null | grep ^ii')"

echo "Tools"
for cmd in 'composer --version' 'git --version' 'unzip -v' 'mariadb --version' 'supercronic -version'; do
    check "$cmd" docker run --rm --platform "$platform" --entrypoint bash "$image" -c "$cmd"
done

[ "$php_only" = --php-only ] && finish && exit

echo "Apache"
name=smoke-$$
start_container "$name" "$image"
for _ in $(seq 1 20); do
    docker exec "$name" curl -s -o /dev/null http://localhost/ && break
    sleep 0.5
done
in_container() { docker exec "$name" bash -c "$1" 2>&1; }

# A page that reports the settings PHP has under Apache, and Drupal's
# zend.assertions override, which used to log a warning on every request
in_container 'mkdir -p web && cat > web/info.php <<"EOF"
<?php
foreach (["memory_limit", "upload_max_filesize", "post_max_size", "max_input_vars", "apc.shm_size",
          "apc.enabled", "expose_php", "zend.assertions", "opcache.validate_timestamps",
          "opcache.max_accelerated_files"] as $key) {
  echo $key, "=", ini_get($key), "\n";
}
EOF
echo "php_value zend.assertions 0" > web/.htaccess'
settings=$(in_container 'curl -s http://localhost/info.php')
for setting in memory_limit=512M upload_max_filesize=64M post_max_size=72M max_input_vars=5000 \
    apc.shm_size=128M apc.enabled=1 expose_php= zend.assertions=0 opcache.validate_timestamps=0 \
    opcache.max_accelerated_files=50000; do
    expect_match "PHP under Apache: $setting" "^$setting\$" "$settings"
done

expect_match "config is valid" "Syntax OK" "$(in_container '. /etc/apache2/envvars && apache2ctl -t')"
modules=$(in_container '. /etc/apache2/envvars && apache2ctl -M')
for module in rewrite expires headers; do
    expect_match "module $module enabled" "${module}_module" "$modules"
done
expect_no_match "module status disabled" "status_module" "$modules"
headers=$(in_container 'curl -sI http://localhost/info.php')
expect_match "Server header hides the version" $'^Server: Apache\r?$' "$headers"
expect_no_match "no X-Powered-By header" "X-Powered-By" "$headers"
expect_eq "/server-status not found" 404 "$(in_container 'curl -s -o /dev/null -w "%{http_code}" http://localhost/server-status')"
expect_match "supercronic runs as www-data" "^www-data +supercronic" "$(in_container 'ps -eo user,args')"
logs=$(docker logs "$name" 2>&1)
expect_no_match "no PHP warnings in the log" "PHP (Warning|Fatal|Deprecated)" "$logs"
expect_no_match "no ServerName warning" "AH00558" "$logs"

expect_match "ServerLimit follows APACHE_MAX_REQUEST_WORKERS above 256" "Syntax OK" \
    "$(docker run --rm -e APACHE_MAX_REQUEST_WORKERS=400 --entrypoint bash "$image" -c '. /etc/apache2/envvars && apache2ctl -t' 2>&1)"

name=smoke-docroot-$$
start_container "$name" -e APACHE_DOCUMENT_ROOT=/var/www/html/public "$image"
docker exec "$name" bash -c 'mkdir -p public && echo docroot-ok > public/index.html'
for _ in $(seq 1 20); do
    docker exec "$name" curl -sf -o /dev/null http://localhost/ && break
    sleep 0.5
done
expect_eq "APACHE_DOCUMENT_ROOT can be changed at runtime" docroot-ok "$(docker exec "$name" curl -s http://localhost/)"

finish
