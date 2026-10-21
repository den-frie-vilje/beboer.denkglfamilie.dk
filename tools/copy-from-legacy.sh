#!/bin/sh
# One-off: copy the site that runs today into production's canonical data
# directory, mapping the old layout onto the new one. Run on the NAS as root:
#
#   sudo tools/copy-from-legacy.sh              # files, while the old site runs
#   sudo tools/copy-from-legacy.sh --database   # also the database directory,
#                                               # after stopping its container
#
# Re-runnable: rsync --delete makes the copy match the source each time, so
# the final run in the service window carries everything written since.
# Nothing is started here.
set -eu

OLD=/volume1/docker/humhub
OLD_DB=/volume1/docker/humhub_db/data
OLD_DB_CONTAINER=humhub_db
NEW=$(grep -E '^DATA_DIR=' /volume1/docker/beboer.denkglfamilie.dk/production/production.env | cut -d= -f2- | tr -d '"')
[ -n "$NEW" ] || { echo "DATA_DIR missing in production.env" >&2; exit 1; }
case "$NEW" in /volume1/docker/beboer.denkglfamilie.dk/production/data) ;; *) echo "refusing: DATA_DIR is not the canonical path ($NEW)" >&2; exit 1;; esac

# DSM keeps thumbnail folders (@eaDir) beside indexed photos; they are not
# site data and are several times its size, so every copy leaves them out.
mkdir -p "$NEW/humhub" "$NEW/db"
echo "files: $OLD -> $NEW/humhub"
rsync -a --delete --exclude=@eaDir --exclude="#recycle" "$OLD/unprotected_uploads/"      "$NEW/humhub/uploads/"
rsync -a --delete --exclude=@eaDir --exclude="#recycle" "$OLD/modules/"  "$NEW/humhub/modules/"
rsync -a --delete --exclude=@eaDir --exclude="#recycle" "$OLD/themes/"   "$NEW/humhub/themes/"
rsync -a --delete --exclude=@eaDir --exclude="#recycle" "$OLD/config/"   "$NEW/humhub/config/"
# dynamic.php still carries 1.15-era component blocks (mailer with the
# netsite credentials, a Redis connection with a password the new stack's
# Redis does not have, cache, queue). HumHub 1.18 no longer writes them and
# the regenerated common.php supplies Redis, cache and queue; a stale mailer
# block would otherwise survive the merge with the mail settings.
for block in mailer redis cache queue; do
  sed -i "/^    '$block' => $/,/^    ),$/d" "$NEW/humhub/config/dynamic.php"
done
grep -q "'db' =>" "$NEW/humhub/config/dynamic.php" || { echo "dynamic.php lost its db block; stopping" >&2; exit 1; }

mkdir -p "$NEW/humhub/assets" "$NEW/humhub/php-pages"
# The Kongeligt theme painted the login page with its own background image;
# 1.18 retires the theme and has a built-in login background that lives at
# uploads/login-bg/background.png (HumHub's LoginBackgroundImageHelper).
mkdir -p "$NEW/humhub/uploads/login-bg"
cp "$OLD/themes/Kongeligt/img/login-bg.png" "$NEW/humhub/uploads/login-bg/background.png"
chown -R 100:101 "$NEW/humhub/uploads/login-bg"

if [ "${1:-}" = "--database" ]; then
  if /usr/local/bin/docker ps --format '{{.Names}}' | grep -qx "$OLD_DB_CONTAINER"; then
    echo "stop $OLD_DB_CONTAINER first; a running database cannot be copied consistently" >&2; exit 1
  fi
  echo "database: $OLD_DB -> $NEW/db/data"
  mkdir -p "$NEW/db/data"
  rsync -a --delete --exclude=@eaDir --exclude="#recycle" "$OLD_DB/" "$NEW/db/data/"
fi
du -sh "$NEW"
