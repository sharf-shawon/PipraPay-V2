# ─────────────────────────────────────────────────────────────────────────────
# PipraPay-V2 — Production Docker Image
# Base: official PHP 8.2 with Apache (Debian Bookworm slim)
# ─────────────────────────────────────────────────────────────────────────────
FROM php:8.2-apache

LABEL org.opencontainers.image.title="PipraPay" \
      org.opencontainers.image.description="Self-hosted payment automation platform" \
      org.opencontainers.image.url="https://piprapay.com" \
      org.opencontainers.image.source="https://github.com/sharf-shawon/PipraPay-V2" \
      org.opencontainers.image.licenses="AGPL-3.0"

# ── System dependencies & PHP extensions ──────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        # GD image processing
        libpng-dev \
        libjpeg62-turbo-dev \
        libwebp-dev \
        # Zip / auto-update
        libzip-dev \
        # Imagick
        libmagickwand-dev \
        # MySQL CLI for entrypoint health checks & DB init
        default-mysql-client \
        # General utilities used by entrypoint
        unzip \
    && docker-php-ext-configure gd \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        pdo_mysql \
        gd \
        zip \
        opcache \
    # Imagick via PECL
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    # Cleanup — keep image footprint minimal
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/* /tmp/pear /tmp/* /var/tmp/*

# ── Apache configuration ───────────────────────────────────────────────────────
RUN a2enmod rewrite headers

COPY docker/apache/piprapay.conf /etc/apache2/sites-available/000-default.conf

# ── PHP configuration ──────────────────────────────────────────────────────────
COPY docker/php/php.ini /usr/local/etc/php/conf.d/piprapay.ini

# ── Application source ─────────────────────────────────────────────────────────
WORKDIR /var/www/html

COPY --chown=www-data:www-data . .

# Ensure writable directories have correct ownership and permissions.
# The install wizard checks these four directories for write access.
RUN mkdir -p pp-external/media \
    && chown -R www-data:www-data \
        invoice \
        payment \
        admin \
        pp-include \
        pp-external/media \
    && find /var/www/html -type d -exec chmod 755 {} + \
    && find /var/www/html -type f -exec chmod 644 {} + \
    && chmod 775 invoice payment admin pp-include pp-external/media

# ── Entrypoint ─────────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
