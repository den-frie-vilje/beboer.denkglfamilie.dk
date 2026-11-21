#!/bin/sh
# Moves both Dockerfiles to the newest HumHub the organisation's image fork has
# built: den-frie-vilje/humhub-docker names it in versions.txt, and its Build
# workflow publishes ghcr.io/den-frie-vilje/humhub-<flavour>:<version> from
# main. Pins the digests GHCR serves, as tools/check-version.sh demands, and
# leaves the tree untouched when there is nothing newer or the images are not
# published yet. Run by .github/workflows/update-check.yml every day; needs
# docker and gh.
set -eu
cd "$(dirname "$0")/.."
IMAGE=ghcr.io/den-frie-vilje/humhub
CURRENT=$(sed -nE "s|^FROM $IMAGE-phponly:([0-9.]+)@.*|\1|p" deploy/Dockerfile.humhub)
NEWEST=$(gh api repos/den-frie-vilje/humhub-docker/contents/versions.txt --jq .content | base64 -d | tr -d '[:space:]')
[ -n "$CURRENT" ] && [ -n "$NEWEST" ] || { echo "bump-humhub: could not read the current ($CURRENT) or the fork's ($NEWEST) version" >&2; exit 1; }
if [ "$(printf '%s\n%s\n' "$CURRENT" "$NEWEST" | sort -V | tail -1)" = "$CURRENT" ]; then
  echo "bump-humhub: HumHub $CURRENT is the newest the fork has"
  exit 0
fi
for FLAVOUR in phponly nginx; do
  if ! DIGEST=$(docker buildx imagetools inspect "$IMAGE-$FLAVOUR:$NEWEST" --format '{{.Manifest.Digest}}' 2>/dev/null); then
    echo "bump-humhub: the fork names $NEWEST but $IMAGE-$FLAVOUR:$NEWEST is not published yet"
    git checkout -- deploy/Dockerfile.humhub deploy/Dockerfile.nginx
    exit 0
  fi
  [ $FLAVOUR = phponly ] && FILE=deploy/Dockerfile.humhub || FILE=deploy/Dockerfile.nginx
  sed -E -e "s|^FROM $IMAGE-$FLAVOUR:[0-9.]+@sha256:[0-9a-f]+|FROM $IMAGE-$FLAVOUR:$NEWEST@$DIGEST|" -e "1s|^# HumHub $CURRENT\\.|# HumHub $NEWEST.|" "$FILE" > "$FILE.new"
  mv "$FILE.new" "$FILE"
done
tools/check-version.sh HEAD
echo "bump-humhub: $CURRENT to $NEWEST"
