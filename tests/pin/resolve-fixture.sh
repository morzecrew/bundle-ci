#!/usr/bin/env bash
#
# Stands in for `scripts/resolve.sh` under tests/pin/run.sh, with the same
# contract -- line 1 the digest a tag or digest resolves to, `schema=<value>` on line 2
# when the image carries the schema label -- answered from
# the reference itself, so a test run reaches no registry.
#
#   tests/pin/resolve-fixture.sh ghcr.io/acme/demo-migrations:main
#   sha256:9f2c...
#   schema=0007
#
# The label is zero-padded, as the migrations image's is, so a caller that
# records it as an integer is tested doing so.
set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: resolve-fixture.sh <repo:tag>" >&2
	exit 2
fi

ref=$1
case "$ref" in
	# A digest a registry no longer holds: the components' retention pruned it.
	*@sha256:deadbeef*)
		echo "resolve-fixture: ${ref}: not found" >&2
		exit 1
		;;
	# A digest resolves to itself, as `oras manifest fetch --descriptor` says.
	*@sha256:*) printf '%s\n' "${ref##*@}" ;;
	*) printf 'sha256:%s\n' "$(printf '%s' "$ref" | sha256sum | awk '{print $1}')" ;;
esac

case "$ref" in
	*-migrations:* | *-migrations@*) printf 'schema=0007\n' ;;
esac