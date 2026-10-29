#!/usr/bin/env bash
#
# A runner's cache of the images bundles pin, as OCI layouts on its disk, so a
# smoke job pulls from the registry only what the runner has not seen, and
# loads the rest into its rig from disk.
#
#   image-cache.sh fill <dir> <pin>...         copy each pin not cached yet
#   image-cache.sh load <dir> <rig> <pin>...   load each cached pin into the rig
#   image-cache.sh prune <dir> <days>          drop entries unused for <days>
#
# A pin is `repo[:tag]@sha256:<hex>`, and its entry `<dir>/<repo>/<hex>`: an OCI
# layout whose one descriptor is named `repo@sha256:<hex>`. A containerd image
# store (Docker 29's default, the rig's) gives a loaded image that name, and
# `docker image inspect <pin>` then finds it, so neither smoke.sh nor morzer
# pulls it again. The daemon finds it by the digest only when the pinned
# manifest itself is there: for a multi-platform index, the entry holds the
# index and every manifest it lists, but only IMAGE_CACHE_PLATFORM's layers
# (default linux/amd64), and `load` loads that platform -- the other platforms'
# layers would double what a rig loads, for nothing.
#
# `fill` copies with oras through a temporary directory and renames it into
# place, so two jobs filling one runner's cache never see half an entry. A copy
# that fails 4 times is left to the rig's own pull, with a warning: the cache
# makes a job faster, never one that fails. `fill` and `load` touch the entries
# they use, and `prune` removes what nothing touched for <days>.
#
# Needs oras, logged in to the registry, and mikefarah's yq on PATH.
set -euo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
platform=${IMAGE_CACHE_PLATFORM:-linux/amd64}

die() {
	echo "image-cache.sh: $*" >&2
	exit 1
}

