#!/usr/bin/env bash
#
# Drives scripts/changed.sh over a throwaway repository, with a stand-in
# `oras` on PATH that answers each image's `main` config from files under the
# test's directory, so nothing here reaches a registry.
#
#   bash tests/changed/run.sh
#
# It checks that an image is built when its paths changed since the revision
# its `main` carries, even when the push's own commit touched only another
# image's paths (the build of the commit between was lost); not built when
# nothing under its paths changed, when an excluded path is all that changed,
# or when HEAD is that revision or older; and built when `main` is missing,
# has no revision, or names a commit outside HEAD's history. A multi-platform
# index's revision is read from its linux/amd64 config. The output keeps the
# input's entries and order.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../.." && pwd)
script=${repo}/scripts/changed.sh

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

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

# The stand-in registry: `${registry}/<image>` holds the config of
# `ghcr.io/acme/<image>:main`; a `<image>.index` beside it makes it a
# multi-platform index, whose config only `--platform linux/amd64` returns.
registry=${work}/registry
mkdir -p "${registry}" "${work}/bin"
cat >"${work}/bin/oras" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\$1 \$2" = "manifest fetch-config" ] || { echo "oras stub: unexpected \$*" >&2; exit 2; }
shift 2
platform=
if [ "\$1" = --platform ]; then platform=\$2; shift 2; fi
ref=\$1
image=\${ref#ghcr.io/acme/}
image=\${image%:main}
[ -f "${registry}/\${image}" ] || { echo "\${ref}: not found" >&2; exit 1; }
if [ -f "${registry}/\${image}.index" ] && [ "\${platform}" != linux/amd64 ]; then
	echo "\${ref} is not an image manifest" >&2
	exit 1
fi
cat "${registry}/\${image}"
EOF
chmod +x "${work}/bin/oras"
export PATH="${work}/bin:${PATH}"

built_from() { # built_from <image> <revision> -- <image>:main carries the revision
	printf '{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}\n' "$2" >"${registry}/$1"
}

# A component of two images: the backend from app/, the migrations from db/
# except its README.
images='[
  {"name": "backend", "image": "demo-backend", "paths": ["app/**"]},
  {"name": "migrations", "image": "demo-migrations", "paths": ["db/**", "!db/README.md"]}
]'

tree=${work}/tree
git init -q -b main "${tree}"
commit() { # commit <path> <message> -- prints the new commit
	mkdir -p "$(dirname "${tree}/$1")"
	printf '%s\n' "$2" >>"${tree}/$1"
	git -C "${tree}" add -A
	git -C "${tree}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"
	git -C "${tree}" rev-parse HEAD
}

built() { # built -- the names changed.sh builds at the tree's HEAD
	CHANGED_ROOT="${tree}" CHANGED_OWNER=acme bash "${script}" "${images}" 2>"${work}/stderr" \
		| jq -r 'map(.name) | join(" ")'
}

base=$(commit app/main.py "app")
commit db/0001__init.sql "schema" >/dev/null
built_from demo-backend "${base}"
built_from demo-migrations "${base}"

echo "# a change whose own build was lost is still built"
# db/ changed in the commit before; this push touches only app/.
commit app/main.py "app again" >/dev/null
expect "both images changed since their main" "backend migrations" "$(built)"

echo "# nothing under an image's paths changed"
head=$(git -C "${tree}" rev-parse HEAD)
built_from demo-backend "${head}"
expect "migrations still lags, backend is current" "migrations" "$(built)"
built_from demo-migrations "${head}"
expect "both current: nothing" "" "$(built)"

echo "# an excluded path is not a change"
commit db/README.md "docs" >/dev/null
expect "db/README.md alone builds nothing" "" "$(built)"

echo "# a re-run of an older push never moves main back"
older=$(git -C "${tree}" rev-parse HEAD~1)
latest=$(git -C "${tree}" rev-parse HEAD)
git -C "${tree}" checkout -q "${older}"
commit_later=$(commit app/later.py "later" )
git -C "${tree}" checkout -q "${older}"
built_from demo-backend "${commit_later}"
built_from demo-migrations "${older}"
expect "HEAD older than backend's main, equal to migrations'" "" "$(built)"
git -C "${tree}" checkout -q "${latest}"

echo "# no main, no revision, or a revision outside the history"
rm "${registry}/demo-backend"
expect "a missing main is built" "backend" "$(built)"
if grep -qF "backend: demo-backend:main has no revision" "${work}/stderr"; then
	ok "the reason is on stderr"
else
	fail "the reason is on stderr: $(cat "${work}/stderr")"
fi
printf '{"config":{"Labels":{}}}\n' >"${registry}/demo-backend"
expect "a main without the label is built" "backend" "$(built)"
built_from demo-backend "$(printf 'f%.0s' {1..40})"
expect "a revision git does not know is built" "backend" "$(built)"
built_from demo-backend "${commit_later}"
expect "a revision off HEAD's history is built" "backend" "$(built)"

echo "# a multi-platform index"
built_from demo-backend "${latest}"
touch "${registry}/demo-backend.index"
expect "its linux/amd64 config names the revision" "" "$(built)"

echo "# the output is the input's entries"
built_from demo-migrations "${base}"
out=$(CHANGED_ROOT="${tree}" CHANGED_OWNER=acme bash "${script}" "${images}" 2>/dev/null)
expect "whole entries, as given" "$(jq -c '[.[1]]' <<<"${images}")" "${out}"

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "all checks passed"
