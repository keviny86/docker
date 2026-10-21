FROM php:8.5-apache-trixie

# Fail on errors anywhere in a pipeline
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Set the working directory
WORKDIR /var/www/html

# Change document root to the web directory
ENV APACHE_DOCUMENT_ROOT=/var/www/html/web
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf && \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Install system dependencies, PHP extensions and Apache mods, then purge build dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        default-mysql-client \
        git \
        unzip; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev \
        libjpeg-dev \
        libmemcached-dev \
        libpng-dev \
        libssl-dev \
        libwebp-dev \
        libzip-dev \
        zlib1g-dev; \
    pecl install apcu-5.1.28 memcached-3.4.0; \
    docker-php-ext-enable apcu memcached; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" gd pdo_mysql zip; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    # PECL's .so files are not executable
    find /usr/local -type f \( -executable -o -name '*.so' \) -exec ldd '{}' ';' \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | grep -v '^diversion by' \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/* /tmp/pear; \
    a2enmod rewrite expires headers; \
    # /server-status would be public behind a sidecar proxy
    a2dismod status

# Hide Apache version, silence AH00558 warning, and on stop wait at most 30s for
# in-flight requests (e.g. video streams)
RUN sed -ri -e 's/^ServerTokens .*/ServerTokens Prod/' -e 's/^ServerSignature .*/ServerSignature Off/' \
        /etc/apache2/conf-available/security.conf && \
    printf 'ServerName localhost\nGracefulShutdownTimeout 30\n' > /etc/apache2/conf-available/docker-drupal.conf && \
    a2enconf docker-drupal

# Each worker can use up to memory_limit; lower to fit the container's memory
ENV APACHE_MAX_REQUEST_WORKERS=150
RUN sed -ri -e 's/^(\s*)MaxRequestWorkers\s.*/\1ServerLimit ${APACHE_MAX_REQUEST_WORKERS}\n\1MaxRequestWorkers ${APACHE_MAX_REQUEST_WORKERS}/' \
        /etc/apache2/mods-available/mpm_prefork.conf

# Configure PHP. Code changes need a restart (validate_timestamps=0)
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    { \
        echo 'expose_php=Off'; \
        echo 'memory_limit=512M'; \
        echo 'upload_max_filesize=64M'; \
        echo 'post_max_size=72M'; \
        echo 'max_input_vars=5000'; \
        echo 'apc.shm_size=128M'; \
        echo 'realpath_cache_size=4096K'; \
        echo 'realpath_cache_ttl=600'; \
        # Drupal's .htaccess sets 0; with -1 PHP warns on every request
        echo 'zend.assertions=0'; \
        echo 'opcache.enable=1'; \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=50000'; \
        echo 'opcache.validate_timestamps=0'; \
    } > "$PHP_INI_DIR/conf.d/docker-php.ini"

# Install composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1

# Add vendor/bin to PATH for easy command execution
ENV PATH="${PATH}:/var/www/html/vendor/bin"

# Supercronic schedules drush cron
ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=v0.2.49
RUN case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
        arm64) SUPERCRONIC_SHA256=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" && \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - && \
    chmod +x /usr/local/bin/supercronic

# Apache plus drush cron. DRUSH_CRON_SCHEDULE uses cron syntax (in TZ),
# DRUSH_CRON_TIMEOUT is in seconds (0 = none)
COPY --chmod=755 docker-drupal-start /usr/local/bin/
ENV DRUSH_CRON_SCHEDULE="* * * * *"
ENV DRUSH_CRON_TIMEOUT=3600

# The start script stops gracefully on SIGTERM
STOPSIGNAL SIGTERM
CMD ["docker-drupal-start"]
