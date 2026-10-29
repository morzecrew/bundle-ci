# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- A caller pinned to a release runs that release's scripts. v0.1.0's workflows checked bundle-ci out at `main` unless the caller passed `bundle-ci-ref`; their defaults now name the release.

## [0.1.0] - 2026-10-29

### Added

- Reusable workflows for a morzer bundle repository: `pin.yml` (the dev channel's pin and commit), `guard.yml` (a release tag's check), `bundle.yml` (build, sign, and smoke-test a fresh install and an update in a Docker-in-Docker rig), `publish.yml` (push a version, move its channel, and tag a release's component images `bundle-<version>`) and `retention.yml`.
- `scripts/rehearse.sh` runs the smoke jobs' install, hooks, update and rollback on a workstation, from a product's root.
- A product names its component keys, schema label, operator secrets and probe paths as inputs, and adds its own smoke checks as hooks in `.github/smoke.d`.

[Unreleased]: https://github.com/morzecrew/bundle-ci/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/morzecrew/bundle-ci/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/morzecrew/bundle-ci/releases/tag/v0.1.0
