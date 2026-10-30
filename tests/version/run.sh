#!/usr/bin/env bash
#
# Drives scripts/version.sh over throwaway repositories built under mktemp -d,
# so nothing here reads the committed tree or reaches the network.
#
#   bash tests/version/run.sh
#
# It checks that the version names the last commit that changed
# `bundle/` -- a later commit outside it names the same version -- the nearest
# tag's patch is bumped and `-dev.N.g<sha>` appended for every N including 0,
# a bare `X.Y.Z` tag is accepted as a `vX.Y.Z` one is, and the script refuses
# with the reason on stderr when `bundle/` has no commit, no reachable tag, a
# nearest tag that is not `X.Y.Z` or `vX.Y.Z`, or an untracked or modified
# file. VERSION_PATHS adds paths whose commits name a version, and whose dirt
# is refused, and VERSION_EXCLUDE skips a tag on the commit. Success prints
# one line on stdout and nothing on stderr.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../.." && pwd)
script=${repo}/scripts/version.sh

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

err=${work}/stderr

failures=0
ok() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; failures=$((failures + 1)); }

expect() { # expect <what> <expected> <actual>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		fail "$1: expected '$2', got '$3'"
	fi
}

# --- throwaway repositories -------------------------------------------------

# Every commit carries its own identity, so a run needs no global git config.
git_in() { # git_in <tree> <git args...>
	git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"
}

new_repo() { # new_repo <name> -- prints the directory
	local dir=${work}/$1
	mkdir -p "${dir}"
	git -C "${dir}" init -q -b main
	printf '%s\n' "${dir}"
}

commit() { # commit <tree> <message>
	git_in "$1" add -A
	git_in "$1" commit -qm "$2"
}

write() { # write <tree> <path> <contents>
	mkdir -p "$(dirname "$1/$2")"
	printf '%s\n' "$3" >"$1/$2"
}

# The sha `git describe` abbreviates for a revision -- the same abbreviation
# version.sh must print, so it is read back rather than written down here.
described_sha() { # described_sha <tree> <rev>
	git_in "$1" describe --tags --long "$2" | sed -E 's/.*-g//'
}

# A repository whose first commit is outside `bundle/` and carries v0.0.0, and
# whose second commit changes `bundle/`. Prints the tree.
tagged_then_bundle() { # tagged_then_bundle <name>
	local dir
	dir=$(new_repo "$1")
	write "${dir}" top.txt "top"
	commit "${dir}" "top"
	git_in "${dir}" tag v0.0.0
	write "${dir}" bundle/probe.txt "probe"
	commit "${dir}" "bundle"
	printf '%s\n' "${dir}"
}

# A repository whose only commit changes `bundle/`.
only_bundle() { # only_bundle <name>
	local dir
	dir=$(new_repo "$1")
	write "${dir}" bundle/probe.txt "probe"
	commit "${dir}" "bundle"
	printf '%s\n' "${dir}"
}

# --- running the script -----------------------------------------------------

version_at() { # version_at <tree> -- the version, or a failing check and nothing
	local out
	if out=$(VERSION_ROOT="$1" bash "${script}" 2>"${err}"); then
		printf '%s\n' "${out}"
	else
		fail "version.sh refused ${1}: $(tr '\n' ' ' <"${err}")"
	fi
}

expect_version() { # expect_version <what> <tree> <expected>
	local what=$1 tree=$2 want=$3 got rc=0
	got=$(VERSION_ROOT="${tree}" bash "${script}" 2>"${err}") || rc=$?
	if [ "${rc}" -ne 0 ]; then
		fail "${what}: refused: $(tr '\n' ' ' <"${err}")"
		return
	fi
	if [ -s "${err}" ]; then
		fail "${what}: wrote to stderr: $(tr '\n' ' ' <"${err}")"
		return
	fi
	expect "${what}" "${want}" "${got}"
}

expect_refusal() { # expect_refusal <what> <tree> <stderr substring>
	local what=$1 tree=$2 want=$3 got rc=0
	got=$(VERSION_ROOT="${tree}" bash "${script}" 2>"${err}") || rc=$?
	if [ "${rc}" -eq 0 ]; then
		fail "${what}: succeeded, printing '${got}'"
		return
	fi
	if [ -n "${got}" ]; then
		fail "${what}: refused but printed '${got}' on stdout"
		return
	fi
	if grep -qF -- "${want}" "${err}"; then
		ok "${what}"
	else
		fail "${what}: refused, but not for '${want}': $(tr '\n' ' ' <"${err}")"
	fi
}

err_names() { # err_names <substring> <what>
	if grep -qF -- "$1" "${err}"; then
		ok "$2"
	else
		fail "$2: the reason does not name '$1': $(tr '\n' ' ' <"${err}")"
	fi
}

