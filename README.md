# README — Plataforma WordPress dockerizada con CI/CD, staging y producción (Fly.io + Cloudflare + R2)

## 0. Propósito

Este documento describe **cómo operar WordPress de forma reproducible y tolerante a fallos** usando:

- **Docker** (imagen con WordPress + plugins “horneados”).
- **Fly.io** (ejecución de contenedores; *staging* y *producción* como apps separadas).
- **Cloudflare** (CDN/WAF) + **plugin oficial** para **purga selectiva** tras publicar/actualizar.
- **Cloudflare R2** (S3-compatible) para **offload** de medios (*stateless*).
- **GitHub Actions** (CI/CD) con **despliegue automático** y **post-deploy** por **WP-CLI**.
- **Staging → Producción** por **merge** (pull request), **rollback** rápido con *releases* de Fly.

> **Decisión clave**: **NO** se instalan/actualizan plugins desde el panel de WP.  
> Todo cambio de código va en **Dockerfile** y se despliega por **CI/CD**.  
> En `wp-config.php` se debe fijar `DISALLOW_FILE_MODS` a `true`.

---

## 1. Arquitectura (resumen operativo)

- **Imagen Docker** basada en `wordpress:*`, que **incluye**:
  - **Cloudflare (oficial)**: purga de caché automática y gestión CDN.
  - **Offload Media – Cloud Storage**: sube medios a **R2** y sirve por CDN.
  - **WP-CLI** para operaciones de instalación, activación de plugins y tareas de mantenimiento.
- **Fly.io** ejecuta la imagen:
  - **App de staging** (`app-stg`), con **base de datos** y **bucket R2** propios.
  - **App de producción** (`app-prod`), con **base de datos** y **bucket R2** propios.
- **Cloudflare**:
  - DNS + CDN + WAF delante de ambas apps.
  - **Automatic Cache Management** activo en el plugin oficial → purga **selectiva** tras publicar.
- **R2 (S3)**:
  - Bucket independiente por entorno (p. ej. `media-staging`, `media-prod`).
  - Opción “eliminar del servidor tras subir” para no depender del disco del contenedor.
- **CI/CD (GitHub Actions)**:
  - **Build & Deploy** por rama: `staging` → *staging*, `main` → *producción*.
  - **Post-deploy**: WP-CLI instala (si primera vez), activa plugins y ejecuta tareas.
  - **Actualizaciones de plugins** por **versiones fijadas** en `plugins.lock` + job semanal que abre PR de bump.

---

## 2. Flujo de trabajo

1. **Desarrollo** → push a `staging`.  
   Se construye imagen, se despliega en *staging*, se activa/ajusta con WP-CLI.
2. **Validación** en *staging* (smoke tests, revisión visual).
3. **Promoción** → PR `staging` → `main` y **merge** cuando esté OK.
4. **Despliegue en producción** automático.  
   Post-deploy por WP-CLI, verificación, purga mínima si procede.
5. **Rollback** si es necesario con `fly releases revert`.

> **Contenido** (entradas/medios) **no fluye** de *staging* a *producción* salvo excepciones controladas (ver Anexo H).

---

## 3. Requisitos y secretos

- **Fly.io**
  - `FLY_API_TOKEN` (secret en GitHub).
  - Dos apps: `APP_STG` y `APP_PROD`.
- **Base de datos MySQL** (DBaaS o propia):
  - `WORDPRESS_DB_HOST`, `WORDPRESS_DB_USER`, `WORDPRESS_DB_PASSWORD`, `WORDPRESS_DB_NAME` (por entorno).
- **WordPress (instalación inicial)**:
  - `WP_URL`, `WP_TITLE`, `WP_ADMIN_USER`, `WP_ADMIN_PASSWORD`, `WP_ADMIN_EMAIL`.
- **Cloudflare (en el panel de WP)**:
  - API Token con permiso **Zone:Cache Purge** (se configura manualmente dentro de WP, no en CI).
- **R2**:
  - `Access Key` / `Secret Key` + `Endpoint` y `Bucket` (se configuran en el plugin de offload dentro de WP).

