#!/bin/sh
# Checks a HumHub version bump, in CI before an image is built and signed:
# both Dockerfiles name the same version, each pinned digest is what Docker Hub
# serves for that tag, the phponly image really carries that version, and the
# bump skips no minor version, which HumHub advises against
# (docs.humhub.org/docs/admin/updating: "an update from e.g. 1.3 to 1.5 should
# be done in two steps"). Needs docker.
#
#   tools/check-version.sh [<git ref of the version to compare against>]
set -eu
cd "$(dirname "$0")/.."
fail() { echo "check-version: $*" >&2; exit 1; }
pinned() { sed -nE "s|^FROM docker.io/jeremyvies/humhub:([0-9.]+)-$1@(sha256:[0-9a-f]{64})$|\1 \2|p"; }
BASE=${1:-}
set -- $(pinned phponly < deploy/Dockerfile.humhub) $(pinned nginx < deploy/Dockerfile.nginx)
[ $# -eq 4 ] || fail "could not read a pinned 'FROM docker.io/jeremyvies/humhub:<version>-<flavour>@sha256:...' line from both Dockerfiles"
VERSION=$1 PHP_DIGEST=$2 NGINX_VERSION=$3 NGINX_DIGEST=$4
[ "$VERSION" = "$NGINX_VERSION" ] || fail "Dockerfile.humhub is $VERSION but Dockerfile.nginx is $NGINX_VERSION"

for FLAVOUR in phponly nginx; do
  [ $FLAVOUR = phponly ] && WANT=$PHP_DIGEST || WANT=$NGINX_DIGEST
  SERVED=$(docker buildx imagetools inspect "docker.io/jeremyvies/humhub:$VERSION-$FLAVOUR" --format '{{.Manifest.Digest}}')
  [ "$SERVED" = "$WANT" ] || fail "tag $VERSION-$FLAVOUR is $SERVED on Docker Hub, the Dockerfile pins $WANT"
done
INSIDE=$(docker run --rm --entrypoint cat "docker.io/jeremyvies/humhub:$VERSION-phponly@$PHP_DIGEST" /usr/src/humhub/.version | tr -d 'v[:space:]')
[ "$INSIDE" = "$VERSION" ] || fail "the image tagged $VERSION-phponly contains HumHub $INSIDE"

if [ -n "$BASE" ] && git cat-file -e "$BASE:deploy/Dockerfile.humhub" 2>/dev/null; then
  set -- $(git show "$BASE:deploy/Dockerfile.humhub" | pinned phponly)
  OLD=$1
  [ "$(printf '%s\n%s\n' "$OLD" "$VERSION" | sort -V | head -1)" = "$OLD" ] || fail "$VERSION is older than $OLD on $BASE"
  [ "${OLD%%.*}" = "${VERSION%%.*}" ] || fail "$OLD to $VERSION changes the major version; that is a project, not a bump"
  OLD_MINOR=$(echo "$OLD" | cut -d. -f2); NEW_MINOR=$(echo "$VERSION" | cut -d. -f2)
  [ $((NEW_MINOR - OLD_MINOR)) -le 1 ] || fail "$OLD to $VERSION skips a minor version; HumHub wants one minor at a time"
  echo "check-version: $OLD on $BASE to $VERSION"
fi
echo "check-version: HumHub $VERSION, both images pinned to the digests Docker Hub serves, image content matches"