echo "# the last commit that changed bundle/ names the version"
a=$(tagged_then_bundle a)
expect_version "the tag's patch is bumped and N counts the commits since" "${a}" \
	"0.0.1-dev.1.g$(described_sha "${a}" HEAD)"

echo "# a commit outside bundle/ names the version already built"
b=$(tagged_then_bundle b)
before=$(version_at "${b}")
write "${b}" top.txt "top again"
commit "${b}" "top again"
expect "a commit that does not touch bundle/ leaves the version alone" \
	"${before}" "$(version_at "${b}")"
expect_version "and the version still names the bundle commit, not HEAD" "${b}" \
	"0.0.1-dev.1.g$(described_sha "${b}" 'HEAD~1')"

echo "# a tag on the bundle commit itself prints dev.0"
c=$(only_bundle c)
git_in "${c}" tag v0.0.0
expect_version "N=0 is printed too" "${c}" "0.0.1-dev.0.g$(described_sha "${c}" HEAD)"

echo "# a tag needs no v prefix"
d=$(only_bundle d)
git_in "${d}" tag 0.0.0
expect_version "a bare X.Y.Z tag is accepted" "${d}" \
	"0.0.1-dev.0.g$(described_sha "${d}" HEAD)"

echo "# a nearest tag that is not X.Y.Z or vX.Y.Z is refused"
e=$(only_bundle e)
git_in "${e}" tag v0.0.1-rc1
expect_refusal "a prerelease nearest tag" "${e}" "is not X.Y.Z"
err_names "v0.0.1-rc1" "the reason names the tag it read"

echo "# no tag reachable is refused"
f=$(only_bundle f)
expect_refusal "a repository with no tag" "${f}" "no tag is reachable"

echo "# no commit changed bundle/ is refused"
g=$(new_repo g)
write "${g}" top.txt "top"
commit "${g}" "top"
git_in "${g}" tag v0.0.0
expect_refusal "commits outside bundle/ only" "${g}" "no commit changed bundle"

h=$(new_repo h)
expect_refusal "a repository with no commits" "${h}" "no commit changed bundle"

echo "# anything under bundle/ that a commit does not carry is refused"
i=$(tagged_then_bundle i)
write "${i}" bundle/untracked.txt "untracked"
expect_refusal "an untracked file under bundle/" "${i}" "uncommitted changes"
err_names "?? bundle/untracked.txt" "the reason lists the untracked file"

j=$(tagged_then_bundle j)
write "${j}" bundle/probe.txt "changed"
expect_refusal "a modified tracked file under bundle/" "${j}" "uncommitted changes"
err_names " M bundle/probe.txt" "the reason lists the modified file"

echo "# dirt outside bundle/ is not the bundle's"
k=$(tagged_then_bundle k)
write "${k}" notes.txt "uncommitted"
expect_version "a dirty file outside bundle/ does not refuse" "${k}" \
	"0.0.1-dev.1.g$(described_sha "${k}" HEAD)"

echo "# VERSION_PATHS: a product's code names a version too"
m=$(tagged_then_bundle m)
write "${m}" app/main.py "print()"
commit "${m}" "app"
expect_version "by default a commit outside bundle/ keeps the version" "${m}" \
	"0.0.1-dev.1.g$(described_sha "${m}" 'HEAD~1')"
VERSION_PATHS="bundle app" expect_version "a commit under a named path names the version" "${m}" \
	"0.0.1-dev.2.g$(described_sha "${m}" HEAD)"
write "${m}" app/main.py "changed"
VERSION_PATHS="bundle app" expect_refusal "a modified file under a named path" "${m}" "uncommitted changes"
err_names " M app/main.py" "the reason lists the modified file"
expect_version "a path not named is not the bundle's" "${m}" \
	"0.0.1-dev.1.g$(described_sha "${m}" 'HEAD~1')"

echo "# VERSION_EXCLUDE: a release reads the dev version its commit had"
n=$(tagged_then_bundle n)
published=$(version_at "${n}")
git_in "${n}" tag v0.1.0
expect_version "the release's tag is the nearest without it" "${n}" \
	"0.1.1-dev.0.g$(described_sha "${n}" HEAD)"
VERSION_EXCLUDE=v0.1.0 expect_version "skipping it names the version published before" "${n}" "${published}"

# A workflow runs the script from bundle-ci's checkout with the product's
# checkout as its working directory, so the default is the current directory.
echo "# without VERSION_ROOT the script reads the current directory"
if got_default=$(cd "${a}" && bash "${script}" 2>"${err}"); then
	expect "the script reads the repository it runs in" \
		"$(version_at "${a}")" "${got_default}"
else
	fail "the script reads the repository it runs in: $(tr '\n' ' ' <"${err}")"
fi

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "all checks passed"