---

## 4. Buenas prácticas operativas

- **Plugins/tema**: siempre “horneados” en Docker; **prohibido** instalarlos por panel.  
- **Staging separado**: DB y R2 propios, sin indexar por buscadores.  
- **Cache**: delegar purga selectiva al plugin oficial de Cloudflare; purgas masivas solo ante cambios estructurales.  
- **Backups**: DB (dump SQL) antes de despliegues sensibles; inventario de R2 opcional.  
- **Observabilidad**: revisa logs, errores 5xx y TTFB tras cada despliegue.  
- **Seguridad**: `DISALLOW_FILE_MODS=true`, 2FA en paneles, tokens con mínimos privilegios.

---

## 5. Índice de anexos (scripts y plantillas)

- **Anexo A** — Estructura del repositorio  
- **Anexo B** — `Dockerfile` (WP + plugins horneados + WP-CLI)  
- **Anexo C** — `fly.toml` (plantilla)  
- **Anexo D** — CI/CD: `deploy-staging.yml` y `deploy-prod.yml`  
- **Anexo E** — Gestión de plugins con `plugins.lock` y job semanal de PR  
- **Anexo F** — Scripts de **preflight**, **rollback** y **purga opcional**  
- **Anexo G** — Alta rápida de **staging** (comandos)  
- **Anexo H** — **Promoción** *staging → producción* y excepciones de contenido  
- **Anexo I** — **Endurecimiento** de `wp-config.php` (bloquear mods y no indexar staging)

---

# ANEXOS

## Anexo A — Estructura del repositorio

```
/
├─ Dockerfile
├─ fly.toml
├─ plugins.lock
├─ .github/
│  └─ workflows/
│     ├─ deploy-staging.yml
│     ├─ deploy-prod.yml
│     └─ plugins-weekly-check.yml
├─ scripts/
│  ├─ release/
│  │  ├─ preflight.sh
│  │  ├─ rollback.sh
│  │  └─ cf_purge_urls.sh      # opcional (si no dependes solo del plugin CF)
│  └─ staging/
│     └─ bootstrap.sh
└─ README.md
```

---

## Anexo B — `Dockerfile` (WordPress + plugins horneados + WP-CLI)

```dockerfile
FROM wordpress:6.6-php8.3-apache

RUN apt-get update && apt-get install -y --no-install-recommends     unzip curl ca-certificates jq  && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html

# Plugins “horneados” por versión desde plugins.lock (pasadas como build-arg)
ARG BAKED_WP_PLUGINS=""
ENV BAKED_WP_PLUGINS=${BAKED_WP_PLUGINS}
RUN set -e;   if [ -n "$BAKED_WP_PLUGINS" ]; then     for spec in $BAKED_WP_PLUGINS; do       slug="${spec%@*}"; ver="${spec#*@}";       test "$slug" != "$ver" || { echo "Falta @version en $spec"; exit 1; } ;       echo "Baking $slug@$ver";       curl -fsSL -o "/tmp/$slug.zip" "https://downloads.wordpress.org/plugin/${slug}.${ver}.zip";       unzip -q "/tmp/$slug.zip" -d wp-content/plugins;       rm "/tmp/$slug.zip";     done;   fi

# WP-CLI disponible en runtime
RUN curl -fsSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar  && chmod +x /usr/local/bin/wp

# Permisos razonables
RUN chown -R www-data:www-data /var/www/html
```

> **Nota**: en `plugins.lock` fija versiones, p. ej.  
> ```
> cloudflare@4.13.2
> offload-media-cloud-storage@3.2.4
> ```

---

## Anexo C — `fly.toml` (plantilla)

