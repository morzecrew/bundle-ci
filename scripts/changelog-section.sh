#!/usr/bin/env bash
#
# Print one version's section of a Keep a Changelog file: what follows
# `## [X.Y.Z]`, up to the next `## [`, without the link definitions the oldest
# section runs into. A release's notes on GitHub.
#
#   bash scripts/changelog-section.sh CHANGELOG.md 1.2.3
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: changelog-section.sh <changelog> <version>" >&2; exit 2; }
section=$(awk -v v="$2" '
	index($0, "## [" v "]") == 1 { on = 1; next }
	on && /^## \[/ { exit }
	on && !/^\[[^]]+\]: / { print }' "$1" | sed -e '/./,$!d')
[ -n "${section}" ] || { echo "changelog-section.sh: $1 has no section for $2" >&2; exit 1; }
printf '%s\n' "${section}"
