# Drupal PHP + Apache images

Base images for running Drupal sites in production: PHP with Apache, the PHP extensions Drupal needs, Composer, and drush cron built in.

## Tags

| Tag | PHP | Platforms |
|---|---|---|
| `php-8.5-apache` | 8.5 (Debian trixie) | amd64, arm64 |
| `php-8.4-apache` | 8.4 | amd64 |
| `php-8.3-apache` | 8.3 | amd64 |
| `php-8.2-apache` | 8.2 | amd64 |

Images are rebuilt every Monday to pick up PHP and Debian security updates. Each build is also tagged with its date, for example `php-8.5-apache-20261026`; pin to a dated tag to roll back or to keep builds reproducible.

This page describes `php-8.5-apache`. The 8.2–8.4 tags use an older setup, see [Older tags](#older-tags-82-84).

## What's included

- **Apache** serving `/var/www/html/web`, with `rewrite`, `expires` and `headers` enabled
- **PHP extensions:** gd (JPEG, WebP, FreeType), pdo_mysql, zip, OPcache, APCu, memcached
- **Tools:** Composer 2, git, unzip, MariaDB client (for `drush sql:*`)
- **drush cron**, scheduled by [Supercronic](https://github.com/aptible/supercronic)
- The compilers PHP needs to build extensions, so sites can add their own

## Usage

The image expects a Composer-based Drupal project (like `drupal/recommended-project`) in `/var/www/html`, with the docroot in `web/` and drush installed by Composer. `vendor/bin` is on the `PATH`.

```dockerfile
FROM keviny86/drupal:php-8.5-apache

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --optimize-autoloader

COPY config ./config
COPY web ./web
```

```yaml
services:
  drupal:
    build: .
    # Let a running cron finish when the container stops
    stop_grace_period: 15m
    environment:
      DRUSH_OPTIONS_URI: "https://example.com"
      DRUSH_CRON_SCHEDULE: "*/15 * * * *"
      TZ: "Europe/Stockholm"
    volumes:
      - files:/var/www/html/web/sites/default/files

volumes:
  files:
```

The files directory must be writable by `www-data`.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DRUSH_CRON_SCHEDULE` | `* * * * *` | When drush cron runs, in cron syntax. `@hourly`, `@daily` etc. work too. For seconds use 7 fields: `*/30 * * * * * *` (second minute hour day month weekday year). |
| `DRUSH_CRON_TIMEOUT` | `3600` | Seconds before a cron run is stopped. `0` disables the timeout. |
| `TZ` | UTC | Timezone for the cron schedule. |
| `APACHE_MAX_REQUEST_WORKERS` | `150` | Maximum simultaneous requests. Each can use up to `memory_limit` (512M), so lower it to fit the container's memory. |
| `APACHE_DOCUMENT_ROOT` | `/var/www/html/web` | Apache's document root. |

## Cron

drush cron runs inside the container, next to Apache:

- It runs as `www-data`, with the container's environment variables.
- It is skipped while the site is in maintenance mode, for example during a deploy, and when maintenance mode can't be checked (such as while the database is starting).
- A new run never starts while the previous one is still running.
- Successful runs log nothing. Failures and warnings logged by Drupal during a run appear in `docker logs`.

When running several replicas, cron runs in each of them; Drupal's cron lock makes sure only one run happens at a time.

## Graceful shutdown

On `SIGTERM` (`docker stop`, Kubernetes) the container:

- lets a running cron finish, and starts no new one
- stops Apache gracefully, waiting at most 30 seconds for requests in progress

Docker kills containers that haven't stopped after 10 seconds, so set `stop_grace_period` (Compose) or `terminationGracePeriodSeconds` (Kubernetes) to how long your cron may take. It's a maximum: an idle container stops in about a second.

The container also exits if Apache or the cron scheduler stops unexpectedly, so the restart policy can bring it back.

## PHP settings

Based on `php.ini-production`, plus:

| Setting | Value |
|---|---|
| `memory_limit` | 512M |
| `upload_max_filesize` / `post_max_size` | 64M / 72M |
| `max_input_vars` | 5000 |
| `apc.shm_size` | 128M |
| `opcache.memory_consumption` | 256 |
| `opcache.max_accelerated_files` | 50000 |
| `opcache.validate_timestamps` | 0 |
| `expose_php` | Off |

`opcache.validate_timestamps=0` means PHP never rereads changed code: deploy new code by building a new image and restarting the container. `drush cr` does not clear Apache's OPcache.

To change a setting, add an ini file in your site image:

```dockerfile
COPY php.ini /usr/local/etc/php/conf.d/zz-site.ini
```

## Running drush

Run drush as `www-data`, so files it writes (translations, Twig cache) aren't owned by root:

```sh
docker exec -u www-data -e HOME=/tmp <container> drush status
```

The MariaDB client in the image (11.8) requires TLS by default. If your database server doesn't offer TLS (MariaDB before 11.4), `drush sql:*` commands fail with `SSL is required, but the server does not support it`. Add this to the database connection in `settings.php`:

```php
'pdo' => [\Pdo\Mysql::ATTR_SSL_VERIFY_SERVER_CERT => FALSE],
```

## Adding PHP extensions

The compilers are kept in the image, so sites can install more extensions:

```dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends libicu-dev && \
    docker-php-ext-install intl && \
    rm -rf /var/lib/apt/lists/*
```

`RUN` steps in images built from this one use `bash -o pipefail`, so a failure anywhere in a pipeline fails the build.

## Tests

Every build of `php-8.5-apache` is tested before it is published: the PHP setup, Apache configuration, cron and shutdown behaviour, a real Drupal install against MariaDB, and a scan for critical vulnerabilities that have a fix. To run the tests locally, from the source repository:

```sh
tests/lint.sh
docker build -t drupal-test drupal-php-8.5-apache
tests/smoke.sh drupal-test
tests/cron.sh drupal-test
tests/drupal.sh drupal-test
tests/scan.sh drupal-test
```

## Older tags (8.2–8.4)

The 8.2–8.4 tags have not been updated to the setup above:

- drush cron runs as root: every minute through Debian's cron on 8.2 and 8.3 (output discarded), every 30 seconds through Supercronic on 8.4
- No graceful shutdown, maintenance-mode check, timeout or environment variables for cron
- Older PHP and Apache settings (for example `memory_limit=1024M`, no APCu, Apache version shown in headers)
