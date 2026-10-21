#!/bin/sh
# Entrypoint of the HumHub image: dumps the database before an upgrade
# migrates it, then hands over to the upstream entrypoint. The upstream
# entrypoint runs the migrations before anything in /docker-entrypoint.d,
# which is why this wraps it instead of living there. The dump lands beside
# the configuration it belongs to, in protected/config/backups, which is
# already mounted from the data directory (a new bind mount would need its
# source directory created on the NAS first). Restoring is in README.md,
# "Rollback".
set -eu
CONFIG=/var/www/localhost/htdocs/protected/config
INSTALLED=$(cat "$CONFIG/.version" 2>/dev/null || true)
SHIPPED=$(cat /usr/src/humhub/.version)
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$SHIPPED" ]; then
  SQL="$CONFIG/backups/humhub-$INSTALLED-before-$SHIPPED-$(date +%Y%m%dT%H%M%S).sql"
  echo "pre-start: dumping the $INSTALLED database to $SQL.gz before migrating to $SHIPPED"
  mkdir -p "$CONFIG/backups"
  until nc -z -w60 "${HUMHUB_DB_HOST:-db}" "${HUMHUB_DB_PORT:-3306}"; do sleep 2; done
  # --skip-ssl: the MariaDB 11 client insists on TLS by default; the database
  # is on the stack's private network.
  mariadb-dump --skip-ssl --single-transaction --quick -h "${HUMHUB_DB_HOST:-db}" -P "${HUMHUB_DB_PORT:-3306}" \
    -u "$HUMHUB_DB_USER" -p"$HUMHUB_DB_PASSWORD" "${HUMHUB_DB_NAME:-humhub}" > "$SQL" \
    || { echo "pre-start: the dump failed, not migrating" >&2; rm -f "$SQL"; exit 1; }
  grep -q '^-- Dump completed' "$SQL" || { echo "pre-start: the dump is incomplete, not migrating" >&2; exit 1; }
  gzip "$SQL"
  # Read by deploy/entrypoint.d/20-update-modules.sh once the core is migrated.
  touch "$CONFIG/.modules-need-update"
fi
exec /docker-entrypoint.sh "$@"
