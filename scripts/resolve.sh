#!/usr/bin/env bash
#
# Resolve an image reference to the digest it points at, and report the
# schema label the image carries.
#
#   SCHEMA_LABEL=tech.morze.demo.schema scripts/resolve.sh ghcr.io/acme/demo-backend:main
#   sha256:6f1c...
#
#   SCHEMA_LABEL=tech.morze.demo.schema scripts/resolve.sh ghcr.io/acme/demo-migrations:main
#   sha256:9b0d...
#   schema=0007
#
# Line one is always the digest, read from the registry with `oras manifest
# fetch --descriptor`; a `repo@digest` resolves to itself when the registry
# still holds it. Line two appears only when the image carries the label
# SCHEMA_LABEL names -- a migrations image does -- so a reader learns which
# schema a release produces without running it. Without SCHEMA_LABEL there is
# no line two.
#
# This reaches the registry, so it needs the network and a logged-in `oras`;
# tests/pin/run.sh stands an `oras` fixture in for the registry.
set -euo pipefail

schema_label=${SCHEMA_LABEL:-}

if [ $# -ne 1 ]; then
	echo "usage: resolve.sh <repo:tag>" >&2
	exit 2
fi

ref=$1
case "$ref" in
	*:*) ;;
	*)
		echo "resolve.sh: '${ref}' names no tag; pass a repo:tag" >&2
		exit 2
		;;
esac

digest=$(oras manifest fetch --descriptor "$ref" | jq -r '.digest')
case "$digest" in
	sha256:*) ;;
	*)
		echo "resolve.sh: '${ref}' resolved to '${digest}', which is not a digest" >&2
		exit 1
		;;
esac
printf '%s\n' "$digest"

# A multi-platform index has no config of its own; its linux/amd64 manifest
# does. Ask for the tag's own config first -- a single-platform image has one
# -- and fall back to the platform's manifest when it is an index. An image
# with no config at all simply reports no label.
[ -n "$schema_label" ] || exit 0
labels=$(oras manifest fetch-config "$ref" 2>/dev/null \
	|| oras manifest fetch-config --platform linux/amd64 "$ref" 2>/dev/null || true)
schema=$(printf '%s' "$labels" \
	| jq -r --arg key "$schema_label" '(.config.Labels // {})[$key] // empty' 2>/dev/null || true)
if [ -n "$schema" ]; then
	printf 'schema=%s\n' "$schema"
fi