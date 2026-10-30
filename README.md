# bundle-ci

The CI pipeline of a [morzer](https://github.com/morzecrew/morzer) bundle
repository, as reusable workflows: pin the component images, build, sign and
smoke-test the bundle in a Docker-in-Docker rig, and publish it to ghcr behind
a `:main` dev channel and a `:stable` release channel. The component
repositories behind a bundle build and keep their images with it too
([below](#a-component-repository)).

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
variable naming the runner label; without it jobs run on `ubuntu-24.04`. Every
job has a `timeout-minutes`, so one a self-hosted runner hangs fails within the
hour instead of holding the concurrency group, and every run queued behind it,
for GitHub's six.

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
    uses: morzecrew/bundle-ci/.github/workflows/pin.yml@v0.4.1
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
  bundle:
    needs: pin
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.4.1
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
    uses: morzecrew/bundle-ci/.github/workflows/publish.yml@v0.4.1
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
    uses: morzecrew/bundle-ci/.github/workflows/guard.yml@v0.4.1
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
  bundle:
    needs: guard
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.4.1
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
    uses: morzecrew/bundle-ci/.github/workflows/publish.yml@v0.4.1
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
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.4.1
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
    uses: morzecrew/bundle-ci/.github/workflows/retention.yml@v0.4.1
    with:
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
    secrets:
      token: ${{ secrets.GH_PAT }}
```

### `bundle.yml`'s inputs

| Input | Default | |
|---|---|---|
| `ref` | — | the product commit to build |
| `version` | the dev version | `0.0.0-pr.N` for a pull request, `X.Y.Z` for a release; empty takes `scripts/version.sh`'s `<next-patch>-dev.<n>.g<sha>` of the last commit that changed `version-paths` |
| `version-paths` | `bundle` | the paths whose last commit names the dev version; a product in one repository adds its code's |
| `pin` | `none` | `dev` pins every component's `main`; `release` promotes the committed pins as `bundle-<version>`; `promote` promotes the pins of the dev bundle the commit was published as ([below](#a-product-in-one-repository)) |
| `channel` | — | `main` or `stable`: what `smoke-update` updates from, and whether a published version is refused |
| `signing` | — | `dev`, `release`, or `ephemeral` (a key made in the job) |
| `on-existing` | `fail` | `skip` ends the run quietly when the version is already published |
| `components` | `backend migrations frontend` | the `images:` keys `pin` moves |
| `schema-image` | `migrations` | the key whose image's label is the schema the release produces; empty when none |
| `schema-label` | `tech.morze.<metadata.name>.schema` | that label |
| `operator-secrets` | — | secrets only an operator sets; the smoke install sets each from random |
| `health-port`, `probe-paths` | `8081`, `/__platform_healthz /health` | what a probe asks the edge's loopback port for; empty `probe-paths` for a bundle that serves no HTTP, which leaves its manifest's health checks, run at every apply |
| `smoke-hooks` | `.github/smoke.d` | the product's smoke hooks |
| `dev-pubkey`, `release-pubkey` | — | the public keys the dev and release builds are verified with, and `smoke-update` trusts the published bundle by |
| `image-cache` | `true` | on a self-hosted runner, load the pinned images from the runner's cache (below) |

### The image cache

A smoke job's rig starts empty, and pulling every image a bundle pins took most
of its time, over a link that drops connections. On a self-hosted runner each
smoke job instead:

1. lists the archive's pins in the rig (`smoke.sh pins`);
2. copies each one the runner has not seen into `~/.cache/bundle-ci/oci`, an
   OCI layout per repository and digest, with `oras` and up to 4 tries. For a
   multi-platform index it keeps the index and every manifest it lists, but only
   `linux/amd64`'s layers (`IMAGE_CACHE_PLATFORM`), half of what a full copy
   would hold;
3. loads every cached pin into the rig at once, an index's for its one platform,
   each tried twice. Named
   `repo@sha256:<hex>`, a loaded image answers `docker image inspect <pin>`, and
   `docker create --pull never <pin>` uses it, so neither `smoke.sh` nor morzer
   pulls it;
4. prunes entries no job used for 14 days.

A copy that fails 4 times, or a load that fails twice, is left to the rig's own
retried pull: the cache makes a job faster, never one that fails. Entries fill
through a temporary directory renamed into place, under a lock beside each
(`flock`, where the runner has it), so jobs sharing a runner's disk never see
half of one, nor copy one twice. The
cache holds the private images the bundles pin, readable by the runner's user:
a self-hosted runner is trusted with them already, as it pulls them. A hosted
runner starts empty, so its rigs pull directly; `image-cache: false` makes a
self-hosted one do the same.

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
committed (or, in one repository, pinned in its dev bundle), and `publish.yml`
tags each image `bundle-<version>`, which a
retention that deletes a version only when every tag matches (as
`snok/container-retention-policy` v3 does) never selects. The tag needs the
product repository to hold the **Write** role under each component package's
**Package settings → Manage Actions access**. Tag the commit the dev VM runs:

```console
git tag vA.B.C <commit> && git push origin vA.B.C
```

### A product in one repository

When a product's code lives beside its bundle, one repository builds both, and
nothing commits pins back to it:

- `main.yml` builds the code's image with `component-image.yml`, then calls
  `bundle.yml` with `pin: dev`, which resolves the image's `main` in the job
  and commits nothing. The concurrency group makes `main` this run's build, or
  the last one when the code did not change. `version-paths` names the code's
  paths beside `bundle`, so a commit to the code is a new dev version.
- `release.yml` passes `pin: promote`. The release reads the digests from the
  dev bundle its commit was published as (`:<dev version>`, named as before the
  tag existed), and `publish.yml` tags them `bundle-<version>`; the image is
  never rebuilt. `retention.yml` keeps the last 5 dev versions, so a release
  of an older commit is refused: release a newer one.
- `bundle/manifest.yaml` commits the code's image as `repo:main@sha256:000…0`,
  a placeholder only CI fills in. The image is a package of its own, since the
  bundle takes the repository's name.
- A pull request's bundle pins the image `main` points at, not one built from
  the pull request.

```yaml
# .github/workflows/main.yml -- the code's image, then the dev channel
name: main
on:
  push:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: "23 */6 * * *"
permissions: {}
concurrency:
  group: main-bundle
  cancel-in-progress: false
jobs:
  image:
    permissions: { contents: write, packages: write, pull-requests: read }
    uses: morzecrew/bundle-ci/.github/workflows/component-image.yml@v0.4.1
    with:
      component: app
      schema-label: tech.morze.demo.schema
      schema-dir: app/migrations
      images: >-
        [{"name": "app", "image": "demo-app", "context": ".", "file": "containers/app/Dockerfile",
          "paths": ["app/**", "containers/app/**"]}]
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
  bundle:
    needs: image
    permissions: { contents: read, packages: read }
    uses: morzecrew/bundle-ci/.github/workflows/bundle.yml@v0.4.1
    with:
      ref: ${{ github.sha }}
      pin: dev
      version-paths: bundle app containers/app
      components: app
      schema-image: app
      channel: main
      signing: dev
      on-existing: skip # nothing moved since the last run
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
      dev-pubkey: ${{ vars.MINISIGN_DEV_PUBKEY }}
    secrets:
      minisign-key: ${{ secrets.MINISIGN_DEV_KEY }}
  publish:
    needs: bundle
    if: needs.bundle.outputs.proceed == 'true'
    permissions: { contents: read, packages: write }
    uses: morzecrew/bundle-ci/.github/workflows/publish.yml@v0.4.1
    with:
      version: ${{ needs.bundle.outputs.version }}
      archive: ${{ needs.bundle.outputs.archive }}
      channel: main
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
```

`release.yml` is the one above with these inputs to `bundle.yml`, and
`pr.yml` the one above with `components` and `schema-image`:

```yaml
      pin: promote
      version-paths: bundle app containers/app
      components: app
      schema-image: app
```

`component-retention.yml` keeps the image's package beside the bundle's.

## A component repository

A repository whose images a bundle pins calls two workflows:

| Workflow | Job | Needs |
|---|---|---|
| `component-image.yml` | build the images whose paths changed; on `main` push `main` and `sha-<commit>` and tell the bundle repository; on a `vX.Y.Z` tag push `X.Y.Z` and create the GitHub release from the CHANGELOG; on a pull request build only | `contents: write`, `packages: write`, `pull-requests: read` |
| `component-retention.yml` | keep the last commit builds and the newest untagged version | a token secret that may delete package versions |

```yaml
# .github/workflows/build-and-push.yml
name: build-and-push
on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
  pull_request:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: "17 * * * *"
permissions: {}
concurrency:
  group: images-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  images:
    permissions: { contents: write, packages: write, pull-requests: read }
    uses: morzecrew/bundle-ci/.github/workflows/component-image.yml@v0.4.1
    with:
      component: backend
      bundle-repo: demo-standalone
      schema-label: tech.morze.demo.schema
      images: >-
        [
          {"name": "backend", "image": "demo-backend", "context": ".", "file": "containers/app/Dockerfile",
           "build-arg-prefix": "APP__", "paths": ["app/**", "containers/app/**", ".github/workflows/build-and-push.yml"]},
          {"name": "migrations", "image": "demo-migrations", "context": ".", "file": "containers/flyway/Dockerfile",
           "target": "sql", "paths": ["db/**", "containers/flyway/**", ".github/workflows/build-and-push.yml"]}
        ]
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-24.04' }}
      app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
```

```yaml
# .github/workflows/retention-policy.yaml
name: retention
on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:
permissions: {}
jobs:
  retention:
    permissions: {}
    uses: morzecrew/bundle-ci/.github/workflows/component-retention.yml@v0.4.1
    with:
      images: demo-backend demo-migrations
      runs-on: ${{ vars.RUNS_ON || 'ubuntu-latest' }}
    secrets:
      token: ${{ secrets.GH_PAT }}
```

`component-image.yml`'s inputs:

| Input | Default | |
|---|---|---|
| `images` | — | a JSON array of `{name, image, context, file, target?, build-arg-prefix?, paths}`. `image` is the package under the repository's owner; `paths` are the globs whose change rebuilds it (`!` excludes); `build-arg-prefix` names the build args `<prefix>VERSION` (`main` or `X.Y.Z`), `<prefix>BUILD_ID` (the short sha) and `<prefix>GIT_SHA` |
| `component` | — | its name in the dispatch the bundle repository receives |
| `bundle-repo` | — | the bundle repository under the same owner to tell when `main` moves |
| `schema-label`, `schema-dir` | —, `db/migrations/postgres` | a label every image carries with the highest versioned migration in `schema-dir` (`<n>__*.sql`), the schema a bundle declares |
| `tag-version-command` | — | a command printing the version a release tag must name, such as `jq -r .version package.json` |
| `platforms` | `linux/amd64` | what to build for |
| `app-id` | — | the GitHub App whose token dispatches to the bundle repository; without it the bundle picks the images up on its schedule |

A push to `main` rebuilds each image whose `paths` changed since the commit
its `main` was built from, which the image's `org.opencontainers.image.revision`
label names, so a build that failed or was cancelled is caught up by the next
push. An image without a `main`, or one built from a commit outside `main`'s
history, is rebuilt; a re-run of an older push rebuilds nothing. There the
`paths` are git glob pathspecs, which read `dir/**` and a file's path as a pull
request's filter does.

A scheduled run does the same on `main`, so a build that hung or was cancelled
is caught up by the next tick rather than the next push; when every image's
`main` is current it costs a checkout and one registry lookup per image, and
builds nothing. A manual run (`workflow_dispatch`) still rebuilds every image.

The images are plain manifests (`provenance: false`): an attestation would
wrap one in an index whose entries are untagged, which the untagged rule would
delete from under the tag. A component's own release (`vX.Y.Z`) is optional: a
bundle release promotes the `main` builds its dev channel ran.

## Releasing bundle-ci

A called workflow cannot see its own ref, so each one checks bundle-ci out at
`bundle-ci-ref`, whose default names the release. A release:

1. sets every `default: ... # bundle-ci-ref:` line to the coming tag, and seals
   the CHANGELOG, in one pull request (CI refuses defaults that differ):

   ```console
   sed -i -E 's/^( +default: )[^ ]+( # bundle-ci-ref:)/\1vX.Y.Z\2/' .github/workflows/*.yml
   ```

2. tags the merge commit `vX.Y.Z`. `release.yml` refuses a tag that is not on
   `main` or whose defaults name anything else (delete it and release again),
   and otherwise creates the GitHub release with the version's CHANGELOG
   section as its notes.

A caller pinned to `@vX.Y.Z` then runs vX.Y.Z's scripts. To try an unreleased
commit, call the workflows at that commit and pass `bundle-ci-ref` the same
commit.

## Working on bundle-ci

```console
bash tests/pin/run.sh       # needs mikefarah's yq
bash tests/version/run.sh
bash tests/smoke/run.sh     # needs zstd
bash tests/cache/run.sh     # needs mikefarah's yq
bash tests/changed/run.sh   # needs jq
shellcheck -x scripts/*.sh tests/*/*.sh
```

Commits and pull request titles follow `gitmoji-conventional`, and CHANGELOG
entries `keep-a-changelog`: the skills are in `.agents/skills` (`.claude/skills`
links there), installed with `npx skills` and recorded in `skills-lock.json`,
and CI runs their checkers.

This repository is public. Its own CI runs on GitHub-hosted runners only, and
nothing here names a private repository or image: every product name arrives as
an input.
