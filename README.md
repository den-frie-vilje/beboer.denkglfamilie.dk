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
3. In a service window, back production up, then merge `staging` into `main`.
   The merge is the deploy: the agent pulls within a few minutes and the
   migrations run against production.

Rollback is the backup: stop the stack, restore the database directory and
the config directory from the backup, revert the merge so `production-latest`
moves back, and let the agent start it. Nothing shortens the window itself;
the data is frozen from the backup to the moment the new version answers.

## Layout

| Path | Purpose |
|---|---|
| `deploy/Dockerfile.humhub`, `Dockerfile.nginx` | Which upstream HumHub images this branch runs, pinned by digest |
| `deploy/compose.production.yml` | The production stack |
| `deploy/compose.staging.yml` | The same stack plus the mail catcher |
| `deploy/<env>.env.example` | Template for the env file on the NAS |
| `deploy/nas-sites/beboer.denkglfamilie.dk.<env>.env` | The agent's config for that environment, on record |
| `deploy/ladder.yml` | Override for running an intermediate version's migrations without deploying it |
| `tools/refresh-staging.sh` | Copies production's data to staging and neutralises it |
| `.github/workflows/deploy-<env>.yml` | Builds and signs that environment's images when the Dockerfiles change |

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

Production is the stack that ran before this repository existed. Its data
stays where it is; `deploy/production.env.example` points there. Onboarding
it is the first deploy: stop the old stack, disable it so it does not come
back on reboot, and run the agent for `beboer.denkglfamilie.dk production`. The compose file is
the old one with a loopback bind and the utf8mb4 server default added, at 1.15.6 instead of the 1.15.2 whose image is no longer published. Staging then walks the copy up one minor at a time, since HumHub advises against skipping minors:

```sh
sudo /volume1/docker/beboer.denkglfamilie.dk/repo/tools/refresh-staging.sh \
  docker.io/jeremyvies/humhub:1.16.2-phponly@sha256:74d74f81857232167e51291f2272995f519c62a3366f045dcb798ef3178a5e04 \
  docker.io/jeremyvies/humhub:1.17.5-phponly@sha256:3c09fc19a52e7f1dcca302d4e4c94c60a0b9d47f1e24a84fc1a8b43c2e7b110e
```

Check the information page and the marketplace modules at 1.17.5 as well:
1.18 moved HumHub from Bootstrap 3 to Bootstrap 5, and a theme or module from
the 1.15 days stops rendering there.

## Refreshing staging

```sh
sudo /volume1/docker/beboer.denkglfamilie.dk/repo/tools/refresh-staging.sh [intermediate phponly image ...]
```

Production keeps running; its database is dumped in a single transaction and
its files are copied with rsync. The copy is then migrated through any
intermediate images given (see `deploy/ladder.yml`), neutralised, and
started. The first refresh copies everything; later ones copy the delta.

## Service window for production

1. Rename `/volume1/docker/nas-sites/sites.d/beboer.denkglfamilie.dk.production.env` to
   `.disabled` so the agent cannot start anything until you say so.
2. Stop production: `docker compose -p beboer-denkglfamilie-dk-production down`
   (from `/volume1/docker/beboer.denkglfamilie.dk/repo` with the compose file and env file, as
   the agent runs it).
3. Back up `db/data` and `humhub/config` under the data directory. On
   Btrfs, `cp -a --reflink=always` is instant; otherwise rsync to a sibling
   directory.
4. If staging needed a ladder, run the same images against production with
   `deploy/ladder.yml` now, one after the other.
5. Run the collation fix if Administration, Information still warns about it
   (below).
6. Merge `staging` into `main`, wait for the build, rename the `sites.d` file
   back, and run the agent: `sudo -u deploy /volume1/docker/nas-sites/deploy-agent.sh beboer.denkglfamilie.dk production`.
7. Log in, read Administration, Information, update the marketplace modules.

### Collation fix

The database was created with MariaDB's old default collation, and tables
created by modules inherited it. HumHub's own 2018 migration converted the
core tables; this applies the same statements to the rest. Run it against the
database before the new version starts:

```sql
ALTER DATABASE humhub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SET FOREIGN_KEY_CHECKS=0;
-- one line per table the information page lists, for example:
ALTER TABLE custom_pages_page_setting CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SET FOREIGN_KEY_CHECKS=1;
SELECT table_name, table_collation FROM information_schema.tables
 WHERE table_schema='humhub' AND table_collation <> 'utf8mb4_unicode_ci';
```

The last query must come back empty. The compose files also set the server
default to utf8mb4, so new tables no longer inherit the old collation.

## Mail

The mail transport is a HumHub setting stored in the database (Administration,
Settings, Mailing), not something in this repository. Production's setting
survives upgrades with the data; staging's is overwritten by every refresh.
