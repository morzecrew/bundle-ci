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
# layout whose one manifest is named `repo@sha256:<hex>`. A containerd image
# store (Docker 29's default, the rig's) gives a loaded image that name, and
# `docker image inspect <pin>` then finds it, so neither smoke.sh nor morzer
# pulls it again.
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

fill() {
	local dir=$1 pin tmp attempt copied
	shift
	mkdir -p "${dir}"
	for pin in "$@"; do
		entry_of "${dir}" "${pin}"
		if [ -f "${ENTRY}/index.json" ]; then
			touch "${ENTRY}"
			echo "image-cache.sh: cached ${NAME}"
			continue
		fi
		mkdir -p "$(dirname "${ENTRY}")"
		tmp=$(mktemp -d "${dir}/.fill.XXXXXX")
		copied=false
		for attempt in 1 2 3 4; do
			if oras copy --to-oci-layout "${NAME}" "${tmp}:pin" >/dev/null; then
				copied=true
				break
			fi
			[ "${attempt}" -lt 4 ] || break
			echo "image-cache.sh: copying ${NAME} failed (attempt ${attempt}); retrying in $((attempt * 15))s" >&2
			sleep $((attempt * 15))
		done
		if ! "${copied}"; then
			echo "::warning::image-cache.sh: could not copy ${NAME}; the rig pulls it itself"
			rm -rf "${tmp}"
			continue
		fi
		# oras lists the platform manifests it copied beside the tagged one;
		# named too, the last would take the name from it.
		IMAGE=${NAME} yq -i -p json -o json '
			.manifests |= map(select(.annotations."org.opencontainers.image.ref.name" == "pin")) |
			.manifests[0].annotations."io.containerd.image.name" = strenv(IMAGE)' "${tmp}/index.json"
		# Another job may have filled the entry meanwhile; its copy is as good.
		if mv -T "${tmp}" "${ENTRY}" 2>/dev/null; then
			echo "image-cache.sh: copied ${NAME}"
		else
			rm -rf "${tmp}"
			touch "${ENTRY}"
			echo "image-cache.sh: cached ${NAME}"
		fi
	done
}

load() {
	local dir=$1 rig=$2 pin
	shift 2
	for pin in "$@"; do
		entry_of "${dir}" "${pin}"
		if [ ! -f "${ENTRY}/index.json" ]; then
			echo "image-cache.sh: ${NAME} is not cached; the rig pulls it itself"
			continue
		fi
		touch "${ENTRY}"
		tar -C "${ENTRY}" -cf - oci-layout index.json blobs \
			| bash "${self_dir}/rig.sh" exec "${rig}" docker load >/dev/null
		echo "image-cache.sh: loaded ${NAME}"
	done
}

prune() {
	local dir=$1 days=$2
	[[ ${days} =~ ^[0-9]+$ ]] || die "prune takes a number of days, not '${days}'"
	[ -d "${dir}" ] || return 0
	# Entries are directories named by a digest's 64 hex digits; a fill that
	# died midway left a `.fill.*` directory.
	find "${dir}" -mindepth 1 -type d \( -regextype posix-extended -regex '.*/[0-9a-f]{64}' -o -name '.fill.*' \) \
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
