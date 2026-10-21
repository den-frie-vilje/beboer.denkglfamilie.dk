#!/bin/sh
# Refresh staging of beboer.denkglfamilie.dk from production, then neutralise
# everything that could reach a member. Run on the NAS as root:
#
#   sudo tools/refresh-staging.sh [intermediate phponly image ...]
#
# Any images given are run as a migration ladder (deploy/ladder.yml) between
# the copy and the start of staging's own version. Production keeps running;
# the database is dumped with a single transaction.
set -eu

DOMAIN=beboer.denkglfamilie.dk
ROOT=/volume1/docker/$DOMAIN
REPO=$ROOT/repo
STAGE_HOST=https://beboer-denkglfamilie-dk.stage.denfrievilje.dk/
P_ENV=$ROOT/production/production.env
S_ENV=$ROOT/staging/staging.env
read_var() { grep -E "^$2=" "$1" | cut -d= -f2- | tr -d '"'; }
P_DATA=$(read_var "$P_ENV" DATA_DIR)
S_DATA=$(read_var "$S_ENV" DATA_DIR)
[ -n "$P_DATA" ] && [ -n "$S_DATA" ] && [ "$P_DATA" != "$S_DATA" ] || { echo "DATA_DIR missing or identical in $P_ENV and $S_ENV" >&2; exit 1; }
prod() { docker compose -p beboer-denkglfamilie-dk-production -f "$REPO/deploy/compose.production.yml" --env-file "$P_ENV" "$@"; }
stage() { docker compose -p beboer-denkglfamilie-dk-staging -f "$REPO/deploy/compose.staging.yml" --env-file "$S_ENV" "$@"; }

echo "1/6 stopping staging"
stage down --remove-orphans

echo "2/6 dumping the production database"
mkdir -p "$S_DATA/db"
prod exec -T db sh -c 'mysqldump --single-transaction --quick -uroot -p"$MYSQL_ROOT_PASSWORD" humhub' > "$S_DATA/db/production.sql"

echo "3/6 copying files (uploads, config, modules, themes, assets)"
mkdir -p "$S_DATA/humhub"
rsync -a --delete "$P_DATA/humhub/" "$S_DATA/humhub/"

echo "4/6 recreating the staging database from the dump"
rm -rf "$S_DATA/db/data"
mkdir -p "$S_DATA/db/data"
stage up -d --wait db
stage exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" humhub' < "$S_DATA/db/production.sql"
rm -f "$S_DATA/db/production.sql"

for IMG in "$@"; do
  echo "5/6 migrating through $IMG"
  LADDER_IMAGE="$IMG" stage -f "$REPO/deploy/ladder.yml" run --rm humhub true
done

echo "6/6 neutralising the copy: mail to the catcher, push module removed, staging base URL"
stage run --rm humhub sh -c "
  php yii settings/set base mailerTransportType smtp &&
  php yii settings/set base mailerHostname mailer &&
  php yii settings/set base mailerPort 1025 &&
  php yii settings/set base mailerUsername '' &&
  php yii settings/set base mailerPassword '' &&
  php yii settings/set base mailerEncryption '' &&
  php yii settings/set base baseUrl $STAGE_HOST &&
  (php yii marketplace/remove fcm-push || true) &&
  php yii cache/flush"
stage up -d --wait
echo "staging is up on $STAGE_HOST"
