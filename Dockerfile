FROM wordpress:6.6-php8.3-apache
RUN apt-get update && apt-get install -y --no-install-recommends unzip curl ca-certificates jq && rm -rf /var/lib/apt/lists/*
WORKDIR /var/www/html
ARG BAKED_WP_PLUGINS=""
ENV BAKED_WP_PLUGINS=${BAKED_WP_PLUGINS}
RUN set -e; if [ -n "$BAKED_WP_PLUGINS" ]; then for spec in $BAKED_WP_PLUGINS; do slug="${spec%@*}"; ver="${spec#*@}"; test "$slug" != "$ver" || { echo "Falta @version en $spec"; exit 1; }; echo "Baking $slug@$ver"; curl -fsSL -o "/tmp/$slug.zip" "https://downloads.wordpress.org/plugin/${slug}.${ver}.zip"; unzip -q "/tmp/$slug.zip" -d wp-content/plugins; rm "/tmp/$slug.zip"; done; fi
RUN curl -fsSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp
RUN chown -R www-data:www-data /var/www/html
