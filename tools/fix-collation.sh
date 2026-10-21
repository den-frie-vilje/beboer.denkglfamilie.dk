#!/bin/sh
# Converts the database default and every table to utf8mb4_unicode_ci, the
# collation HumHub recommends. The database was created with MariaDB's old
# latin1_swedish_ci default and tables created by modules inherited it.
# Run against a stack whose database container is up and before HumHub
# migrates, because migrations create new tables with the database default.
# tools/refresh-staging.sh calls it at that point; the production window
# runs it by hand (README.md). Re-runnable: converts only what is left.
#
#   sudo tools/fix-collation.sh staging|production
set -eu
ENV_NAME=${1:?staging or production}
DOMAIN=beboer.denkglfamilie.dk
REPO=/volume1/docker/$DOMAIN/repo
dc() { docker compose -p beboer-denkglfamilie-dk-$ENV_NAME -f "$REPO/deploy/compose.$ENV_NAME.yml" --env-file "/volume1/docker/$DOMAIN/$ENV_NAME/$ENV_NAME.env" "$@"; }
sql() { dc exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B humhub'; }
not_utf8="SELECT table_name FROM information_schema.tables WHERE table_schema='humhub' AND table_type='BASE TABLE' AND table_collation<>'utf8mb4_unicode_ci'"

echo "ALTER DATABASE humhub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | sql
TABLES=$(echo "$not_utf8;" | sql)
if [ -n "$TABLES" ]; then
  { echo "SET FOREIGN_KEY_CHECKS=0;"
    for t in $TABLES; do echo "ALTER TABLE \`$t\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; done
    echo "SET FOREIGN_KEY_CHECKS=1;"; } | sql
  echo "converted: $(echo $TABLES)"
else
  echo "every table already utf8mb4_unicode_ci"
fi
LEFT=$(echo "SELECT COUNT(*) FROM ($not_utf8) t;" | sql)
echo "database default: $(echo 'SELECT @@collation_database;' | sql); tables not utf8mb4_unicode_ci: $LEFT"
[ "$LEFT" = 0 ]
