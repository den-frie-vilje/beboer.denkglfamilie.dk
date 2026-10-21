#!/bin/sh
# Rebuilds protected/config/common.php from the image's factory on every
# start, so Redis, cache, queue and the public host come from the compose
# environment and staging never carries production's hostname. The image
# regenerates the file only on a fresh install. The database settings live
# in dynamic.php, written by the installer, so nothing is lost. Runs after
# the entrypoint's migrations.
set -e
C=/var/www/localhost/htdocs/protected/config
{ printf '<?php return '; php /usr/src/humhub/protected/config/common-factory.php; printf ';\n'; } > "$C/common.php.new"
php -l "$C/common.php.new" > /dev/null
sed -i "s/'enablePjax' => false/'enablePjax' => true/" "$C/common.php.new"
mv "$C/common.php.new" "$C/common.php"
chown nginx:nginx "$C/common.php"