```toml
app = "app-prod"            # cambia por app-stg para staging
primary_region = "mad"

[build]
  dockerfile = "Dockerfile"

[env]
  # Variables de entorno en runtime
  # DB y ajustes de instalación se inyectan como secrets con flyctl

[http_service]
  internal_port = 80
  force_https = true
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 1   # pon 2 si quieres zero-downtime con rolling

[[services]]
  protocol = "tcp"
  internal_port = 80
  processes = ["app"]
  [services.concurrency]
    type = "requests"
    soft_limit = 25
    hard_limit = 50
  [[services.ports]]
    port = 80
  [[services.ports]]
    port = 443
  [[services.tcp_checks]]
    interval = "15s"
    timeout = "2s"
```

---

## Anexo D — CI/CD (GitHub Actions)

### D.1 `deploy-staging.yml`

```yaml
name: Deploy Staging

on:
  push:
    branches: [ "staging" ]
  workflow_dispatch: {}

jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN_STG }}
      APP: app-stg
      WORDPRESS_DB_HOST: ${{ secrets.WORDPRESS_DB_HOST_STG }}
      WORDPRESS_DB_USER: ${{ secrets.WORDPRESS_DB_USER_STG }}
      WORDPRESS_DB_PASSWORD: ${{ secrets.WORDPRESS_DB_PASSWORD_STG }}
      WORDPRESS_DB_NAME: ${{ secrets.WORDPRESS_DB_NAME_STG }}
      WP_URL: ${{ secrets.WP_URL_STG }}
      WP_TITLE: ${{ secrets.WP_TITLE_STG }}
      WP_ADMIN_USER: ${{ secrets.WP_ADMIN_USER_STG }}
      WP_ADMIN_PASSWORD: ${{ secrets.WP_ADMIN_PASSWORD_STG }}
      WP_ADMIN_EMAIL: ${{ secrets.WP_ADMIN_EMAIL_STG }}

    steps:
      - uses: actions/checkout@v4

      - name: Build arg (plugins.lock)
        id: bake
        run: echo "BAKED=$(tr '\n' ' ' < plugins.lock)" >> $GITHUB_OUTPUT

      - name: Install Flyctl
        uses: superfly/flyctl-actions/setup-flyctl@v1

      - name: Deploy
        run: |
          flyctl deploy -a "$APP" --remote-only             --build-arg BAKED_WP_PLUGINS="${{ steps.bake.outputs.BAKED }}"

      - name: Push secrets
        run: |
          flyctl secrets set -a "$APP"             WORDPRESS_DB_HOST="$WORDPRESS_DB_HOST"             WORDPRESS_DB_USER="$WORDPRESS_DB_USER"             WORDPRESS_DB_PASSWORD="$WORDPRESS_DB_PASSWORD"             WORDPRESS_DB_NAME="$WORDPRESS_DB_NAME"             WP_URL="$WP_URL"             WP_TITLE="$WP_TITLE"             WP_ADMIN_USER="$WP_ADMIN_USER"             WP_ADMIN_PASSWORD="$WP_ADMIN_PASSWORD"             WP_ADMIN_EMAIL="$WP_ADMIN_EMAIL"

      - name: Post-deploy (install if first time + activate plugins)
        run: |
          sleep 10
          flyctl ssh console -a "$APP" -C "bash -lc '
            set -e
            cd /var/www/html
            command -v wp || (curl -fsSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp)
            for i in {1..30}; do php -r "@mysqli_connect(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD")) ?: exit(1);" && break || sleep 2; done
            wp core is-installed --allow-root || wp core install               --url="$WP_URL" --title="$WP_TITLE"               --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD"               --admin_email="$WP_ADMIN_EMAIL" --skip-email --allow-root
            # Activar plugins baked
            wp plugin activate cloudflare offload-media-cloud-storage --allow-root || true
            # Endurecer staging
            wp option update blog_public 0 --allow-root
          '"
```

### D.2 `deploy-prod.yml`

