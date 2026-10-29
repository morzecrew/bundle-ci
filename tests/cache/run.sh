#!/usr/bin/env bash
#
# Drives scripts/image-cache.sh with `oras`, `docker` and `sleep` replaced by
# stubs on PATH, so nothing here reaches a registry, a daemon or a clock.
#
#   bash tests/cache/run.sh      # needs mikefarah's yq
#
# It checks that `fill` writes one OCI layout per repository and digest, whose
# one manifest is named `repo@sha256:<hex>`; that a multi-platform index keeps
# the index, every manifest it lists and one platform's layers, which `load`
# asks for; that a cached pin is not copied
# again; that a copy which fails is retried, and one that fails 4 times leaves
# a warning, no entry and no temporary directory; that `load` loads only what
# is cached; that `prune` drops entries and abandoned fills older than its
# days and keeps the rest; and that a pin that is not repo@digest is refused.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../.." && pwd)
script=${repo}/scripts/image-cache.sh

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

# `oras copy --to-oci-layout <name> <dir>:pin` writes a layout whose index
# lists the tagged manifest and a platform one, as oras does for an index; it
# fails while FAIL counts down. `docker` logs, and swallows a load's stdin.
bin=${work}/bin
mkdir -p "${bin}"
cat >"${bin}/oras" <<'EOF'
#!/usr/bin/env bash
# `manifest fetch --descriptor` answers an index for a repository named
# `*-multi`; `manifest fetch <name> --output <file>` writes INDEX for the index
# itself and `{}` for a manifest it lists; `copy` fails while FAIL counts down,
# and writes a layout whose index lists the tagged manifest and a platform one,
# as oras does.
echo "oras $*" >>"${LOG}"
case "$1 $2" in
"manifest fetch")
	if [ "$3" = --descriptor ]; then
		case "$4" in
		*-multi@*) echo '{"mediaType": "application/vnd.oci.image.index.v1+json"}' ;;
		*) echo '{"mediaType": "application/vnd.oci.image.manifest.v1+json"}' ;;
		esac
	elif [ "$3" = "${INDEX_NAME}" ]; then
		cp "${INDEX}" "$5"
	else
		echo '{}' >"$5"
	fi
	exit 0
	;;
esac
left=$(cat "${FAIL}" 2>/dev/null || echo 0)
if [ "${left}" -gt 0 ]; then
	echo $((left - 1)) >"${FAIL}"
	exit 1
