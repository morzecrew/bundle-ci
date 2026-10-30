#!/usr/bin/env bash
#
# Print the dev version of the bundle at HEAD.
#
# The version names the last commit that changed VERSION_PATHS (`bundle/`
# unless told otherwise), not HEAD: a commit outside them ships the version
# already built, and two commits that both change them would otherwise name
# one version twice. That commit is described by its nearest tag and the next
# patch version is taken from it:
#
#   vX.Y.Z-N-g<sha>  ->  X.Y.(Z+1)-dev.N.g<sha>
#
# N is the number of commits since the tag and is printed for every N, 0
# included, with the sha abbreviated as git abbreviates it. The dev channel
# never prints a bare `X.Y.Z`, so it cannot claim a version the release
# workflow publishes.
#
# A product whose bundle and code share one repository names its code's paths
# too, so a commit to the code is a new version. VERSION_EXCLUDE names a tag
# the description skips: a release passes its own, and reads the dev version
# its commit was published as before the tag existed.
#
# The script refuses, exiting non-zero with the reason on stderr, in four
# cases: no commit changed VERSION_PATHS; no tag is reachable from that
# commit; the nearest tag is not `X.Y.Z` or `vX.Y.Z`; or `git status
# --porcelain --untracked-files=all` reports anything under VERSION_PATHS --
# an uncommitted change there would ship without being built.
#
# Environment:
#   VERSION_ROOT     the product repository to read (default: the current directory)
#   VERSION_PATHS    the paths whose commits name a version, space-separated
#                    (default: bundle)
#   VERSION_EXCLUDE  a tag the description skips (default: none)
set -euo pipefail

root=${VERSION_ROOT:-$(pwd)}
read -ra paths <<<"${VERSION_PATHS:-bundle}"
[ ${#paths[@]} -gt 0 ] || paths=(bundle)
exclude=()
[ -z "${VERSION_EXCLUDE:-}" ] || exclude=(--exclude "${VERSION_EXCLUDE}")

die() {
	echo "version.sh: $*" >&2
	exit 1
}

bundle_commit=$(git -C "$root" log -1 --format=%H -- "${paths[@]}" 2>/dev/null || true)
[ -n "$bundle_commit" ] || die "no commit changed ${paths[*]} under ${root}"

described=$(git -C "$root" describe --tags --long ${exclude[@]+"${exclude[@]}"} "$bundle_commit" 2>/dev/null || true)
[ -n "$described" ] || die "no tag is reachable from ${bundle_commit}"

if [[ $described =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)-g([0-9a-f]+)$ ]]; then
	major=${BASH_REMATCH[1]}
	minor=${BASH_REMATCH[2]}
	patch=${BASH_REMATCH[3]}
	count=${BASH_REMATCH[4]}
	sha=${BASH_REMATCH[5]}
else
	tag=$(printf '%s\n' "$described" | sed -E 's/-[0-9]+-g[0-9a-f]+$//')
	die "the nearest tag '${tag}' is not X.Y.Z or vX.Y.Z"
fi

# Anything under the paths that a commit does not carry: an untracked file,
# or a tracked one edited since.
status=$(git -C "$root" status --porcelain --untracked-files=all -- "${paths[@]}" || true)
if [ -n "$status" ]; then
	printf '%s\n' "$status" >&2
	die "${paths[*]} has uncommitted changes under ${root}"
fi

printf '%s\n' "${major}.${minor}.$((10#${patch} + 1))-dev.${count}.g${sha}"