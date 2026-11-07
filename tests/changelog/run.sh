#!/usr/bin/env bash
#
# changelog-section.sh prints the section a version heads and nothing around
# it, takes 1.2.3 for 1.2.3 and never for 1.2.30, and refuses a version with
# no section.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
expect() { # <what> <want> <got>
	if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: expected '$2', got '$3'"; failed=1; fi
}

cat >"${work}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.30] - 2026-11-07

### Fixed

- Thirty.

## [1.2.3] - 2026-11-01

### Added

- Three.

[Unreleased]: https://example.com/compare/v1.2.30...HEAD
[1.2.30]: https://example.com/compare/v1.2.3...v1.2.30
[1.2.3]: https://example.com/releases/tag/v1.2.3
EOF
section() { bash "${repo}/scripts/changelog-section.sh" "${work}/CHANGELOG.md" "$1"; }

expect "a middle section, to the next heading" $'### Fixed\n\n- Thirty.' "$(section 1.2.30)"
expect "the oldest, without the links" $'### Added\n\n- Three.' "$(section 1.2.3)"
if out=$(section 1.2 2>&1); then
	expect "a version with no section refuses" "a refusal" "${out}"
else
	expect "a version with no section refuses, naming it" 1 "$(grep -c 'no section for 1.2$' <<<"${out}")"
fi

[ "${failed}" -eq 0 ] || { echo "check(s) failed"; exit 1; }
