#!/bin/sh
# Points the euro-office module at the document server on every start: the
# address from the compose file (OFFICE_URL) and the JWT secret from the file
# the document server's own stack reads
# (den-frie-vilje/onlyoffice.denfrievilje.dk, deploy/secrets.env.example), so
# the secret is kept in one place on the NAS. Written to the
# setting table, where the module reads them; HumHub's pinned settings cannot
# be used, since PHP-FPM clears the container's environment and a pin named
# in the .env file cannot address a module id with a hyphen
# (EnvHelper::keyToPath). Without the file, the address or the module, nothing
# is changed.
SECRETS=/run/office/office.env
cd /var/www/localhost/htdocs/protected
[ -f "$SECRETS" ] && [ -n "${OFFICE_URL:-}" ] && [ -d modules/euro-office ] || exit 0
. "$SECRETS"
[ -n "${JWT_SECRET:-}" ] || exit 0
# settings/set prints the value it stores; the secret stays out of the log.
php yii settings/set euro-office serverUrl "$OFFICE_URL" > /dev/null \
  && php yii settings/set euro-office jwtSecret "$JWT_SECRET" > /dev/null \
  && echo "30-office-settings: euro-office uses $OFFICE_URL" \
  || echo "30-office-settings: the document server settings were not written" >&2
exit 0
