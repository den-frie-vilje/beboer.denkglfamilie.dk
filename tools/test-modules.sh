#!/bin/sh
# Proves that the HumHub image built from this repository still carries the
# community's marketplace modules: brings deploy/compose.test.yml up on an
# empty database, signs in as the test administrator, installs and enables
# every module in deploy/modules.txt through the marketplace the way an
# administrator does, then renders the pages the modules take part in. Runs
# on a pull request (.github/workflows/test-modules.yml) and anywhere with
# Docker: tools/test-modules.sh. Exit 0 is a pass; the stack is removed either
# way, and a failure prints the container log first.
set -eu
cd "$(dirname "$0")/.."

compose() { docker compose -f deploy/compose.test.yml "$@"; }
# The console runs as the web user so the files it writes stay writable for
# the web application.
yii() { compose exec -T -u nginx -w /var/www/localhost/htdocs/protected humhub php yii "$@"; }

URL=http://127.0.0.1:18080
JAR=$(mktemp)
BODY=$(mktemp)
finish() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- last response, error lines"
    sed -e 's/<[^>]*>//g' "$BODY" | grep -iE 'error|exception' | head -20 || true
    echo "--- humhub container log, last 100 lines"
    compose logs --no-color --tail 100 humhub || true
  fi
  compose down -v --remove-orphans > /dev/null 2>&1 || true
  rm -f "$JAR" "$BODY"
  exit "$status"
}
trap finish EXIT
fail() { echo "FAIL: $*"; exit 1; }

# Prints the status code; the body lands in $BODY.
page() { curl -sS -o "$BODY" --max-time 120 -b "$JAR" -c "$JAR" -w '%{http_code}' "$@"; }
# The CSRF token of the page in $BODY; Yii issues a new one at sign-in.
token() { grep -oE 'name="csrf-token" content="[^"]+"' "$BODY" | cut -d'"' -f4; }

echo "1/4 building the images and installing HumHub on an empty database"
compose up -d --build --wait --wait-timeout 900

echo "2/4 signing in as the test administrator"
# Sign-in is two steps since 1.19: the username, then the password
# (humhub/modules/user/controllers/AuthController.php, actionLogin and actionPassword).
page "$URL/user/auth/login" > /dev/null
code=$(page "$URL/user/auth/login" --data-urlencode "_csrf=$(token)" --data-urlencode 'Login[username]=admin')
[ "$code" = 302 ] || fail "the username step answered $code"
page "$URL/user/auth/password" > /dev/null
code=$(page "$URL/user/auth/password" --data-urlencode "_csrf=$(token)" --data-urlencode 'Login[password]=test-modules')
[ "$code" = 302 ] || fail "the password step answered $code"
code=$(page "$URL/dashboard")
[ "$code" = 200 ] || fail "the dashboard answered $code after sign-in"
CSRF=$(token)

echo "3/4 installing and enabling the modules in deploy/modules.txt"
# Through the marketplace pages rather than the console: the console
# installer runs without third-party modules loaded, and a module whose
# requirements.php looks one up (external_calendar needs calendar) fails there.
# The marketplace is asked first, as HumHub asks it (HumHubApiClient sends
# the core version): a paid module downloads only with the licence production
# holds, so it is reported and left out; a module without a release for this
# core is the failure this test exists for.
VERSION=$(compose exec -T humhub cat /usr/src/humhub/.version | tr -d 'v[:space:]')
MODULES=$(grep -vE '^[[:space:]]*(#|$)' deploy/modules.txt)
INSTALLED=""
MISSING=""
for m in $MODULES; do
  INFO=$(curl -sS --max-time 60 "https://api.humhub.com/v1/modules/info?id=$m&version=$VERSION&installId=test")
  case "$INFO" in
    *'"isPaid":true'*) echo "  paid $m downloads only with the licence; not installed in the test"; continue ;;
    *'"latestCompatibleVersion":{'*) ;;
    *) echo "  NONE $m has no release for HumHub $VERSION"; MISSING="$MISSING $m"; continue ;;
  esac
  for action in install enable; do
    code=$(page "$URL/marketplace/browse/$action" --data-urlencode "_csrf=$CSRF" --data-urlencode "moduleId=$m")
    [ "$code" = 200 ] || fail "$action of $m answered $code"
  done
  echo "  $m installed and enabled"
  INSTALLED="$INSTALLED $m"
done
LIST=$(yii module/list)
echo "$LIST"
for m in $INSTALLED; do
  echo "$LIST" | grep -qE "^  $m +enabled " || fail "$m is not enabled"
done
# The marketplace serves releases per core version; every module must be at
# the release it serves for this core, and the integrity check must pass.
yii module/update-all
yii integrity/run

echo "4/4 rendering the pages and reading the application log"
# A page passes with 200 and no error page in the body. A module without a
# page of its own answers 404 to every candidate path; that is reported, not
# failed, since the module's widgets are rendered by the pages below.
render() {
  code=$(page "$URL$1")
  case "$code" in
    200) grep -q 'An internal server error occurred' "$BODY" && fail "$1 rendered the error page"; echo "  200 $1"; return 0 ;;
    404) return 1 ;;
    *) fail "$1 answered $code" ;;
  esac
}
for p in /dashboard /people /spaces /admin/module/list; do
  render "$p" || fail "$p answered 404"
done
# /admin/module/list is the module manager; it names every installed module.
for m in $INSTALLED; do
  grep -q "moduleId=$m\b" "$BODY" || fail "the module manager does not list $m"
done
for m in $INSTALLED; do
  for p in /$m/admin /$m/config /$m/global /$m/index; do
    render "$p" && break
  done || echo "  none $m has no page of its own"
done
ERRORS=$(compose exec -T humhub sh -c 'cat protected/runtime/logs/app.log 2>/dev/null' | grep -E '\[error\]' || true)
[ -z "$ERRORS" ] || { echo "$ERRORS"; fail "errors in protected/runtime/logs/app.log"; }

# Reported last so one run shows everything else as well.
[ -z "$MISSING" ] || fail "the marketplace has no release for HumHub $VERSION of:$MISSING"
echo "PASS: $(echo "$INSTALLED" | wc -w | tr -d ' ') modules installed, enabled and rendering"