```yaml
name: Deploy Production

on:
  push:
    branches: [ "main" ]
  workflow_dispatch: {}

jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN_PROD }}
      APP: app-prod
      WORDPRESS_DB_HOST: ${{ secrets.WORDPRESS_DB_HOST_PROD }}
      WORDPRESS_DB_USER: ${{ secrets.WORDPRESS_DB_USER_PROD }}
      WORDPRESS_DB_PASSWORD: ${{ secrets.WORDPRESS_DB_PASSWORD_PROD }}
      WORDPRESS_DB_NAME: ${{ secrets.WORDPRESS_DB_NAME_PROD }}
      WP_URL: ${{ secrets.WP_URL_PROD }}
      WP_TITLE: ${{ secrets.WP_TITLE_PROD }}
      WP_ADMIN_USER: ${{ secrets.WP_ADMIN_USER_PROD }}
      WP_ADMIN_PASSWORD: ${{ secrets.WP_ADMIN_PASSWORD_PROD }}
      WP_ADMIN_EMAIL: ${{ secrets.WP_ADMIN_EMAIL_PROD }}

    steps:
      - uses: actions/checkout@v4

      - name: Build arg (plugins.lock)
        id: bake
        run: echo "BAKED=$(tr '\n' ' ' < plugins.lock)" >> $GITHUB_OUTPUT

      - name: Install Flyctl
        uses: superfly/flyctl-actions/setup-flyctl@v1

      - name: Deploy
        run: |
          flyctl deploy -a "$APP" --remote-only             --build-arg BAKED_WP_PLUGINS="${{ steps.bake.outputs.BAKED }}"

      - name: Push secrets
        run: |
          flyctl secrets set -a "$APP"             WORDPRESS_DB_HOST="$WORDPRESS_DB_HOST"             WORDPRESS_DB_USER="$WORDPRESS_DB_USER"             WORDPRESS_DB_PASSWORD="$WORDPRESS_DB_PASSWORD"             WORDPRESS_DB_NAME="$WORDPRESS_DB_NAME"             WP_URL="$WP_URL"             WP_TITLE="$WP_TITLE"             WP_ADMIN_USER="$WP_ADMIN_USER"             WP_ADMIN_PASSWORD="$WP_ADMIN_PASSWORD"             WP_ADMIN_EMAIL="$WP_ADMIN_EMAIL"

      - name: Post-deploy (activate baked plugins + db updates)
        run: |
          sleep 10
          flyctl ssh console -a "$APP" -C "bash -lc '
            set -e
            cd /var/www/html
            command -v wp || (curl -fsSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp)
            for i in {1..30}; do php -r "@mysqli_connect(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD")) ?: exit(1);" && break || sleep 2; done
            wp core is-installed --allow-root || wp core install               --url="$WP_URL" --title="$WP_TITLE"               --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD"               --admin_email="$WP_ADMIN_EMAIL" --skip-email --allow-root
            wp plugin activate cloudflare offload-media-cloud-storage --allow-root || true
            wp core update-db --allow-root || true
          '"
```

---

## Anexo E — Job semanal (`plugins-weekly-check.yml`)

```yaml
name: Check WP plugin updates
on:
  schedule: [{ cron: "0 6 * * 1" }]
  workflow_dispatch: {}

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq curl
      - name: Bump plugins.lock
        run: |
          set -e
          TMP=plugins.lock.new
          > "$TMP"
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            slug="${line%@*}"; cur="${line#*@}"
            latest=$(curl -fsS "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request[slug]=$slug" | jq -r '.version')
            [ -n "$latest" ] || { echo "No version for $slug"; exit 1; }
            if [ "$latest" != "$cur" ]; then
              echo "$slug@$latest" >> "$TMP"
            else
              echo "$line" >> "$TMP"
            fi
          done < plugins.lock
          if ! cmp -s plugins.lock "$TMP"; then mv "$TMP" plugins.lock; else exit 0; fi
      - uses: peter-evans/create-pull-request@v6
        with:
          commit-message: "chore(wp): bump plugins.lock"
          title: "Bump WordPress plugins"
          body: "Actualiza versiones de plugins."
          branch: chore/bump-wp-plugins
```

---

## Anexo F — Scripts

### F.1 `scripts/release/preflight.sh`
```bash
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
```

