# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The rig and the build install morzer 0.13.0, up from 0.12.0, so a bundle that declares `compatibility.database: none`, which needs 0.13.0, can be built and smoke-tested. Under 0.13.0, `update` refuses a release older than the one installed, and `doctor` exits 3 when a running service is unhealthy or a release health check fails.

### Fixed

- `smoke.sh update` passes `--allow-older`, so the smoke update of a pull request's build, versioned `0.0.0-pr.N`, and `rehearse.sh`'s update run under morzer 0.13.0, which refuses an update to a version that sorts below the installed one.

## [0.6.0] - 2026-11-07

### Added

- A second bundle in one repository. `bundle.yml` takes `bundle-dir` (default `bundle`), `package` (default the repository's name) and `tag-prefix` (default `v`); `publish.yml` takes `package` and `guard.yml` takes `tag-prefix`, as `retention.yml` already took `package`. `rehearse.sh` reads `REHEARSE_BUNDLE_DIR`, and `pin.sh` reads `PIN_BUNDLE_DIR`.
- `version.sh` reads `VERSION_TAG_PREFIX`: only tags `<prefix>X.Y.Z` are described, and any other tag is passed over.

### Changed

- `bundle.yml` passes `tag-prefix` to `version.sh`, so a dev version counts from the nearest `vX.Y.Z` tag and passes over any other tag. A nearer tag that is not `vX.Y.Z`, such as a bare `X.Y.Z` or another bundle's, no longer refuses the build.

### Fixed

- `rehearse.sh` skips the HTTP probe when `REHEARSE_PROBE_PATHS` is empty, as `bundle.yml` does for an empty `probe-paths`. It probed the default paths instead, so a product with no health port, such as dotdash, failed the rehearsal at the first probe.

## [0.5.0] - 2026-11-07

### Added

- Pre-apply smoke hooks: `.github/smoke.d/pre-apply/*.sh` run inside `smoke.sh install`, after `morzer init` and the operator secrets and before the first `apply`, in `smoke-install`, in `smoke-update`'s install of the published bundle, and in `rehearse.sh`. A bundle that needs a domain, a parameter with no default, or a service it reaches before it can apply can now be smoke-tested. `smoke-update` checks out the product for them.
- `init-args` (`REHEARSE_INIT_ARGS` for `rehearse.sh`): what each smoke install adds to `morzer init`, such as `--domain` and a `--set` for each parameter with no default, which `init` refuses without.

### Changed

- The rig and the build install morzer 0.12.0, up from 0.9.0, so a bundle whose `min_manager_version` is above 0.9.0 can be built and smoke-tested.

## [0.4.1] - 2026-10-30

### Fixed

- `component-image.yml` tells the bundle repository again on a runner behind a proxy. `actions/create-github-app-token` v3 refused to run when `HTTPS_PROXY` was set ("Node.js native proxy support is not enabled"), so the bundle repository waited for its schedule. The token step now sets `NODE_USE_ENV_PROXY=1`.

## [0.4.0] - 2026-10-30

### Added

- `component-image.yml` catches up a lost build on a schedule: a scheduled run on `main` rebuilds only the images whose `main` lags, as a push does, instead of every image. A build that hung or was cancelled no longer waits for the next push. The README's component example runs hourly.

### Changed

- Every job has a `timeout-minutes`: 60 for an image build, 45 per smoke job, 30 for a bundle build, 10 to 20 otherwise. A job on a hung self-hosted runner now fails then, instead of holding the caller's concurrency group for GitHub's 360 minutes.

## [0.3.1] - 2026-10-30

### Fixed

- `component-image.yml` no longer leaves a change unbuilt when a push's build fails or is cancelled. A push to `main` rebuilt the images whose paths changed since the push's previous commit, so a migration whose own build was lost stayed out of `main` while the next push rebuilt only the backend, and the bundle paired them. It now rebuilds each image whose paths changed since the commit its `main` was built from, as the image's `org.opencontainers.image.revision` label names it.

## [0.3.0] - 2026-10-30

### Added

- A product whose code shares one repository with its bundle builds both without committing pins back to it. `bundle.yml`'s `version-paths` names the code's paths beside `bundle`, so a commit to the code is a new dev version, and `pin: dev` with no `version` now works: the version is named before the pin edits the manifest. `pin: promote` releases the digests of the dev bundle the tagged commit was published as, and refuses a commit whose dev bundle retention pruned. The README's "A product in one repository" shows the callers.

## [0.2.1] - 2026-10-30

### Fixed

- An empty `probe-paths` no longer falls back to the default paths: a bundle that serves no HTTP passes it, and the smoke jobs skip the HTTP probe, leaving the health checks morzer runs at every apply.

## [0.2.0] - 2026-10-30

### Added

- `component-image.yml`, for a repository whose images a bundle pins. It builds the images whose paths changed (an `images` JSON input of name, package, context, Dockerfile, target, build-arg prefix and paths), pushes `main` and `sha-<commit>` from `main` and `X.Y.Z` from a release tag, labels each with the schema its migrations produce, tells the bundle repository through a GitHub App token limited to Contents write, and creates a release tag's GitHub release from the CHANGELOG and the image list.
- `component-retention.yml`, which keeps a component's last commit builds and newest untagged version, and never a version a release or `main` also tags.
- On a self-hosted runner, the smoke jobs keep every image a bundle pins in a cache on the runner's disk (`scripts/image-cache.sh`, OCI layouts under `~/.cache/bundle-ci/oci`, a multi-platform index with only `linux/amd64`'s layers) and load them into each rig, so the registry is asked only for images the runner has not seen. Images load into the rig in parallel. A copy that fails 4 times, or a load that fails twice, falls back to the rig's own pull; jobs sharing a runner copy an image once; entries unused for 14 days are pruned. `image-cache: false` turns it off.

## [0.1.2] - 2026-10-29

### Fixed

- A registry that drops one connection no longer fails a smoke job. `smoke.sh install` and `update` pull every image the archive pins by digest first, each tried up to 4 times with a growing pause, and morzer finds them present; a pull that fails 4 times stops the job and names the image.

## [0.1.1] - 2026-10-29

### Fixed

- A caller pinned to a release runs that release's scripts. v0.1.0's workflows checked bundle-ci out at `main` unless the caller passed `bundle-ci-ref`; their defaults now name the release.

## [0.1.0] - 2026-10-29

### Added

- Reusable workflows for a morzer bundle repository: `pin.yml` (the dev channel's pin and commit), `guard.yml` (a release tag's check), `bundle.yml` (build, sign, and smoke-test a fresh install and an update in a Docker-in-Docker rig), `publish.yml` (push a version, move its channel, and tag a release's component images `bundle-<version>`) and `retention.yml`.
- `scripts/rehearse.sh` runs the smoke jobs' install, hooks, update and rollback on a workstation, from a product's root.
- A product names its component keys, schema label, operator secrets and probe paths as inputs, and adds its own smoke checks as hooks in `.github/smoke.d`.

[Unreleased]: https://github.com/morzecrew/bundle-ci/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/morzecrew/bundle-ci/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/morzecrew/bundle-ci/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/morzecrew/bundle-ci/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/morzecrew/bundle-ci/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/morzecrew/bundle-ci/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/morzecrew/bundle-ci/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/morzecrew/bundle-ci/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/morzecrew/bundle-ci/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/morzecrew/bundle-ci/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/morzecrew/bundle-ci/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/morzecrew/bundle-ci/releases/tag/v0.1.0
