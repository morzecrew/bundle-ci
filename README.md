# bundle-ci

The CI pipeline of a [morzer](https://github.com/morzecrew/morzer) bundle
repository, as reusable workflows: pin the component images, build, sign and
smoke-test the bundle in a Docker-in-Docker rig, and publish it to ghcr behind
a `:main` dev channel and a `:stable` release channel.

A product repository keeps its bundle, a few thin workflows that call these,
and whatever only it checks. Everything else lives here, once.

## What a product repository holds

| Path | What it is |
|---|---|
| `bundle/` | the morzer bundle: `manifest.yaml`, Compose, secrets schema, hooks |
| `components.yaml` | `rollback_safe` of each component, which a release declares together |
| `.github/smoke.d/*.sh` | the product's own smoke checks, run in the rig after the install |
| `.github/workflows/{main,release,pr,retention}.yml` | the callers below |

The bundle is published to `ghcr.io/<owner>/<repository>`. Its component images
are pinned in `bundle/manifest.yaml` as `repo:tag@sha256:...`; the keys named
by `components` (default `backend migrations frontend`) are the ones this
pipeline moves.

## The workflows

| Workflow | Job | Needs |
|---|---|---|
| `pin.yml` | resolve each component's `main` to a digest, commit a changed pin to the product's main; outputs `sha` | `contents: write`, `packages: read` |
| `guard.yml` | refuse a release tag that is not `vX.Y.Z` on main; outputs `version` | `contents: read` |
| `bundle.yml` | build, sign, `smoke-install` and `smoke-update`; outputs `version`, `archive`, `proceed`, `images` | `contents: read`, `packages: read` |
| `publish.yml` | push `:<version>`, move the channel; for a release, first tag each component image `bundle-<version>` | `contents: read`, `packages: write` |
| `retention.yml` | keep the last dev versions and drop untagged ones | a token secret that may delete package versions |

They are not nested: a product's workflow calls each as a job, so every
permission it grants is visible where it is granted.

### A product's callers

Pin the workflows to a release tag (or its commit). `RUNS_ON` is a repository
variable naming the runner label; without it jobs run on `ubuntu-24.04`.

```yaml
# .github/workflows/main.yml -- the dev channel
name: main
on:
  repository_dispatch:
    types: [component-published]
  push:
    branches: [main]
    paths: [bundle/**, components.yaml]
  workflow_dispatch:
  schedule:
    - cron: "23 */6 * * *"
permissions: {}
concurrency:
  group: main-bundle
  cancel-in-progress: false
jobs:
  pin:
    permissions: { contents: write, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/pin.yml@v0.1.2
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
  bundle:
    needs: pin
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.1.2
    with:
      ref: ${{ needs.pin.outputs.sha }}
      channel: main
      signing: dev
      on-existing: skip # nothing moved since the last run
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
      operator-secrets: admin_password
      dev-pubkey: ${{ vars.MINISIGN_DEV_PUBKEY }}
    secrets:
      minisign-key: ${{ secrets.MINISIGN_DEV_KEY }}
  publish:
    needs: [pin, bundle]
    if: needs.bundle.outputs.proceed == 'true'
    permissions: { contents: read, packages: write }
    uses: morzecrew/bundle-ci/.github/workflows/publish.yml@v0.1.2
    with:
      version: ${{ needs.bundle.outputs.version }}
      archive: ${{ needs.bundle.outputs.archive }}
      channel: main
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
```

```yaml
# .github/workflows/release.yml -- the stable channel
name: release
on:
  push:
    tags: ["v*"]
permissions: {}
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
jobs:
  guard:
    permissions: { contents: read }
    uses: morzecrew/bundle-ci/.github/workflows/guard.yml@v0.1.2
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
  bundle:
    needs: guard
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.1.2
    with:
      ref: ${{ github.sha }}
      version: ${{ needs.guard.outputs.version }}
      pin: release
      channel: stable
      signing: release
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
      operator-secrets: admin_password
      release-pubkey: ${{ vars.MINISIGN_RELEASE_PUBKEY }}
    secrets:
      minisign-key: ${{ secrets.MINISIGN_RELEASE_KEY }}
  publish:
    needs: bundle
    if: needs.bundle.outputs.proceed == 'true'
    permissions: { contents: read, packages: write }
    uses: morzecrew/bundle-ci/.github/workflows/publish.yml@v0.1.2
    with:
      version: ${{ needs.bundle.outputs.version }}
      archive: ${{ needs.bundle.outputs.archive }}
      channel: stable
      images: ${{ needs.bundle.outputs.images }}
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
```

```yaml
# .github/workflows/pr.yml -- built and smoke-tested, never published
name: pr
on:
  pull_request:
permissions: {}
concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  bundle:
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.1.2
    with:
      ref: ${{ github.sha }}
      version: 0.0.0-pr.${{ github.event.pull_request.number }}
      pin: dev
      signing: ephemeral
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
      operator-secrets: admin_password
      # smoke-update installs the published :main first, trusting this key.
      dev-pubkey: ${{ vars.MINISIGN_DEV_PUBKEY }}
```

```yaml
# .github/workflows/retention.yml
name: retention
on:
  schedule:
    - cron: "41 3 * * *"
  workflow_dispatch:
permissions: {}
jobs:
  retention:
    permissions: {}
    uses: morzecrew/bundle-ci/.github/workflows/retention.yml@v0.1.2
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
    secrets:
      token: ${{ secrets.GH_PAT }}
```

### `bundle.yml`'s inputs

| Input | Default | |
|---|---|---|
| `ref` | — | the product commit to build |
| `version` | the dev version | `0.0.0-pr.N` for a pull request, `X.Y.Z` for a release; empty takes `scripts/version.sh`'s `<next-patch>-dev.<n>.g<sha>` of the last commit that changed `bundle/` |
| `pin` | `none` | `dev` pins every component's `main`; `release` promotes the committed pins as `bundle-<version>` |
| `channel` | — | `main` or `stable`: what `smoke-update` updates from, and whether a published version is refused |
| `signing` | — | `dev`, `release`, or `ephemeral` (a key made in the job) |
| `on-existing` | `fail` | `skip` ends the run quietly when the version is already published |
| `components` | `backend migrations frontend` | the `images:` keys `pin` moves |
| `schema-image` | `migrations` | the key whose image's label is the schema the release produces; empty when none |
| `schema-label` | `tech.morze.<metadata.name>.schema` | that label |
| `operator-secrets` | — | secrets only an operator sets; the smoke install sets each from random |
| `health-port`, `probe-paths` | `8081`, `/__platform_healthz /health` | what a probe asks the edge's loopback port for |
| `smoke-hooks` | `.github/smoke.d` | the product's smoke hooks |
| `dev-pubkey`, `release-pubkey` | — | the public keys the dev and release builds are verified with, and `smoke-update` trusts the published bundle by |

### Smoke hooks

`smoke-install` installs the bundle in the rig and probes it, copies the
`smoke-hooks` directory whole to `/rig/smoke.d`, then runs each top-level `*.sh`
there in name order, as root, each followed by a probe. Anything else in the
directory, such as a `lib/` of the product's helpers, is there for a hook to
source. A hook starts with `. /rig/smoke-lib.sh`, which gives it:

- `SMOKE_PROJECT`, the Compose project (the manifest's
  `runtimes.compose.options.project`, else `metadata.name`);
- `service_container <service>`, the running container of a service;
- `die`, `random` and `probe`.

```bash
# .github/smoke.d/10-task.sh
. /rig/smoke-lib.sh
sudo morzer task list
sudo morzer --verbose task run repair
```

A hook is the product's own code and runs as root; it never prints a secret.

### Rehearsing on a workstation

`scripts/rehearse.sh` runs what the smoke jobs prove, against the working
tree: it installs a published bundle in a `<project>-rehearsal` rig, runs the
smoke hooks, updates to the tree's `bundle/`, and rolls back. Run it from the
product's root, with `oras` logged in to ghcr:

```console
git clone https://github.com/morzecrew/bundle-ci ~/bundle-ci
cd <product>
REHEARSE_PUBKEY="$(gh variable get MINISIGN_DEV_PUBKEY)" \
REHEARSE_OPERATOR_SECRETS=admin_password \
  bash ~/bundle-ci/scripts/rehearse.sh            # from the product's :main
bash ~/bundle-ci/scripts/rehearse.sh --from <ref> # from another published bundle
bash ~/bundle-ci/scripts/rehearse.sh --keep       # leave the rig for inspection
```

No credential enters the rig: the workstation's `oras` copies every image
either manifest pins into it.

### Releasing a product

A release promotes a dev build: it ships the component digests the dev channel
committed, and `publish.yml` tags each image `bundle-<version>`, which a
retention that deletes a version only when every tag matches (as
`snok/container-retention-policy` v3 does) never selects. The tag needs the
product repository to hold the **Write** role under each component package's
**Package settings → Manage Actions access**. Tag the commit the dev VM runs:

```console
git tag vA.B.C <commit> && git push origin vA.B.C
```

## Releasing bundle-ci

A called workflow cannot see its own ref, so each one checks bundle-ci out at
`bundle-ci-ref`, whose default names the release. A release:

1. sets every `default: ... # bundle-ci-ref:` line to the coming tag, and seals
   the CHANGELOG, in one pull request (CI refuses defaults that differ):

   ```console
   sed -i -E 's/^( +default: )[^ ]+( # bundle-ci-ref:)/\1vX.Y.Z\2/' .github/workflows/*.yml
   ```

2. tags the merge commit `vX.Y.Z`. CI fails on a tag whose defaults name
   anything else; delete it and release again.

A caller pinned to `@vX.Y.Z` then runs vX.Y.Z's scripts. To try an unreleased
commit, call the workflows at that commit and pass `bundle-ci-ref` the same
commit.

## Working on bundle-ci

```console
bash tests/pin/run.sh       # needs mikefarah's yq
bash tests/version/run.sh
bash tests/smoke/run.sh     # needs zstd
shellcheck -x scripts/*.sh tests/*/*.sh
```

This repository is public. Its own CI runs on GitHub-hosted runners only, and
nothing here names a private repository or image: every product name arrives as
an input.