fi
layout=${*: -1}
layout=${layout%:pin}
mkdir -p "${layout}/blobs/sha256"
echo '{"imageLayoutVersion": "1.0.0"}' >"${layout}/oci-layout"
cat >"${layout}/index.json" <<JSON
{"schemaVersion": 2, "manifests": [
  {"digest": "sha256:aa", "annotations": {"org.opencontainers.image.ref.name": "pin"}},
  {"digest": "sha256:bb", "platform": {"os": "linux", "architecture": "amd64"}}
]}
JSON
EOF
cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"${LOG}"
cat >/dev/null
EOF
cat >"${bin}/sleep" <<'EOF'
#!/usr/bin/env bash
EOF
chmod +x "${bin}"/*

export LOG=${work}/log FAIL=${work}/fail
export PATH="${bin}:${PATH}"
cache=${work}/cache
hex=$(printf 'a%.0s' {1..64})
other=$(printf 'b%.0s' {1..64})
pin=ghcr.io/acme/demo-backend:main@sha256:${hex}
entry=${cache}/ghcr.io/acme/demo-backend/${hex}

run() { : >"${LOG}"; bash "${script}" "$@"; }

echo "# fill writes one entry per repository and digest"
echo 0 >"${FAIL}"
run fill "${cache}" "${pin}" >/dev/null
expect "the entry is <repo>/<hex>" yes "$([ -f "${entry}/index.json" ] && echo yes || echo no)"
expect "oras copies by digest, without the tag" \
	"oras copy --to-oci-layout ghcr.io/acme/demo-backend@sha256:${hex} " \
	"$(grep '^oras copy' "${LOG}" | sed -E 's#[^ ]*:pin$##')"
expect "one manifest is left" 1 "$(yq -p json -o yaml '.manifests | length' "${entry}/index.json")"
expect "named as a pull by the pin names it" "ghcr.io/acme/demo-backend@sha256:${hex}" \
	"$(yq -p json -o yaml '.manifests[0].annotations."io.containerd.image.name"' "${entry}/index.json")"

echo "# a multi-platform index keeps the index and one platform's layers"
child_a=sha256:$(printf 'c%.0s' {1..64})
child_b=sha256:$(printf 'd%.0s' {1..64})
export INDEX=${work}/index-blob
printf '{"manifests": [{"digest": "%s"}, {"digest": "%s"}]}' "${child_a}" "${child_b}" >"${INDEX}"
index_digest=sha256:$(sha256sum "${INDEX}" | cut -d' ' -f1)
export INDEX_NAME=ghcr.io/acme/demo-multi@${index_digest}
multi=${cache}/ghcr.io/acme/demo-multi/${index_digest#sha256:}
run fill "${cache}" "ghcr.io/acme/demo-multi:1.0@${index_digest}" >/dev/null
expect "only linux/amd64 is copied" 1 "$(grep -c '^oras copy --platform linux/amd64 ' "${LOG}")"
expect "the index blob is there" yes "$([ -f "${multi}/blobs/sha256/${index_digest#sha256:}" ] && echo yes || echo no)"
expect "every manifest it lists is there" yes \
	"$([ -f "${multi}/blobs/sha256/${child_a#sha256:}" ] && [ -f "${multi}/blobs/sha256/${child_b#sha256:}" ] && echo yes || echo no)"
expect "the layout's one descriptor is the index" "${index_digest} application/vnd.oci.image.index.v1+json" \
	"$(yq -p json -o yaml '.manifests[0].digest + " " + .manifests[0].mediaType' "${multi}/index.json")"
expect "named as a pull by the pin names it" "${INDEX_NAME}" \
	"$(yq -p json -o yaml '.manifests[0].annotations."io.containerd.image.name"' "${multi}/index.json")"
expect "its platform is recorded" linux/amd64 "$(cat "${multi}/platform")"
run load "${cache}" a-rig "ghcr.io/acme/demo-multi:1.0@${index_digest}" >/dev/null
expect "load asks for that platform" 1 "$(grep -c 'docker exec -i a-rig docker load --platform linux/amd64' "${LOG}")"

echo "# an index that does not hash to its pin is not cached"
wrong=sha256:$(printf 'e%.0s' {1..64})
run fill "${cache}" "ghcr.io/acme/demo-multi@${wrong}" >/dev/null 2>&1
expect "no entry" no "$([ -e "${cache}/ghcr.io/acme/demo-multi/${wrong#sha256:}" ] && echo yes || echo no)"

echo "# a cached pin is not copied again"
run fill "${cache}" "${pin}" >/dev/null
expect "no copy" 0 "$(grep -c '^oras copy' "${LOG}")"

echo "# a copy that fails is retried"
echo 2 >"${FAIL}"
run fill "${cache}" "ghcr.io/acme/demo-frontend@sha256:${hex}" >/dev/null 2>&1
expect "three attempts" 3 "$(grep -c '^oras copy' "${LOG}")"
expect "then cached" yes "$([ -f "${cache}/ghcr.io/acme/demo-frontend/${hex}/index.json" ] && echo yes || echo no)"

echo "# a copy that fails 4 times is left to the rig"
echo 9 >"${FAIL}"
if out=$(run fill "${cache}" "ghcr.io/acme/demo-gone@sha256:${hex}" 2>&1); then
	ok "fill still succeeds"
else
	fail "fill still succeeds: ${out}"
fi
expect "four attempts" 4 "$(grep -c '^oras copy' "${LOG}")"
case "${out}" in
*"::warning::"*"could not copy ghcr.io/acme/demo-gone"*) ok "it warns" ;;
*) fail "it warns: ${out}" ;;
esac
expect "no entry" no "$([ -e "${cache}/ghcr.io/acme/demo-gone/${hex}" ] && echo yes || echo no)"
expect "no temporary directory" 0 "$(find "${cache}" -maxdepth 1 -name '.fill.*' | wc -l | tr -d ' ')"

echo "# load loads what is cached, and only that"
run load "${cache}" a-rig "${pin}" "ghcr.io/acme/demo-gone@sha256:${hex}" >/dev/null
expect "one load" 1 "$(grep -c 'docker exec -i a-rig docker load' "${LOG}")"

echo "# prune drops what nothing used for its days"
echo 0 >"${FAIL}"
run fill "${cache}" "ghcr.io/acme/demo-old@sha256:${other}" >/dev/null
touch -d '20 days ago' "${cache}/ghcr.io/acme/demo-old/${other}"
mkdir -p "${cache}/.fill.abandoned"
touch -d '20 days ago' "${cache}/.fill.abandoned"
run prune "${cache}" 14
expect "the old entry goes" no "$([ -e "${cache}/ghcr.io/acme/demo-old" ] && echo yes || echo no)"
expect "the abandoned fill goes" no "$([ -e "${cache}/.fill.abandoned" ] && echo yes || echo no)"
expect "a recent entry stays" yes "$([ -f "${entry}/index.json" ] && echo yes || echo no)"

echo "# a pin that is not repo@digest is refused"
if out=$(run fill "${cache}" ghcr.io/acme/demo-backend:main 2>&1); then
	fail "a tag alone is refused: it was accepted"
else
	case "${out}" in
	*"is not repo[:tag]@sha256:<hex>"*) ok "a tag alone is refused" ;;
	*) fail "a tag alone is refused: ${out}" ;;
	esac
fi

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "all checks passed"
