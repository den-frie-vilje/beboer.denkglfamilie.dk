#!/bin/sh
# Proves that the HumHub image built from this repository still carries the
# community's marketplace modules: brings deploy/compose.test.yml up on an
# empty database, signs in as the test administrator, installs and enables
# every module in deploy/modules.txt through the marketplace the way an
# administrator does, renders the pages the modules take part in, and runs
# the unit and functional tests each module ships. A table at the end says
# how every module fared; on GitHub it is the job summary. Runs on a pull
# request (.github/workflows/test-modules.yml), every day against the newest
# releases (.github/workflows/update-check.yml) and anywhere with Docker:
# tools/test-modules.sh. Exit 0 is a pass, and a pass writes the module
# versions it ran with into deploy/modules.txt; the stack is removed either
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
ROWS=$(mktemp)
finish() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- last response, error lines"
    sed -e 's/<[^>]*>//g' "$BODY" | grep -iE 'error|exception' | head -20 || true
    echo "--- humhub container log, last 100 lines"
    compose logs --no-color --tail 100 humhub || true
  fi
  compose down -v --remove-orphans > /dev/null 2>&1 || true
  rm -f "$JAR" "$BODY" "$ROWS"
  exit "$status"
}
trap finish EXIT
fail() { echo "FAIL: $*"; exit 1; }

# Prints the status code; the body lands in $BODY.
page() { curl -sS -o "$BODY" --max-time 120 -b "$JAR" -c "$JAR" -w '%{http_code}' "$@"; }
# The CSRF token of the page in $BODY; Yii issues a new one at sign-in.
token() { grep -oE 'name="csrf-token" content="[^"]+"' "$BODY" | cut -d'"' -f4; }
# One line of the table per module: id|version|installed|unit|functional.
row() { echo "$1|$2|$3|$4|$5" >> "$ROWS"; }

echo "1/5 building the images and installing HumHub on an empty database"
compose up -d --build --wait --wait-timeout 900

echo "2/5 signing in as the test administrator"
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

echo "3/5 installing and enabling the modules in deploy/modules.txt"
# Through the marketplace pages rather than the console: the console
# installer runs without third-party modules loaded, and a module whose
# requirements.php looks one up (external_calendar needs calendar) fails there.
# The marketplace is asked first, as HumHub asks it (HumHubApiClient sends
# the core version): a paid module downloads only with the licence production
# holds, so it is reported and left out; a module without a release for this
# core is the failure this test exists for.
VERSION=$(compose exec -T humhub cat /usr/src/humhub/.version | tr -d 'v[:space:]')
MODULES=$(grep -vE '^[[:space:]]*(#|$)' deploy/modules.txt | cut -d' ' -f1)
INSTALLED=""
MISSING=""
for m in $MODULES; do
  INFO=$(curl -sS --max-time 60 "https://api.humhub.com/v1/modules/info?id=$m&version=$VERSION&installId=test")
  case "$INFO" in
    *'"isPaid":true'*) echo "  paid $m downloads only with the licence; not installed in the test"; row "$m" "" "paid, outside the test" "" ""; continue ;;
    *'"latestCompatibleVersion":{'*) ;;
    *) echo "  NONE $m has no release for HumHub $VERSION"; MISSING="$MISSING $m"; row "$m" "" "NO RELEASE for $VERSION" "" ""; continue ;;
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
LIST=$(yii module/list)
version() { echo "$LIST" | awk -v m="$1" '$1 == m { print $3 }'; }

echo "4/5 rendering the pages and reading the application log"
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
ERRORS=$(compose exec -T humhub sh -c 'cat /var/www/localhost/htdocs/protected/runtime/logs/app.log' | grep -E '\[error\]' || true)
[ -z "$ERRORS" ] || { echo "$ERRORS"; fail "errors in protected/runtime/logs/app.log"; }

