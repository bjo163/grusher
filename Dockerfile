# Dockerfile for Grusher
FROM php:8.2-apache

# Install system dependencies and PHP extensions
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libgmp-dev \
    libmagickwand-dev \
    libmemcached-dev \
    libsnmp-dev snmp \
    libxslt-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libonig-dev \
    unzip \
    git \
    wget \
    nano \
    cron \
    iputils-ping \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install Composer manually
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
    gd \
    zip \
    mysqli \
    pdo_mysql \
    opcache \
    intl \
    gmp \
    sockets \
    xsl \
    ctype \
    fileinfo \
    ftp \
    mbstring \
    snmp \
    curl

# Install imagick
RUN pecl install imagick \
    && docker-php-ext-enable imagick

# Install memcached
RUN pecl install memcached \
    && docker-php-ext-enable memcached

# Install xmlrpc via PECL
RUN pecl install xmlrpc \
    && docker-php-ext-enable xmlrpc

# Enable Apache mod_rewrite
RUN a2enmod rewrite

# Set recommended PHP.ini settings
COPY php.ini /usr/local/etc/php/

# Set working directory
WORKDIR /var/www/html

# Copy Grusher installer and other necessary scripts to a tools directory
COPY doc/grusher_installer.phar /opt/grusher_tools/grusher_installer.phar
RUN chmod +x /opt/grusher_tools/grusher_installer.phar

COPY entrypoint-websocket.sh /opt/grusher_tools/entrypoint-websocket.sh
RUN chmod +x /opt/grusher_tools/entrypoint-websocket.sh

# Add cron job for Grusher (assuming cron.php will exist after installation)
RUN echo "* * * * * www-data /usr/local/bin/php /var/www/html/grusher/cron.php > /dev/null 2>&1" > /etc/cron.d/grusher-cron \
    && chmod 0644 /etc/cron.d/grusher-cron \
    && crontab /etc/cron.d/grusher-cron \
    && touch /var/log/cron.log
# RUN service cron start # This should be started by entrypoint or supervisord if needed as a long-running service

# Expose port 80
EXPOSE 80

# Entrypoint to guide user for installation or start services
# entrypoint.sh is copied from the root of the build context by default if not specified otherwise
# COPY entrypoint.sh /entrypoint.sh # This line is usually not needed if ENTRYPOINT is just "/entrypoint.sh"
# RUN chmod +x /entrypoint.sh # Ensure it's executable if copied explicitly
ENTRYPOINT ["/entrypoint.sh"]