# Sets NAME (`repo@sha256:<hex>`) and ENTRY (`<dir>/<repo>/<hex>`) for a pin.
entry_of() {
	local dir=$1 pin=$2 repo digest
	[[ ${pin} =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]] \
		|| die "'${pin}' is not repo[:tag]@sha256:<hex>"
	digest=${pin##*@}
	repo=${pin%@*}
	# The tag goes; a port in the registry's host stays.
	[[ ${repo##*/} != *:* ]] || repo=${repo%:*}
	NAME=${repo}@${digest}
	ENTRY=${dir}/${repo}/${digest#sha256:}
}

# Copy NAME into the empty layout directory $1.
copy_pin() {
	local tmp=$1 descriptor media hex child blobs=$1/blobs/sha256 repo=${NAME%@*}
	descriptor=$(oras manifest fetch --descriptor "${NAME}") || return 1
	media=$(yq -p json -o yaml '.mediaType' <<<"${descriptor}")
	case "${media}" in
	*image.index* | *manifest.list*)
		oras copy --platform "${platform}" --to-oci-layout "${NAME}" "${tmp}:pin" >/dev/null || return 1
		hex=${NAME##*@sha256:}
		oras manifest fetch "${NAME}" --output "${blobs}/${hex}" || return 1
		echo "${hex}  ${blobs}/${hex}" | sha256sum -c - >/dev/null || return 1
		for child in $(yq -p json -o yaml '.manifests[].digest' "${blobs}/${hex}"); do
			[ -f "${blobs}/${child#sha256:}" ] \
				|| oras manifest fetch "${repo}@${child}" --output "${blobs}/${child#sha256:}" || return 1
		done
		MEDIA=${media} SIZE=$(stat -c %s "${blobs}/${hex}") IMAGE=${NAME} yq -n -o json '{
			"schemaVersion": 2,
			"mediaType": "application/vnd.oci.image.index.v1+json",
			"manifests": [{
				"mediaType": strenv(MEDIA),
				"digest": (strenv(IMAGE) | sub(".*@", "")),
				"size": (strenv(SIZE) | tonumber),
				"annotations": {"io.containerd.image.name": strenv(IMAGE), "org.opencontainers.image.ref.name": "pin"}}]}' \
			>"${tmp}/index.json"
		printf '%s\n' "${platform}" >"${tmp}/platform"
		;;
	*)
		oras copy --to-oci-layout "${NAME}" "${tmp}:pin" >/dev/null || return 1
		# oras lists the platform manifests it copied beside the tagged one;
		# named too, the last would take the name from it.
		IMAGE=${NAME} yq -i -p json -o json '
			.manifests |= map(select(.annotations."org.opencontainers.image.ref.name" == "pin")) |
			.manifests[0].annotations."io.containerd.image.name" = strenv(IMAGE)' "${tmp}/index.json"
		;;
	esac
}

# Fill one entry, ENTRY for NAME; the caller holds its lock.
fill_one() {
	local tmp attempt copied=false
	if [ -f "${ENTRY}/index.json" ]; then
		touch "${ENTRY}"
		echo "image-cache.sh: cached ${NAME}"
		return 0
	fi
	for attempt in 1 2 3 4; do
		tmp=$(mktemp -d "$(dirname "${ENTRY}")/.fill.XXXXXX")
		if copy_pin "${tmp}"; then
			copied=true
			break
		fi
		rm -rf "${tmp}"
		[ "${attempt}" -lt 4 ] || break
		echo "image-cache.sh: copying ${NAME} failed (attempt ${attempt}); retrying in $((attempt * 15))s" >&2
		sleep $((attempt * 15))
	done
	if ! "${copied}"; then
		echo "::warning::image-cache.sh: could not copy ${NAME}; the rig pulls it itself"
		return 0
	fi
	# A runner without flock lets two jobs copy one entry; the second's
	# rename then fails, and the first's copy is as good.
	if mv -T "${tmp}" "${ENTRY}" 2>/dev/null; then
		echo "image-cache.sh: copied ${NAME}"
	else
		rm -rf "${tmp}"
		touch "${ENTRY}"
		echo "image-cache.sh: cached ${NAME}"
	fi
}

fill() {
	local dir=$1 pin
	shift
	mkdir -p "${dir}"
	for pin in "$@"; do
		entry_of "${dir}" "${pin}"
		mkdir -p "$(dirname "${ENTRY}")"
		# One job copies an entry while another sharing the runner's disk
		# waits for it, and then finds it cached rather than copying it twice.
		if command -v flock >/dev/null 2>&1; then
			(
				flock 9
				fill_one
			) 9>"${ENTRY}.lock"
		else
			fill_one
		fi
	done
}

# Load one entry into the rig, tried twice: a load that fails leaves the image
# to the rig's own pull, with a warning.
load_one() {
	local entry=$1 name=$2 rig=$3 attempt args=()
	# An index's entry holds one platform's layers: load that platform.
	[ ! -f "${entry}/platform" ] || args=(--platform "$(cat "${entry}/platform")")
	for attempt in 1 2; do
		if tar -C "${entry}" -cf - oci-layout index.json blobs \
			| bash "${self_dir}/rig.sh" exec "${rig}" docker load ${args[@]+"${args[@]}"} >/dev/null; then
			echo "image-cache.sh: loaded ${name}"
			return 0
		fi
		echo "image-cache.sh: loading ${name} failed (attempt ${attempt})" >&2
	done
	echo "::warning::image-cache.sh: could not load ${name}; the rig pulls it itself"
}

# Every image at once: loading is mostly unpacking layers, and one image's
# does not wait for another's.
load() {
	local dir=$1 rig=$2 pin pids=() pid
	shift 2
	for pin in "$@"; do
		entry_of "${dir}" "${pin}"
		if [ ! -f "${ENTRY}/index.json" ]; then
			echo "image-cache.sh: ${NAME} is not cached; the rig pulls it itself"
			continue
		fi
		touch "${ENTRY}"
		load_one "${ENTRY}" "${NAME}" "${rig}" &
		pids+=("$!")
	done
	for pid in ${pids[@]+"${pids[@]}"}; do
		wait "${pid}"
	done
}

prune() {
	local dir=$1 days=$2
	[[ ${days} =~ ^[0-9]+$ ]] || die "prune takes a number of days, not '${days}'"
	[ -d "${dir}" ] || return 0
	# Entries are directories named by a digest's 64 hex digits, each with a
	# `.lock` beside it; a fill that died midway left a `.fill.*` directory.
	find "${dir}" -mindepth 1 -regextype posix-extended \( \
		\( -type d \( -regex '.*/[0-9a-f]{64}' -o -name '.fill.*' \) \) \
		-o \( -type f -regex '.*/[0-9a-f]{64}\.lock' \) \) \
		-mtime "+${days}" -prune -exec rm -rf {} +
	find "${dir}" -mindepth 1 -type d -empty -delete
}

case "${1:-}" in
fill)
	[ $# -ge 2 ] || die "usage: image-cache.sh fill <dir> <pin>..."
	shift
	fill "$@"
	;;
load)
	[ $# -ge 3 ] || die "usage: image-cache.sh load <dir> <rig> <pin>..."
	shift
	load "$@"
	;;
prune)
	[ $# -eq 3 ] || die "usage: image-cache.sh prune <dir> <days>"
	prune "$2" "$3"
	;;
*) die "usage: image-cache.sh fill|load|prune" ;;
esac
