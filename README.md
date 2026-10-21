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
bumps as one pull request for both files. A fix in the base image's
packages, PHP included, needs no version bump: rerun the environment's
deploy workflow by hand (Actions, Run workflow), the build's `apk upgrade`
takes the current packages, and the agent pulls the new image.

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
| `tools/refresh-staging.sh` | Copies production's data to staging and neutralises it |
| `deploy/pre-start.sh` | The image's entrypoint: dumps the database before an upgrade migrates it |
| `deploy/entrypoint.d/20-update-modules.sh` | Updates the marketplace modules once, after a core upgrade has migrated |
| `tools/check-version.sh` | The version-bump check the workflows run before building |
| `tools/fix-collation.sh` | Converts the database default and every table to utf8mb4_unicode_ci, before HumHub migrates |
| `.github/workflows/deploy-<env>.yml` | Checks the version bump, then builds and signs that environment's images when the Dockerfiles change |
| `.github/workflows/check-version.yml` | The same check on a pull request |

The site runs the stock theme. Kongeligt, a Bootstrap 3 theme built with the
deprecated theme-builder module, was retired at the 1.18 upgrade; its six
colours live on in Appearance (primary `#284764`, accent `#6fdbe8`, success
`#97d271`, warning `#fdd198`, danger `#ff8989`, light `#ededed`), its login
background sits where 1.18 keeps its own (`uploads/login-bg/background.png`),
and its one rule, the logo width on the login page, is pinned as custom SCSS
in `deploy/humhub.<env>.env`. The old files stay in the data directory under
`humhub/themes/Kongeligt` for the rewrite, and a rewritten Kongeligt is
mounted as a single folder when it exists. The stacks mount no theme folder
until then: mounting the whole `themes` folder would hide the stock theme that
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

## Service window for production

1. Rename `/volume1/docker/nas-sites/sites.d/beboer.denkglfamilie.dk.production.env` to
   `.disabled` so the agent cannot start anything until you say so.
2. Stop production: `docker compose -p beboer-denkglfamilie-dk-production down`
   (from `/volume1/docker/beboer.denkglfamilie.dk/repo` with the compose file and env file, as
   the agent runs it).
3. Copy `humhub/config` under the data directory to a sibling directory.
   The database needs no copy: the image dumps it into
   `humhub/config/backups` before it migrates.
4. If staging needed a ladder, run the same images against production with
   `deploy/ladder.yml` now, one after the other.
5. Merge `staging` into `main`, wait for the build, rename the `sites.d` file
   back, and run the agent: `sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh beboer.denkglfamilie.dk production`.
6. Log in, read Administration, Information, update the marketplace modules.

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

HumHub migrations create new tables with the database default, so the
database default and every table are utf8mb4_unicode_ci, the collation HumHub
recommends. `tools/fix-collation.sh` converts whatever is left and refuses to
succeed while any table remains; the staging refresh runs it as soon as the
copied database is up, so a table that slipped in with another collation is
caught on staging, before the production deploy migrates it.

## Mail

The mail transport is a HumHub setting stored in the database (Administration,
Settings, Mailing), not something in this repository. Production's setting
survives upgrades with the data; staging's is overwritten by every refresh.
