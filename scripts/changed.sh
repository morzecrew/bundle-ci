#!/usr/bin/env bash
#
# Which of a component's images a push to main rebuilds: each whose paths
# changed since the commit its `main` was built from, as the image's
# `org.opencontainers.image.revision` label names it. Not since the push's
# previous commit: a build that failed or was cancelled would leave its change
# unbuilt until the paths changed again, and the bundle would pin an image
# that lacks it.
#
#   changed.sh '<images JSON>'   prints the JSON array of the images to build
#
# An image is built when its `main` cannot be read or carries no revision, or
# when that revision is not in HEAD's history (a rewritten main). It is not
# built when HEAD is that revision or older: a re-run of an earlier push never
# moves `main` back. Each `paths` entry is a git glob pathspec (`app/**`); one
# starting with `!` excludes. The reason for each image goes to stderr.
#
# Needs git with HEAD's history, jq, and oras logged in to the registry.
#
# Environment:
#   CHANGED_ROOT   the repository to read (default: the current directory)
#   CHANGED_OWNER  the packages' owner (default: GITHUB_REPOSITORY_OWNER)
set -euo pipefail

root=${CHANGED_ROOT:-$(pwd)}
owner=${CHANGED_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}

die() {
	echo "changed.sh: $*" >&2
	exit 1
}

[ $# -eq 1 ] || die "usage: changed.sh '<images JSON>'"
[ -n "${owner}" ] || die "no CHANGED_OWNER or GITHUB_REPOSITORY_OWNER"
images=$1
count=$(jq 'length' <<<"${images}") || die "the images are not a JSON array"
head=$(git -C "${root}" rev-parse HEAD)

# The commit an image's `main` was built from, or nothing. A multi-platform
# index has no config of its own; its linux/amd64 manifest does.
revision_of() {
	local ref=ghcr.io/${owner}/$1:main config
	config=$(oras manifest fetch-config "${ref}" 2>/dev/null \
		|| oras manifest fetch-config --platform linux/amd64 "${ref}" 2>/dev/null) || return 0
	jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"${config}" 2>/dev/null || true
}

# Whether the image needs a build, with the reason on stderr.
stale() {
	local name=$1 image=$2 rev pathspecs=() path
	rev=$(revision_of "${image}")
	if [ -z "${rev}" ]; then
		echo "changed.sh: ${name}: ${image}:main has no revision to compare with; building" >&2
		return 0
	fi
	if git -C "${root}" cat-file -e "${rev}^{commit}" 2>/dev/null \
		&& git -C "${root}" merge-base --is-ancestor "${head}" "${rev}"; then
		echo "changed.sh: ${name}: ${image}:main is built from ${rev::8}, this commit or a later one; not building" >&2
		return 1
	fi
	if ! git -C "${root}" merge-base --is-ancestor "${rev}" "${head}" 2>/dev/null; then
		echo "changed.sh: ${name}: ${image}:main is built from ${rev::8}, which is not in this commit's history; building" >&2
		return 0
	fi
	while IFS= read -r path; do
		case "${path}" in
		!*) pathspecs+=(":(exclude,glob)${path#!}") ;;
		*) pathspecs+=(":(glob)${path}") ;;
		esac
	done < <(jq -r --arg n "${name}" '.[] | select(.name == $n) | .paths[]' <<<"${images}")
	if git -C "${root}" diff --quiet "${rev}" "${head}" -- "${pathspecs[@]}"; then
		echo "changed.sh: ${name}: nothing under its paths changed since ${rev::8}; not building" >&2
		return 1
	fi
	echo "changed.sh: ${name}: its paths changed since ${rev::8}; building" >&2
}

build=()
for ((i = 0; i < count; i++)); do
	name=$(jq -r ".[${i}].name" <<<"${images}")
	image=$(jq -r ".[${i}].image" <<<"${images}")
	if stale "${name}" "${image}"; then
		build+=("${name}")
	fi
done

jq -c 'map(select(.name as $n | $ARGS.positional | index($n)))' --args ${build[@]+"${build[@]}"} <<<"${images}"
