#!/usr/bin/env bash
#
# Ask ghcr whether a bundle tag exists, telling "absent" apart from a failure
# to ask: a refused login must never read as "this version is new".
#
#   bash scripts/registry.sh exists ghcr.io/org/repo:tag
#
# Exits 0 when the tag exists, 1 when the registry says it does not, and 2
# for anything else.
set -euo pipefail

if [ "${1:-}" != exists ] || [ $# -ne 2 ]; then
	echo "usage: registry.sh exists <repo:tag>" >&2
	exit 2
fi

if out=$(oras manifest fetch --descriptor "$2" 2>&1); then
	exit 0
fi
case "${out}" in
*"not found"* | *"NOT_FOUND"* | *"MANIFEST_UNKNOWN"* | *"NAME_UNKNOWN"* | *"name unknown"*)
	exit 1
	;;
esac
echo "registry.sh: could not ask the registry about $2: ${out}" >&2
exit 2
