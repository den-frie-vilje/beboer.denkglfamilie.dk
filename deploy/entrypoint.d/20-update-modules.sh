#!/bin/sh
# Brings the marketplace modules to their releases for this core, after a
# core upgrade and when the tested module list in the image has changed. The
# upstream entrypoint only migrates the core and the module code already on
# disk; a module written for the previous core keeps calling what the new core
# removed (three modules broke the dashboard at 1.19, 2026-10-21).
# deploy/pre-start.sh leaves the marker when the version changed; by the time
# this runs the core is migrated, which is the order the marketplace needs,
# since it serves releases per core version. The list is deploy/modules.txt
# with the versions tools/test-modules.sh passed with, copied into the image
# by deploy/Dockerfile.humhub; the copy applied last sits beside the
# configuration. A marketplace that cannot be reached leaves both for the
# next start and does not stop the site.
CONFIG=/var/www/localhost/htdocs/protected/config
MARKER=$CONFIG/.modules-need-update
TESTED=/usr/local/share/humhub-modules.txt
APPLIED=$CONFIG/.modules-applied
if [ ! -f "$MARKER" ] && cmp -s "$TESTED" "$APPLIED"; then
  exit 0
fi
cd /var/www/localhost/htdocs/protected
if php yii module/update-all && php yii cache/flush-all; then
  rm -f "$MARKER"
  cp "$TESTED" "$APPLIED"
else
  echo "20-update-modules: the module update did not complete; it runs again at the next start" >&2
fi
exit 0
