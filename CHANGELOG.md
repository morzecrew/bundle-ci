# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/morzecrew/bundle-ci/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/morzecrew/bundle-ci/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/morzecrew/bundle-ci/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/morzecrew/bundle-ci/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/morzecrew/bundle-ci/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/morzecrew/bundle-ci/releases/tag/v0.1.0