echo "5/5 running the unit and functional tests the modules ship"
# Most marketplace modules ship Codeception suites, and the image carries
# HumHub's test harness (protected/humhub/tests, index-test.php) but not the
# development packages the suites load, so the throwaway container gets them:
# composer and the tokenizer from Alpine, the dev packages from HumHub's own
# composer.lock. The harness expects a humhub_test database on 127.0.0.1 as
# root (tests/config/common.php); the env file it merges last
# (tests/codeception/config/config.php) points it at the db service. The
# steps are those of humhub/module-coding-standards
# .github/workflows/codeception-base.yml: migrate, installer/auto, codecept
# build, then each module's suites. A module is enabled in the test database
# first, since migrate/up only covers enabled modules
# (humhub/commands/MigrateController.php). Acceptance suites drive Chrome
# through Selenium and are left out. The module code is never touched: a
# failing suite is the module's state on this core, and the daily run tries
# the next release until it passes.
compose exec -T humhub apk add --no-cache -q composer php85-tokenizer
compose exec -T -u nginx -w /var/www/localhost/htdocs humhub composer install --no-interaction --no-progress --quiet
compose exec -T db mariadb -uroot -proot -e 'CREATE DATABASE humhub_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'
compose exec -T humhub sh -c 'cat > /var/www/localhost/htdocs/protected/humhub/tests/config/env/env.php' <<'PHP'
<?php
return ['components' => ['db' => ['dsn' => 'mysql:host=db;dbname=humhub_test', 'username' => 'root', 'password' => 'root']]];
PHP
harness() { compose exec -T -u nginx -w /var/www/localhost/htdocs/protected/humhub/tests/codeception/bin humhub php yii "$@"; }
harness migrate/up --includeModuleMigrations=1 --interactive=0 | tail -1
harness installer/auto | tail -1
compose exec -T -u nginx -w /var/www/localhost/htdocs/protected/humhub/tests humhub php ../../vendor/bin/codecept build --no-interaction | tail -1
FAILED=""
# Runs one suite and prints its cell for the table.
suite() {
  # A suite unloads its fixtures when it ends and leaves the setting table
  # empty, and the installed state is a setting row (InstallationState::setState),
  # read once when the suite's application boots; without it the suite gets
  # the installer page. The installer commands cannot write it again (the
  # admin and the profile fields exist), so the row is put back directly.
  compose exec -T db mariadb -uroot -proot humhub_test -e "INSERT IGNORE INTO setting (module_id, name, value) VALUES ('base', 'humhub\\\\components\\\\InstallationState', '3')"
  harness cache/flush-all > /dev/null
  out=$(compose exec -T -u nginx -w "/var/www/localhost/htdocs/protected/modules/$1/tests" humhub php /var/www/localhost/htdocs/protected/vendor/bin/codecept run "$2" --no-interaction --no-colors 2>&1) || true
  case "$out" in
    *"No tests executed"*|*"could not be found"*) echo "none"; return ;;
  esac
  tests=$(echo "$out" | grep -oE '(OK \(|Tests: )[0-9]+' | tail -1 | grep -oE '[0-9]+$')
  bad=$(( $(echo "$out" | grep -oE '(Failures|Errors): [0-9]+' | grep -oE '[0-9]+' | paste -sd+ - | sed -e 's/^$/0/') ))
  [ -n "$tests" ] || { echo "$out" | tail -40 >&2; echo "FAIL, did not run"; return; }
  if [ "$bad" -gt 0 ]; then
    echo "$out" | grep -vE '^\s*#[0-9]+ ' | grep -A6 -E '^[0-9]+\) ' >&2
    echo "FAIL, $bad of $tests"
  else
    echo "ok, $tests tests"
  fi
}
for m in $INSTALLED; do
  if compose exec -T humhub test -f "/var/www/localhost/htdocs/protected/modules/$m/tests/codeception.yml"; then
    harness module/enable "$m" | tail -1
    u=$(suite "$m" unit); f=$(suite "$m" functional)
    echo "  $m unit: $u; functional: $f"
    case "$u$f" in *FAIL*) FAILED="$FAILED $m" ;; esac
    row "$m" "$(version "$m")" yes "$u" "$f"
  else
    echo "  $m ships no tests"
    row "$m" "$(version "$m")" yes "none" "none"
  fi
done

echo
echo "How the modules fared on HumHub $VERSION"
printf '%-18s %-9s %-24s %-18s %s\n' Module Version Installed 'Unit tests' 'Functional tests'
tr '|' '\t' < "$ROWS" | while IFS="$(printf '\t')" read -r a b c d e; do printf '%-18s %-9s %-24s %-18s %s\n' "$a" "$b" "$c" "$d" "$e"; done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## How the modules fared on HumHub $VERSION"
    echo
    echo "| Module | Version | Installed | Unit tests | Functional tests |"
    echo "|---|---|---|---|---|"
    sed -e 's/^/| /' -e 's/|/ | /g' -e 's/$/ |/' "$ROWS"
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo

# Reported last so one run shows everything else as well.
[ -z "$FAILED" ] || fail "module tests failed:$FAILED"
[ -z "$MISSING" ] || fail "the marketplace has no release for HumHub $VERSION of:$MISSING"
# The versions this pass ran with, behind each id in deploy/modules.txt; the
# image carries the file and deploy/entrypoint.d/20-update-modules.sh updates
# the modules when it changes.
echo "$LIST" > "$BODY"
awk 'NR == FNR { if (NF >= 3) ver[$1] = $3; next }
  /^[[:space:]]*(#|$)/ { print; next }
  { if ($1 in ver) print $1, ver[$1]; else print }' "$BODY" deploy/modules.txt > "$BODY.new"
cat "$BODY.new" > deploy/modules.txt
rm -f "$BODY.new"
echo "PASS: $(echo "$INSTALLED" | wc -w | tr -d ' ') modules installed, enabled, rendering and passing their tests"
