#!/usr/bin/env bash
set -euo pipefail

: "${FLY_API_TOKEN:?Falta FLY_API_TOKEN}"
APP_STG="${APP_STG:-app-stg}"

fly apps create "$APP_STG" || true
fly deploy -a "$APP_STG" --remote-only --build-arg BAKED_WP_PLUGINS="$(tr '\n' ' ' < plugins.lock)"

fly secrets set -a "$APP_STG"   WORDPRESS_DB_HOST="mysql.host:3306"   WORDPRESS_DB_USER="wp_user"   WORDPRESS_DB_PASSWORD="********"   WORDPRESS_DB_NAME="wordpress_stg"   WP_URL="https://staging.tu-dominio.org"   WP_TITLE="Sitio (Staging)"   WP_ADMIN_USER="admin-stg"   WP_ADMIN_PASSWORD="********"   WP_ADMIN_EMAIL="ops@tu-dominio.org"

fly ssh console -a "$APP_STG" -C "bash -lc '
  set -e; cd /var/www/html
  command -v wp || (curl -fsSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp)
  for i in {1..30}; do php -r "@mysqli_connect(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD")) ?: exit(1);" && break || sleep 2; done
  wp core is-installed --allow-root || wp core install     --url="https://staging.tu-dominio.org" --title="Sitio (Staging)"     --admin_user="admin-stg" --admin_password="********" --admin_email="ops@tu-dominio.org"     --skip-email --allow-root
  wp plugin activate cloudflare offload-media-cloud-storage --allow-root || true
  wp option update blog_public 0 --allow-root
'"
echo "Staging desplegado: $APP_STG"
