#!/usr/bin/env bash
set -euo pipefail
APP_STG="${APP_STG:-app-stg}"
curl -fsS https://staging.tu-dominio.org/ >/dev/null
fly ssh console -a "$APP_STG" -C "bash -lc '
  set -e; cd /var/www/html
  command -v wp || (curl -fsSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp)
  wp core is-installed --allow-root
  wp plugin list --allow-root | sed -n "1,20p"
'"
echo "Preflight OK"
