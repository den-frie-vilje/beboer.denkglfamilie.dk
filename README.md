# beboer.denkglfamilie.dk

HumHub community for the residents behind denkglfamilie.dk, run on the Synology NAS as a staging and a
production stack and deployed by the [nas-sites](https://github.com/den-frie-vilje/nas-sites)
pull-only agent. This repository holds everything about the deployment and
nothing about the data: uploads, the database and the HumHub configuration
live on the NAS under each environment's data directory.

## How the two environments work

Production is the live site. Staging is a second, complete stack that runs on
a copy of production's data, refreshed by `tools/refresh-staging.sh` whenever
an upgrade is to be rehearsed. The refresh neutralises the copy so nothing
staging does reaches a member: mail goes to a mail catcher inside the staging
stack, the push notification module is removed from the copy, and the base
URL is staging's own hostname.

The HumHub version is the pair of `FROM` lines in `deploy/`, and the branch
decides the environment: the `staging` branch builds `staging-latest`, `main`
builds `production-latest`. An upgrade is:

1. Bump both Dockerfiles on `staging`. The workflow builds and signs the
   images; the agent pulls them and starts staging, whose entrypoint runs the
   migrations on the copied data.
2. Rehearse on staging: log in, read Administration, Information, update the
   marketplace modules, send a test mail and read it in the catcher.
3. Merge `staging` into `main` in a service window. The merge is the deploy:
   the agent pulls within a few minutes, the image dumps the database
   (`deploy/pre-start.sh`), the migrations run against production, and the
   marketplace modules are updated to their releases for the new core
   (`deploy/entrypoint.d/20-update-modules.sh`).

Every push of the Dockerfiles is checked before anything is built
(`tools/check-version.sh`): both files at one version, the digests as Docker
Hub serves them for that tag, the image's own version file matching, and no
minor version skipped, which HumHub advises against. Dependabot opens patch
bumps as one pull request for both files.

Rollback is the dump: see "Rollback" under the service window. Nothing
shortens the window itself; the data is frozen from the dump to the moment
the new version answers.

## Layout

| Path | Purpose |
|---|---|
| `deploy/Dockerfile.humhub`, `Dockerfile.nginx` | Which upstream HumHub images this branch runs, pinned by digest |
| `deploy/compose.production.yml` | The production stack |
| `deploy/compose.staging.yml` | The same stack plus the mail catcher |
| `deploy/<env>.env.example` | Template for the env file on the NAS |
| `deploy/nas-sites/beboer.denkglfamilie.dk.<env>.env` | The agent's config for that environment, on record |
| `deploy/entrypoint.d/10-common-config.sh` | Regenerates `common.php` from the image's factory and `common.site.php` on every start |
| `deploy/common.site.php` | The site's own PHP configuration, merged over the generated `common.php` |
| `deploy/humhub.<env>.env` | HumHub's own `.env`: scalar configuration and pinned settings per environment |
| `deploy/ladder.yml` | Override for running an intermediate version's migrations without deploying it |
| `tools/copy-from-legacy.sh` | One-off copy of the site that runs today into the canonical layout |
| `tools/refresh-staging.sh` | Copies production's data to staging and neutralises it |
| `deploy/pre-start.sh` | The image's entrypoint: dumps the database before an upgrade migrates it |
| `deploy/entrypoint.d/20-update-modules.sh` | Updates the marketplace modules once, after a core upgrade has migrated |
| `tools/check-version.sh` | The version-bump check the workflows run before building |
| `tools/fix-collation.sh` | Converts the database default and every table to utf8mb4_unicode_ci, before HumHub migrates |
| `.github/workflows/deploy-<env>.yml` | Checks the version bump, then builds and signs that environment's images when the Dockerfiles change |
| `.github/workflows/check-version.yml` | The same check on a pull request |

The copy script places the theme's login background where 1.18 keeps its own
(`uploads/login-bg/background.png`), and the theme's one rule, the logo width on
the login page, is pinned as custom SCSS in `deploy/humhub.<env>.env`. The six
colours the upgrade copies into Appearance are the theme's: primary `#284764`,
accent `#6fdbe8`, success `#97d271`, warning `#fdd198`, danger `#ff8989`, light
`#ededed`. The stacks mount no theme folder. Kongeligt is a Bootstrap 3 theme built with
the deprecated theme-builder module; the 1.18 upgrade retires it and switches
the site to the stock theme, carrying six colours over into Appearance. The
old files stay in the data directory under `humhub/themes/Kongeligt` for the
rewrite, and a rewritten Kongeligt is mounted as a single folder when it
exists. Mounting the whole `themes` folder would hide the stock theme that
ships in the image.

The images are the upstream `jeremyvies/humhub` images re-tagged under
`ghcr.io/den-frie-vilje/beboer-humhub` and `beboer-nginx`. The agent only
deploys a stack that contains at least one image signed by nas-sites' own
workflow, which is what the re-tag provides. After the first build, make both
GHCR packages public, or the NAS cannot pull them.

## One-time setup on the NAS

The operator runs these by hand; the agent has no write access to any of it.

1. Bootstrap each environment with `sudo /volume1/docker/nas-sites/repo/tools/bootstrap-site.sh`
   (domain `beboer.denkglfamilie.dk`, environment, branch `staging` or `main`, compose file
   `deploy/compose.<env>.yml`). It creates `/volume1/docker/beboer.denkglfamilie.dk/<env>/`,
   clones this repository and writes the `sites.d` file; the values it
   writes are the ones in `deploy/nas-sites/`.
2. Fill in `/volume1/docker/beboer.denkglfamilie.dk/<env>/<env>.env` from the example in
   `deploy/`, 0640 root:docker.
3. Point the DSM reverse-proxy vhosts at `localhost:<HUMHUB_PORT>`: the
   public domain for production, `beboer-denkglfamilie-dk.stage.denfrievilje.dk`
   for staging. The stacks bind to loopback only. The mail catcher's UI is on
   `localhost:<MAILCATCHER_PORT>`; reach it through an SSH tunnel or a vhost
   of its own.

## Site configuration

Three kinds of configuration, three places:

- **PHP configuration that only code can express**, such as the display-name
  callback: `deploy/common.site.php`, merged over the generated `common.php`
  on every start. `common.php` itself is regenerated from the image's factory
  by `deploy/entrypoint.d/10-common-config.sh`, so hand edits to it are lost.
- **Scalar configuration and pinned settings**: `deploy/humhub.<env>.env`,
  HumHub's own `.env`, mounted into the web root. `HUMHUB_WEB_CONFIG__...`
  and `HUMHUB_CONFIG__...` set configuration; `HUMHUB_FIXED_SETTINGS__<module>__<name>`
  pins a database setting so that it wins over the setting table and is locked
  in the admin interface. Staging pins its mailer to the catcher and its base
  URL this way.
- **Everything else is data** in the database and the data directory:
  Appearance, module settings, profile fields, `dynamic.php` with the database
  connection, `web.php` and `console.php`.

To add a customisation, decide which of the three it is, change the file on
`staging`, and promote it with the next staging to main pull request.

## Onboarding from the existing stack

The site that runs today is the Container Manager project
`mriedmann-humhub-latest` on `/volume1/docker/humhub`, with the database
project `humhub_db` on `/volume1/docker/humhub_db`, and keeps serving until
the very end. (`/volume1/docker/staging` is a 2024 copy, not the live site.) Nothing here touches it. The new layout is filled
from a copy, and the production domain moves over when the copy is proven.

1. Copy the data into production's canonical directory with
   `tools/copy-from-legacy.sh`, which maps the old layout onto the new one.
   Files are copied while the old site runs; the database directory only with
   `--database`, after its container is stopped, since a running database
   cannot be copied consistently. The copy only exists on disk; nothing is
   started, and the old folders are never mounted by the new stacks:

   ```sh
   cd /volume1/docker/beboer.denkglfamilie.dk/repo
   sudo tools/copy-from-legacy.sh
   sudo /usr/local/bin/docker stop humhub_db && sudo tools/copy-from-legacy.sh --database && sudo /usr/local/bin/docker start humhub_db
   ```

2. Refresh staging from that copy (`tools/refresh-staging.sh`), which copies
   the database files as they are when production is not running, and
   rehearse the upgrade there.
3. **Do not start the production stack before the window.** Two stacks on the
   same data send every digest and notification twice.

Beboer's copy also has to climb from 1.15 one minor at a time; the refresh
and the window both run the ladder, see below.

The cutover is the service window below, with one extra step at the start:
stop the old stack, and rerun `tools/copy-from-legacy.sh --database` so the
copy carries everything written since. From then on the old directory is the rollback, until it is deleted.

## Go-live

The one-off cutover from the old stack, after production has been copied,
converted and migrated as above and parked behind the maintenance page.

1. Rerun "Deploy to staging" and "Deploy to production" by hand (Actions,
   Run workflow) so `apk upgrade` takes the current Alpine packages; this is
   how a PHP fix reaches the image. Check it: `docker run --rm --entrypoint php ghcr.io/den-frie-vilje/beboer-humhub:production-latest -v`.
2. Enable the agent: rename `/volume1/docker/nas-sites/sites.d/beboer.denkglfamilie.dk.production.env.disabled`
   back to `.env`.
3. Run it: `sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh beboer.denkglfamilie.dk production`.
   The first start dumps the database if the version changed, migrates, and
   starts nginx on `localhost:<HUMHUB_PORT>`.
4. Point the Web Station portal of `beboer.denkglfamilie.dk` at that port instead of the
   `maintenance` service.
5. Log in, read Administration, Information.
6. Stop and later delete the old stack; its directory is the rollback until then.
7. The modules update themselves at this start, since the version changes
   from 1.18.6 to 1.19.0; read Administration, Information. Install dark mode
   once, as the service window describes.
8. Send a test mail; the transport (smtp.netsite.dk) comes over with the data.

## Refreshing staging

```sh
sudo /volume1/docker/beboer.denkglfamilie.dk/repo/tools/refresh-staging.sh [intermediate phponly image ...]
```

That is the whole of it: run it whenever staging should test against today's
data. A running production is dumped in a single transaction and its files
are copied with rsync; a production at rest has its database files copied.
The copy is neutralised and started; when staging's branch is a version ahead
of production, the start migrates the copy, as the production deploy will. The
first refresh copies everything; later ones copy the delta. Only a jump of
more than one minor version needs intermediate images, which are run as a
migration ladder (see `deploy/ladder.yml`) with the marketplace modules
updated to each core on the way.

Before the first go-live, beboer's copy came from 1.15.2, so the refresh ran
the ladder:

```sh
sudo /volume1/docker/beboer.denkglfamilie.dk/repo/tools/refresh-staging.sh \
  docker.io/jeremyvies/humhub:1.16.2-phponly@sha256:74d74f81857232167e51291f2272995f519c62a3366f045dcb798ef3178a5e04 \
  docker.io/jeremyvies/humhub:1.17.5-phponly@sha256:3c09fc19a52e7f1dcca302d4e4c94c60a0b9d47f1e24a84fc1a8b43c2e7b110e
```

It updates every module to its release for each core on the way and
uninstalls theme-builder, which has no release after 1.17. The Kongeligt
theme it produced is a Bootstrap 3 theme; 1.18 moved HumHub to Bootstrap 5
and Sass, so staging at 1.18.6 shows whether Kongeligt needs a rewrite or
the stock theme takes over.

## Service window for production

1. Rename `/volume1/docker/nas-sites/sites.d/beboer.denkglfamilie.dk.production.env` to
   `.disabled` so the agent cannot start anything until you say so.
2. Stop production: `docker compose -p beboer-denkglfamilie-dk-production down`
   (from `/volume1/docker/beboer.denkglfamilie.dk/repo` with the compose file and env file, as
   the agent runs it). At the first cutover this is the old stack instead,
   followed by the final copy from "Onboarding from the existing stack".
3. Copy `humhub/config` under the data directory to a sibling directory.
   The database needs no copy: the image dumps it into
   `humhub/config/backups` before it migrates.
4. If staging needed a ladder, run the same images against production with
   `deploy/ladder.yml` now, one after the other.
5. Start the database alone and run the collation fix (below), before any
   HumHub container migrates.
6. Merge `staging` into `main`, wait for the build, rename the `sites.d` file
   back, and run the agent: `sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh beboer.denkglfamilie.dk production`.
7. Log in, read Administration, Information, update the marketplace modules.
   Once, at the first go-live: install the dark-mode module as on spejdernet,
   in the running stack:
   ```sh
   docker compose -p beboer-denkglfamilie-dk-production -f deploy/compose.production.yml --env-file /volume1/docker/beboer.denkglfamilie.dk/production/production.env exec -w /var/www/localhost/htdocs/protected humhub sh -c "php yii module/install dark-mode && php yii module/enable dark-mode && php yii settings/set dark-mode showButton 1 && php yii cache/flush-all"
   ```
8. At the first cutover: point the DSM reverse-proxy vhost of the production
   domain at `localhost:<HUMHUB_PORT>` of the new stack.

### Rollback

The dump in `humhub/config/backups` is named after the version it holds and
the version that was about to migrate it. To go back: stop the stack, revert
the merge on `main` and wait for the build, recreate the database from the
dump, then let the agent start the old version again. The old image finds a
newer version file, dumps once more, runs no migrations it does not know, and
writes its own version file back.

```sh
cd /volume1/docker/beboer.denkglfamilie.dk/repo
PROD="docker compose -p beboer-denkglfamilie-dk-production -f deploy/compose.production.yml --env-file /volume1/docker/beboer.denkglfamilie.dk/production/production.env"
sudo $PROD down
sudo $PROD up -d --wait db
zcat /volume1/docker/beboer.denkglfamilie.dk/production/data/humhub/config/backups/humhub-OLD-before-NEW-*.sql.gz | sudo $PROD exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE humhub; CREATE DATABASE humhub" && mysql -uroot -p"$MYSQL_ROOT_PASSWORD" humhub'
sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh beboer.denkglfamilie.dk production
```

### Collation fix

The database was created with MariaDB's old default collation, and tables
created by modules inherited it; HumHub migrations create new tables with the
database default, so the conversion has to happen before HumHub migrates.
`tools/fix-collation.sh` converts the database default and every remaining
table to utf8mb4_unicode_ci and refuses to succeed while any table is left.
The staging refresh runs it as soon as the copied database is up. In the
production window, start the database alone, run it, then let the agent
start the stack:

```sh
cd /volume1/docker/beboer.denkglfamilie.dk/repo
sudo docker compose -p beboer-denkglfamilie-dk-production -f deploy/compose.production.yml --env-file /volume1/docker/beboer.denkglfamilie.dk/production/production.env up -d --wait db
sudo tools/fix-collation.sh production
```

## Mail

The mail transport is a HumHub setting stored in the database (Administration,
Settings, Mailing), not something in this repository. Production's setting
survives upgrades with the data; staging's is overwritten by every refresh.
