FROM php:8.3-apache

# Set the working directory
WORKDIR /var/www/html

# Change document root to the web directory
ENV APACHE_DOCUMENT_ROOT=/var/www/html/web
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf && \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Install system dependencies, PHP extensions and Apache mods
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        default-mysql-client \
        libmemcached-dev \
        zlib1g-dev \
        libssl-dev \
        git \
        cron \
        unzip \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libwebp-dev \
        libzip-dev && \
    rm -rf /var/lib/apt/lists/* && \
    pecl install memcached-3.2.0 && \
    docker-php-ext-enable memcached opcache && \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && \
    docker-php-ext-install iconv gd pdo pdo_mysql zip && \
    a2enmod rewrite expires headers

# Configure PHP
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    { \
        echo 'memory_limit=1024M'; \
        echo 'opcache.enable=1'; \
        echo 'opcache.enable_cli=1'; \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=20000'; \
        echo 'opcache.validate_timestamps=0'; \
    } > "$PHP_INI_DIR/conf.d/docker-php.ini"

# Install composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1

# Add vendor/bin to PATH for easy command execution
ENV PATH="${PATH}:/var/www/html/vendor/bin"

# Setup cron job for drush cron
RUN echo '* * * * * root PATH=$PATH:/var/www/html/vendor/bin; drush cron >/dev/null 2>&1' >> /etc/crontab

# Custom command to start cron and Apache
CMD bash -c "cron && apache2-foreground"