### F.2 `scripts/release/rollback.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${APP_PROD:-app-prod}"
echo "Releases recientes:"
fly releases -a "$APP" | head -n 8
read -rp "Version a revertir (VERSION_ID): " V
fly releases revert -a "$APP" "$V"
```

### F.3 `scripts/release/cf_purge_urls.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
: "${CF_ZONE_ID:?Falta CF_ZONE_ID}"
: "${CF_API_TOKEN:?Falta CF_API_TOKEN}"
readarray -t URLS < <( if [ $# -gt 0 ]; then printf "%s
" "$@"; else cat -; fi   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^https?://' || true)
mapfile -t URLS < <(printf "%s
" "${URLS[@]}" | awk '!x[$0]++')
chunk(){ arr=("$@"); payload=$(printf '%s
' "${arr[@]}" | jq -R . | jq -s '{files: .}');
  curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache"     -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json"     --data "$payload" | jq -e '.success == true' >/dev/null; echo "Purged ${#arr[@]} URL(s)"; }
buf=(); c=0; for u in "${URLS[@]}"; do buf+=("$u"); ((c++)); if ((c==30)); then chunk "${buf[@]}"; buf=(); c=0; fi; done
((c>0)) && chunk "${buf[@]}"; echo "OK"
```

---

## Anexo G — `scripts/staging/bootstrap.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

: "${FLY_API_TOKEN:?Falta FLY_API_TOKEN}"
APP_STG="${APP_STG:-app-stg}"

# Crear app y desplegar
fly apps create "$APP_STG" || true
fly deploy -a "$APP_STG" --remote-only   --build-arg BAKED_WP_PLUGINS="$(tr '
' ' ' < plugins.lock)"

# Secrets (ajusta valores antes de ejecutar)
fly secrets set -a "$APP_STG"   WORDPRESS_DB_HOST="mysql.host:3306"   WORDPRESS_DB_USER="wp_user"   WORDPRESS_DB_PASSWORD="********"   WORDPRESS_DB_NAME="wordpress_stg"   WP_URL="https://staging.tu-dominio.org"   WP_TITLE="Sitio (Staging)"   WP_ADMIN_USER="admin-stg"   WP_ADMIN_PASSWORD="********"   WP_ADMIN_EMAIL="ops@tu-dominio.org"

# Post-deploy inicial
fly ssh console -a "$APP_STG" -C "bash -lc '
  set -e; cd /var/www/html
  command -v wp || (curl -fsSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp)
  for i in {1..30}; do php -r "@mysqli_connect(getenv("WORDPRESS_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD")) ?: exit(1);" && break || sleep 2; done
  wp core is-installed --allow-root || wp core install     --url="https://staging.tu-dominio.org" --title="Sitio (Staging)"     --admin_user="admin-stg" --admin_password="********" --admin_email="ops@tu-dominio.org"     --skip-email --allow-root
  wp plugin activate cloudflare offload-media-cloud-storage --allow-root || true
  wp option update blog_public 0 --allow-root
'"
echo "Staging desplegado: $APP_STG"
```

---

## Anexo H — Promoción (resumen)

- PR `staging` → `main` → despliegue prod.
- Rollback con `fly releases revert -a app-prod <VERSION_ID>`.

---

## Anexo I — `wp-config.php` (endurecimiento)

```php
define('DISALLOW_FILE_MODS', true);
if (strpos($_SERVER['HTTP_HOST'] ?? '', 'staging.') === 0) {
  define('DISALLOW_INDEXING', true);
}
```

---

## Nota rápida — Cargar *secrets* de GitHub por script

Usa **GitHub CLI** (`gh`) y el script incluido:

```bash
# 1) Rellena y guarda tus ficheros .secrets.*.env a partir de los .example
cp .secrets.staging.env.example .secrets.staging.env
cp .secrets.prod.env.example .secrets.prod.env
# (edita valores)

# 2) Sube secrets al repositorio (sustituye owner/repo)
./scripts/ci/gh_set_secrets.sh owner/repo .secrets.staging.env
./scripts/ci/gh_set_secrets.sh owner/repo .secrets.prod.env
```

> Requiere haber hecho `gh auth login` previamente.
