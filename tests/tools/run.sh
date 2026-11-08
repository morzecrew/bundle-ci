#!/usr/bin/env bash
#
# scripts/tools.sh's downloads, with `curl` replaced by a stub that logs its
# arguments: a GITHUB_TOKEN (or GH_TOKEN) goes along as a bearer header, and
# without one no header is sent. The stub's file fails the checksum, so
# nothing is installed.
#
#   bash tests/tools/run.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0
ok() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; failures=$((failures + 1)); }

mkdir -p "${work}/bin"
cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOG}"
while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo stub >"$2"; shift; }; shift; done
STUB
chmod +x "${work}/bin/curl"

run() { # <env assignments...>: tools.sh yq, its curl calls in ${LOG}
	: >"${work}/log"
	env -u GITHUB_TOKEN -u GH_TOKEN "$@" LOG="${work}/log" BIN_DIR="${work}/out" PATH="${work}/bin:${PATH}" \
		bash "${repo}/scripts/tools.sh" yq >/dev/null 2>&1 || true
}

check() { # <what> <command...>: ok when the command succeeds
	local what=$1
	shift
	if "$@"; then ok "${what}"; else fail "${what}: $(cat "${work}/log")"; fi
}
run GITHUB_TOKEN=t0ken
check "GITHUB_TOKEN goes along as a bearer header" grep -qF -- '-H Authorization: Bearer t0ken' "${work}/log"
check "it asks GitHub's release download" grep -q 'github.com/mikefarah/yq/releases/download' "${work}/log"
check "a file that fails its checksum is not installed" test ! -e "${work}/out/yq"
run GH_TOKEN=gh-t0ken
check "so does GH_TOKEN" grep -qF -- '-H Authorization: Bearer gh-t0ken' "${work}/log"
run
no_header() { ! grep -q Authorization "${work}/log"; }
check "no token, no header" no_header

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "all checks passed"
