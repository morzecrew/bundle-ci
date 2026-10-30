#!/usr/bin/env bash
#
# Pin a bundle's component images in `bundle/manifest.yaml` to their digests,
# and record the schema label one of them carries in the three
# `compatibility.database_schema_*` fields. `--release` also writes
# `compatibility.rollback_safe`, true only when every components.yaml entry
# declares it; plain pinning leaves it as committed. No other value in the
# manifest changes, and a second run leaves the file byte-identical.
#
#   scripts/pin.sh                  pin `main` -- the dev channel
#   scripts/pin.sh --release X.Y.Z  promote the committed pins as release X.Y.Z
#
# The dev channel pins the digest each component's `main` points at right now.
# A release ships what the dev channel installed and smoke-tested, so
# `--release` resolves no tag: it keeps each digest the committed manifest
# pins and names it under the tag `bundle-X.Y.Z`, which publish.yml then puts
# on the image so the components' retention keeps it. It refuses the all-zero
# placeholder and a digest the registry no longer holds. A product whose
# bundle shares its repository with its code commits no pins: its release
# reads them from the dev bundle the tagged commit was published as, which
# PIN_FROM names.
#
# Every pin is resolved before the manifest is written, so a refusal leaves it
# as it was. The digests come from `scripts/resolve.sh`, which reaches the
# registry; tests/pin/run.sh points RESOLVE at a fixture instead.
#
# Environment:
#   PIN_ROOT          the product repository (default: the current directory)
#   RESOLVE           the resolver to call (default: resolve.sh beside this script)
#   PIN_COMPONENTS    the `images:` keys to pin (default: backend migrations frontend)
#   PIN_SCHEMA_IMAGE  the key whose image carries the schema label (default:
#                     migrations; set it empty when no image does)
#   SCHEMA_LABEL      the label (default: tech.morze.<metadata.name>.schema)
#   PIN_FROM          the manifest whose digests `--release` promotes (default:
#                     bundle/manifest.yaml, the committed pins)
set -euo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${PIN_ROOT:-$(pwd)}
resolve=${RESOLVE:-"${self_dir}/resolve.sh"}
pin_components=${PIN_COMPONENTS:-backend migrations frontend}
schema_image=${PIN_SCHEMA_IMAGE-migrations}

manifest=${root}/bundle/manifest.yaml
components=${root}/components.yaml
pinned_from=${PIN_FROM:-${manifest}}

die() {
	echo "pin.sh: $*" >&2
	exit 1
}

usage() {
	echo "usage: pin.sh [--release X.Y.Z]"
}

release=false
version=
while [ $# -gt 0 ]; do
	case "$1" in
		--release)
			[ $# -ge 2 ] || die "--release takes the release's version ($(usage))"
			release=true
			version=$2
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*) die "unknown argument '$1' ($(usage))" ;;
	esac
	shift
done
if $release; then
	[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "--release takes the release's X.Y.Z, not '${version}'"
fi

[ -f "$manifest" ] || die "no bundle/manifest.yaml under ${root}"
[ -f "$pinned_from" ] || die "PIN_FROM: no manifest at ${pinned_from}"
[ -f "$resolve" ] || die "no resolver at ${resolve}"

product=$(yq -r '.metadata.name // ""' "$manifest")
export SCHEMA_LABEL=${SCHEMA_LABEL:-tech.morze.${product}.schema}

# The repository an image key is pinned in, without its tag and digest:
# `ghcr.io/acme/demo-backend:main@sha256:...` -> `ghcr.io/acme/demo-backend`.
repo_of() {
	local value
	value=$(yq -r ".images.$1" "$manifest")
	case "$value" in
		'' | null) die "bundle/manifest.yaml names no images.$1" ;;
	esac
	printf '%s\n' "${value%@sha256:*}" | sed -E 's/:[^:/]+$//'
}

