# Working in this repository

The branches are the merge train. `staging` builds and deploys the staging
stack, `main` the production stack (README, "How the two environments work").
Every change, whether a version bump, a configuration change or a tooling fix,
is a pull request against `staging`, merged there and rehearsed on the staging
stack. `main` receives one kind of pull request: `staging` itself, opened once
the rehearsal has passed. The workflow `.github/workflows/merge-train.yml` and
the rulesets on both branches refuse anything else. Nothing is pushed to either
branch directly, and nothing is opened against `main` from another branch,
however urgent; an urgent fix goes through `staging` in the same hour.
