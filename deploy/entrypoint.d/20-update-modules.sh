#!/bin/sh
# Brings the marketplace modules to the list the image carries: installs and
# enables a module the list names that is not on disk, and updates them all
# after a core upgrade and whenever the list changes. The upstream entrypoint
# only migrates the core and the module code already on disk; a module written
# for the previous core keeps calling what the new core removed (three modules
# broke the dashboard at 1.19, 2026-10-21). deploy/pre-start.sh leaves the
# marker when the version changed; by the time this runs the core is migrated,
# which is the order the marketplace needs, since it serves releases per core
# version. The list is deploy/modules.txt with the versions
# tools/test-modules.sh passed with, copied into the image by
# deploy/Dockerfile.humhub; the copy applied last sits beside the
# configuration. A line "-id" in the list removes that module, files, tables
# and settings, after the installs; a module merely dropped from the list stays on disk. A marketplace that cannot be
# reached leaves marker and list for the next start and does not stop the site.
CONFIG=/var/www/localhost/htdocs/protected/config
MARKER=$CONFIG/.modules-need-update
TESTED=/usr/local/share/humhub-modules.txt
APPLIED=$CONFIG/.modules-applied
if [ ! -f "$MARKER" ] && cmp -s "$TESTED" "$APPLIED"; then
  exit 0
fi
cd /var/www/localhost/htdocs/protected
ok=true
for m in $(grep -vE '^[[:space:]]*(#|-|$)' "$TESTED" | cut -d' ' -f1); do
  [ -d "modules/$m" ] && continue
  php yii module/install "$m" && php yii module/enable "$m" || ok=false
done
# euro-office reads the onlyoffice module's connection settings only while it
# has none of its own and stores them when an administrator saves its form
# (euro-office models/Configuration.php, loadFromOnlyOfficeSettings); removing
# onlyoffice deletes them. So they are stored under euro-office first, with
# the module's own mapping and conditions.
if [ -d modules/onlyoffice ] && [ -d modules/euro-office ]; then
  # --skip-ssl: as in deploy/pre-start.sh.
  mariadb --skip-ssl -h "${HUMHUB_DB_HOST:-db}" -P "${HUMHUB_DB_PORT:-3306}" \
    -u "$HUMHUB_DB_USER" -p"$HUMHUB_DB_PASSWORD" "${HUMHUB_DB_NAME:-humhub}" <<'SQL' || ok=false
REPLACE INTO setting (name, value, module_id)
SELECT IF(o.name = 'storageUrl', 'humhubUrl', o.name), o.value, 'euro-office'
FROM setting o
WHERE o.module_id = 'onlyoffice' AND o.value <> ''
  AND o.name IN ('serverUrl', 'internalServerUrl', 'storageUrl', 'jwtSecret', 'jwtHeader', 'verifyPeerOff')
  AND NOT EXISTS (SELECT 1 FROM setting e WHERE e.module_id = 'euro-office' AND e.name = 'serverUrl' AND e.value <> '')
  AND NOT EXISTS (SELECT 1 FROM setting d WHERE d.module_id = 'onlyoffice' AND d.name = 'demoServer' AND d.value NOT IN ('', '0'));
SQL
fi
# Removals come last and only when everything above succeeded, so a module is
# never removed before its replacement is in place.
if $ok; then
  for m in $(sed -nE 's/^-([a-z0-9_-]+).*/\1/p' "$TESTED"); do
    [ -d "modules/$m" ] || continue
    php yii module/remove "$m" || ok=false
  done
fi
if $ok && php yii module/update-all && php yii cache/flush-all; then
  rm -f "$MARKER"
  cp "$TESTED" "$APPLIED"
else
  echo "20-update-modules: the module update did not complete; it runs again at the next start" >&2
fi
exit 0