# Ask the resolver about a `repo:tag` or `repo@digest`, leaving its answer in
# RESOLVED_DIGEST and RESOLVED_SCHEMA (empty when the image carries no schema
# label).
resolve_ref() {
	local out
	out=$("$resolve" "$1") || die "the resolver failed for $1${resolve_hint}"
	RESOLVED_DIGEST=$(printf '%s\n' "$out" | sed -n '1p')
	RESOLVED_SCHEMA=$(printf '%s\n' "$out" | sed -n 's/^schema=//p' | sed -n '1p')
	[[ $RESOLVED_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] \
		|| die "the resolver printed no digest for $1: '${RESOLVED_DIGEST}'"
}

# Whether a rollback is safe, as components.yaml declares it for one
# component. Only a YAML boolean is a release input: a quoted `"true"` is a
# string, which is a wrong value, not a truthy one.
rollback_safe_of() {
	local name=$1
	yq -e ".${name}.rollback_safe | tag == \"!!bool\"" "$components" >/dev/null 2>&1 \
		|| die "components.yaml: ${name}.rollback_safe is not true or false"
	yq -r ".${name}.rollback_safe" "$components"
}

# The digest the dev channel pinned an image key to: the committed manifest's,
# or PIN_FROM's. The all-zero placeholder a new bundle starts with is no pin at
# all: nothing the dev channel installed.
committed_digest() {
	local value digest name
	name=${pinned_from#"${root}/"}
	value=$(yq -r ".images.$1" "$pinned_from")
	digest=${value##*@}
	[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] \
		|| die "${name} pins images.$1 to no digest: '${value}'"
	if [[ $digest =~ ^sha256:0+$ ]]; then
		die "${name}'s images.$1 holds the placeholder digest; a release promotes what main.yml pinned"
	fi
	printf '%s\n' "$digest"
}

# Pin one image key, leaving the pin in PINNED: the digest `main` points at on
# the dev channel, and in a release the committed digest under `bundle-X.Y.Z`.
pin_component() {
	local repo digest
	repo=$(repo_of "$1")
	if $release; then
		digest=$(committed_digest "$1")
		resolve_ref "${repo}@${digest}"
		PINNED="${repo}:bundle-${version}@${RESOLVED_DIGEST}"
	else
		resolve_ref "${repo}:main"
		PINNED="${repo}:main@${RESOLVED_DIGEST}"
	fi
}

resolve_hint=
if $release; then
	[ -f "$components" ] || die "no components.yaml under ${root}; release mode reads rollback_safe from it"
	# A rollback is safe only when every component's is; the conjunction is
	# what the bundle declares.
	entries=$(yq -r 'keys | .[]' "$components")
	[ -n "$entries" ] || die "components.yaml names no component"
	rollback_safe=true
	for entry in $entries; do
		safe=$(rollback_safe_of "$entry")
		[ "$safe" = true ] || rollback_safe=false
	done
	resolve_hint="; the registry no longer holds the digest the dev channel pinned, which the component's retention prunes, so release a newer commit of main"
fi

pins=()
schema=
schema_seen=false
for key in $pin_components; do
	[[ $key =~ ^[a-z][a-z0-9_]*$ ]] || die "PIN_COMPONENTS: '${key}' is not an images: key"
	pin_component "$key"
	pins+=("${key}=${PINNED}")
	[ "$key" = "$schema_image" ] || continue
	schema_seen=true
	schema=${RESOLVED_SCHEMA}
	[ -n "$schema" ] \
		|| die "${PINNED} carries no ${SCHEMA_LABEL} label; the bundle cannot say which schema it produces"
	[[ $schema =~ ^[0-9]+$ ]] \
		|| die "${PINNED}'s ${SCHEMA_LABEL} label is '${schema}', not a number"
	# The three fields are integers and a label may be zero-padded (`0007`),
	# which YAML would read as octal; pin the number itself.
	schema=$((10#$schema))
done
[ ${#pins[@]} -gt 0 ] || die "PIN_COMPONENTS names no component"
if [ -n "$schema_image" ] && ! $schema_seen; then
	die "PIN_SCHEMA_IMAGE '${schema_image}' is not one of PIN_COMPONENTS (${pin_components})"
fi

# Only the component pins and the three schema fields are written; release
# mode adds `compatibility.rollback_safe`, so a plain pin leaves the committed
# value alone. `yq` re-emits the document, so the manifest keeps its keys,
# values and comments and loses only the blank lines between its sections.
update=
i=0
for entry in "${pins[@]}"; do
	export "PIN_${i}=${entry#*=}"
	update="${update}${update:+ | }.images.${entry%%=*} = strenv(PIN_${i})"
	i=$((i + 1))
done
if [ -n "$schema_image" ]; then
	export PIN_SCHEMA=$schema
	update="${update} |
	.compatibility.database_schema_produces = (strenv(PIN_SCHEMA) | tonumber) |
	.compatibility.database_schema_min = (strenv(PIN_SCHEMA) | tonumber) |
	.compatibility.database_schema_max = (strenv(PIN_SCHEMA) | tonumber)"
fi
if $release; then
	update="${update} | .compatibility.rollback_safe = ${rollback_safe}"
fi
yq -i "$update" "$manifest"

for entry in "${pins[@]}"; do
	printf 'pin.sh: %-12s %s\n' "${entry%%=*}" "${entry#*=}"
done
if [ -n "$schema_image" ]; then
	printf 'pin.sh: schema %s, from %s\n' "$schema" "$schema_image"
fi
if $release; then
	printf 'pin.sh: rollback_safe %s\n' "$rollback_safe"
fi
