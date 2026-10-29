#!/usr/bin/env bash
#
# Stands in for the `oras` CLI under tests/pin/run.sh, placed on PATH as
# `oras`. It answers the two calls `scripts/resolve.sh` makes, from the
# reference alone: the digest a tag resolves to, from `oras manifest fetch
# --descriptor`, and the image config, from `oras manifest fetch-config`.
# The migrations image is modelled as a multi-platform index, as a registry
# may publish it: it has no config of its own, so only `--platform
# linux/amd64` returns one. No registry and no network are reached, and
# nothing else is implemented, so a resolver that invents a third call fails
# the test run rather than quietly passing.
#
#   oras manifest fetch --descriptor <repo:tag>
#   oras manifest fetch-config <repo:tag>
#   oras manifest fetch-config --platform linux/amd64 <repo:tag>
set -euo pipefail

# A `repo@digest` names its own digest; a tag gets one derived from the
# reference.
digest_of() {
	case "$1" in
		*@sha256:*) printf '%s\n' "${1##*@}" ;;
		*) printf 'sha256:%s\n' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')" ;;
	esac
}

is_index() {
	case "$1" in
		*-migrations:* | *-migrations@*) return 0 ;;
	esac
	return 1
}

config_of() {
	if is_index "$1"; then
		printf '%s\n' '{"architecture":"amd64","os":"linux","config":{"Labels":{"tech.morze.demo.schema":"0007"}}}'
	else
		printf '%s\n' '{"architecture":"amd64","os":"linux","config":{"Labels":{}}}'
	fi
}

[ "${1:-}" = manifest ] || {
	echo "oras-fixture: unexpected command '${*:-}'" >&2
	exit 1
}
shift
sub=${1:-}
shift || true

case "$sub" in
fetch)
	descriptor=false
	ref=
	while [ $# -gt 0 ]; do
		case "$1" in
		--descriptor)
			descriptor=true
			shift
			;;
		-*)
			echo "oras-fixture: unexpected option '$1' to fetch" >&2
			exit 1
			;;
		*)
			ref=$1
			shift
			;;
		esac
	done
	[ -n "$ref" ] || {
		echo "oras-fixture: fetch needs a reference" >&2
		exit 2
	}
	[ "$descriptor" = true ] || {
		echo "oras-fixture: only 'fetch --descriptor' is supported" >&2
		exit 1
	}
	if is_index "$ref"; then
		media_type=application/vnd.oci.image.index.v1+json
	else
		media_type=application/vnd.oci.image.manifest.v1+json
	fi
	printf '{"mediaType":"%s","digest":"%s","size":1}\n' \
		"$media_type" "$(digest_of "$ref")"
	;;
fetch-config)
	platform=
	ref=
	while [ $# -gt 0 ]; do
		case "$1" in
		--platform)
			[ $# -ge 2 ] || {
				echo "oras-fixture: --platform needs a value" >&2
				exit 2
			}
			platform=$2
			shift 2
			;;
		-*)
			echo "oras-fixture: unexpected option '$1' to fetch-config" >&2
			exit 1
			;;
		*)
			ref=$1
			shift
			;;
		esac
	done
	[ -n "$ref" ] || {
		echo "oras-fixture: fetch-config needs a reference" >&2
		exit 2
	}
	if is_index "$ref" && [ "$platform" != linux/amd64 ]; then
		echo "oras-fixture: \"$(digest_of "$ref")\" is not an image manifest and does not have a config" >&2
		exit 1
	fi
	config_of "$ref"
	;;
*)
	echo "oras-fixture: unexpected subcommand '${sub:-}'" >&2
	exit 1
	;;
esac