FROM php:8.2-apache

# Set the working directory
WORKDIR /var/www/html

# Change document root to the web directory
ENV APACHE_DOCUMENT_ROOT=/var/www/html/web
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf && \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Install system dependencies, PHP extensions and Apache mods
RUN apt-get update && apt-get install -y \
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
        libzip-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pecl install memcached-3.2.0 \
    && docker-php-ext-enable memcached opcache \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install iconv gd pdo pdo_mysql zip \
    && a2enmod rewrite expires headers

# Configure PHP
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    { \
        echo 'memory_limit=1024M'; \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=15000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.enable_cli=1'; \
        echo 'opcache.enable=1'; \
    } > "$PHP_INI_DIR/conf.d/docker-php.ini"

# Install composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Add vendor/bin to PATH for easy command execution
ENV PATH="${PATH}:/var/www/html/vendor/bin"

# Setup cron job for drush cron
RUN echo '* * * * * root PATH=$PATH:/var/www/html/vendor/bin; drush cron >/dev/null 2>&1' >> /etc/crontab

# Custom command to start cron and Apache
CMD bash -c "cron && apache2-foreground"
