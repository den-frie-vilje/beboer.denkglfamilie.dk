#!/bin/sh
# After a core upgrade, brings the marketplace modules to their releases for
# the new core. The upstream entrypoint only migrates the core and the module
# code already on disk; a module written for the previous core keeps calling
# what the new core removed (three modules broke the dashboard at 1.19,
# 2026-10-21). deploy/pre-start.sh leaves the marker when the version changed;
# by the time this runs the core is migrated, which is the order the
# marketplace needs, since it serves releases per core version. A marketplace
# that cannot be reached leaves the marker for the next start and does not
# stop the site.
MARKER=/var/www/localhost/htdocs/protected/config/.modules-need-update
[ -f "$MARKER" ] || exit 0
cd /var/www/localhost/htdocs/protected
if php yii module/update-all && php yii cache/flush-all; then
  rm -f "$MARKER"
else
  echo "20-update-modules: the module update did not complete; it runs again at the next start" >&2
fi
exit 0
