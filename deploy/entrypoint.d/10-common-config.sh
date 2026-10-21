#!/bin/sh
# Rebuilds protected/config/common.php on every start from two sources:
# the image's factory (Redis, cache, queue and the public host from the compose
# environment) and deploy/common.site.php from the repository, merged over it,
# which holds the site's own PHP configuration such as closures that no
# environment variable can carry. Hand edits to common.php do not survive a
# start; they go in common.site.php. The database settings live in
# dynamic.php, written by the installer, and are untouched. Scalar HumHub
# configuration and pinned settings come from the site's .env file
# (deploy/humhub.<env>.env), which HumHub reads itself. Runs after the
# entrypoint's migrations.
set -e
C=/var/www/localhost/htdocs/protected/config
{
  printf '<?php\n$common = '
  php /usr/src/humhub/protected/config/common-factory.php
  printf ';\n$site = __DIR__ . "/common.site.php";\nreturn is_file($site) ? \\yii\\helpers\\ArrayHelper::merge($common, require $site) : $common;\n'
} > "$C/common.php.new"
php -l "$C/common.php.new" > /dev/null
sed -i "s/'enablePjax' => false/'enablePjax' => true/" "$C/common.php.new"
mv "$C/common.php.new" "$C/common.php"
chown nginx:nginx "$C/common.php"
