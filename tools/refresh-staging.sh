#!/bin/sh
# Refresh staging of beboer.denkglfamilie.dk from production, then neutralise
# everything that could reach a member. Run on the NAS as root:
#
#   sudo tools/refresh-staging.sh [intermediate phponly image ...]
#
# Any images given are run as a migration ladder (deploy/ladder.yml) between
# the copy and the start of staging's own version. A running production is
# dumped with a single transaction; a production that is not running (before
# the first cutover) has its database files copied as they are.
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
# Keep the agent away while the copy is half done: it starts any stack whose
# sites.d file exists and whose containers are down, and a half-copied
# staging would run with production's mail settings.
SITES_D=/volume1/docker/nas-sites/sites.d
AGENT_FILE=$SITES_D/$DOMAIN.staging.env
if [ -f "$AGENT_FILE" ]; then
  mv "$AGENT_FILE" "$AGENT_FILE.refreshing"
  trap 'mv "$AGENT_FILE.refreshing" "$AGENT_FILE"' EXIT
fi
prod() { docker compose -p beboer-denkglfamilie-dk-production -f "$REPO/deploy/compose.production.yml" --env-file "$P_ENV" "$@"; }
stage() { docker compose -p beboer-denkglfamilie-dk-staging -f "$REPO/deploy/compose.staging.yml" --env-file "$S_ENV" "$@"; }

echo "1/6 stopping staging"
stage down --remove-orphans

AT_REST=""
if [ -z "$(prod ps --quiet db 2>/dev/null)" ]; then
  AT_REST=1
  echo "2/6 production is not running: its database files are copied as they are"
  mkdir -p "$S_DATA/db"
else
  echo "2/6 dumping the production database"
  mkdir -p "$S_DATA/db"
  prod exec -T db sh -c 'mysqldump --single-transaction --quick -uroot -p"$MYSQL_ROOT_PASSWORD" humhub' > "$S_DATA/db/production.sql"
fi

echo "3/6 copying files (uploads, config, modules, themes, assets)"
mkdir -p "$S_DATA/humhub"
rsync -a --delete "$P_DATA/humhub/" "$S_DATA/humhub/"

if [ -n "$AT_REST" ]; then
  echo "4/6 copying the database files"
  rsync -a --delete "$P_DATA/db/data/" "$S_DATA/db/data/"
  stage up -d --wait db
  "$REPO/tools/fix-collation.sh" staging
else
  echo "4/6 recreating the staging database from the dump"
  rm -rf "$S_DATA/db/data"
  mkdir -p "$S_DATA/db/data"
  stage up -d --wait db
  stage exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" humhub' < "$S_DATA/db/production.sql"
  rm -f "$S_DATA/db/production.sql"
  "$REPO/tools/fix-collation.sh" staging
fi

for IMG in "$@"; do
  echo "5/6 migrating through $IMG, then updating the marketplace modules to that core"
  LADDER_IMAGE="$IMG" stage -f "$REPO/deploy/ladder.yml" run --rm humhub php yii module/update-all
done

echo "6/6 neutralising the copy: mail to the catcher, push module removed, staging base URL, modules updated"
stage run --rm humhub sh -c "
  php yii settings/set base mailerTransportType smtp &&
  php yii settings/set base mailerHostname mailer &&
  php yii settings/set base mailerPort 1025 &&
  php yii settings/set base mailerUsername '' &&
  php yii settings/set base mailerPassword '' &&
  php yii settings/set base mailerEncryption '' &&
  php yii settings/set base baseUrl $STAGE_HOST &&
  php yii module/remove fcm-push &&
  php yii module/remove theme-builder &&
  php yii module/update-all &&
  php yii cache/flush"
stage up -d --wait
echo "staging is up on $STAGE_HOST"
