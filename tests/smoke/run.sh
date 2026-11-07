#!/usr/bin/env bash
#
# Drives scripts/smoke.sh's `update` over a real .tar.zst archive, with
# `sudo`, `docker`, `morzer` and `sleep` replaced by stubs on PATH, so nothing
# here pulls an image or waits.
#
#   bash tests/smoke/run.sh
#
# It checks that every image the archive's manifest pins by digest is pulled
# once before morzer runs, and nothing else; that an image already present is
# not; that `pins` lists them and `manifest` prints the manifest; that a pull
# which fails is tried again until it succeeds; and that one which fails 4
# times stops the update before morzer runs. And that `install` runs the
# product's pre-apply hooks in name order, between the operator secrets and
# the first `apply`, and stops at one that fails; and that it adds
# SMOKE_INIT_ARGS to `morzer init`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../.." && pwd)

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

# An archive whose manifest is the pin tests' fixture, under a directory as
# `morzer release archive` lays it out.
mkdir -p "${work}/archive/bundle"
cp "${repo}/tests/pin/manifest.yaml" "${work}/archive/bundle/manifest.yaml"
archive=${work}/demo.tar.zst
tar -C "${work}/archive" -I zstd -cf "${archive}" bundle

# The stubs. `docker pull <ref>` fails while the ref's count in FAIL_PULLS
# is not used up; every call is logged, and so is morzer's.
bin=${work}/bin
mkdir -p "${bin}"
cat >"${bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
ref=${*: -1}
echo "docker $*" >>"${LOG}"
# An image is present only when CACHED names it.
if [ "$1" = image ] && [ "$2" = inspect ]; then
	grep -qxF "${ref}" "${CACHED}" 2>/dev/null
	exit
fi
left=$(sed -n "s|^${ref} ||p" "${FAIL_PULLS}" 2>/dev/null | sed -n 1p)
if [ -n "${left}" ] && [ "${left}" -gt 0 ]; then
	sed -i "s|^${ref} .*|${ref} $((left - 1))|" "${FAIL_PULLS}"
	exit 1
fi
EOF
cat >"${bin}/morzer" <<'EOF'
#!/usr/bin/env bash
echo "morzer $*" >>"${LOG}"
EOF
cat >"${bin}/sleep" <<'EOF'
#!/usr/bin/env bash
EOF
chmod +x "${bin}"/*

backend=$(yq -r '.images.backend' "${repo}/tests/pin/manifest.yaml" 2>/dev/null \
	|| sed -n 's/^  backend: //p' "${repo}/tests/pin/manifest.yaml")

update() { # update <fail spec> [cached ref]
	LOG=${work}/log
	FAIL_PULLS=${work}/fail
	CACHED=${work}/cached
	: >"${LOG}"
	printf '%s' "$1" >"${FAIL_PULLS}"
	printf '%s\n' "${2:-}" >"${CACHED}"
	LOG=${LOG} FAIL_PULLS=${FAIL_PULLS} CACHED=${CACHED} SMOKE_ENV=/dev/null PATH="${bin}:${PATH}" \
		bash "${repo}/scripts/smoke.sh" update "${archive}"
}

echo "# every pinned image is pulled before morzer runs"
update "" >/dev/null 2>&1
expect "four digest-pinned images are pulled" 4 "$(grep -c '^docker pull' "${work}/log")"
expect "the backend's pin is one of them" 1 "$(grep -cxF "docker pull --quiet ${backend}" "${work}/log")"
expect "morzer runs once, last" "morzer --verbose update --allow-older ${archive}" "$(tail -n1 "${work}/log")"

echo "# an image already present is not pulled"
update "" "${backend}" >/dev/null 2>&1
expect "three images are pulled" 3 "$(grep -c '^docker pull' "${work}/log")"
expect "the present backend is not" 0 "$(grep -cxF "docker pull --quiet ${backend}" "${work}/log")"

echo "# pins lists what the manifest pins by digest"
pins=$(SMOKE_ENV=/dev/null bash "${repo}/scripts/smoke.sh" pins "${archive}")
expect "four pins" 4 "$(printf '%s\n' "${pins}" | grep -c .)"
expect "the backend's among them" 1 "$(printf '%s\n' "${pins}" | grep -cxF "${backend}")"

echo "# manifest prints the archive's manifest"
expect "the manifest, byte for byte" "$(cat "${work}/archive/bundle/manifest.yaml")" \
	"$(SMOKE_ENV=/dev/null bash "${repo}/scripts/smoke.sh" manifest "${archive}")"

echo "# a pull that fails is tried again"
if update "${backend} 2" >/dev/null 2>&1; then
	ok "two failures, then success: the update goes on"
else
	fail "two failures, then success: the update goes on"
fi
expect "the backend is pulled three times" 3 "$(grep -cxF "docker pull --quiet ${backend}" "${work}/log")"

echo "# a pull that fails 4 times stops the update"
if out=$(update "${backend} 9" 2>&1); then
	fail "four failures refuse: the update succeeded"
else
	ok "four failures refuse"
fi
case "${out}" in
*"could not pull ${backend} in 4 attempts"*) ok "the refusal names the image" ;;
*) fail "the refusal names the image: ${out}" ;;
esac
expect "morzer never runs" 0 "$(grep -c '^morzer' "${work}/log")"

echo "# probe"
cat >"${bin}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"${LOG}"
EOF
chmod +x "${bin}/curl"
probe() { # probe [paths]; unset with no argument
	: >"${work}/log"
	if [ $# -eq 0 ]; then
		env -u SMOKE_PROBE_PATHS LOG="${work}/log" SMOKE_ENV=/dev/null PATH="${bin}:${PATH}" \
			bash "${repo}/scripts/smoke.sh" probe
	else
		LOG="${work}/log" SMOKE_ENV=/dev/null SMOKE_PROBE_PATHS="$1" PATH="${bin}:${PATH}" \
			bash "${repo}/scripts/smoke.sh" probe
	fi
}
probe >/dev/null
expect "unset, it asks the default paths" "curl http://127.0.0.1:8081/__platform_healthz curl http://127.0.0.1:8081/health" "$(tr '\n' ' ' <"${work}/log" | sed 's/ $//')"
probe "/ready" >/dev/null
expect "it asks the paths given" "curl http://127.0.0.1:8081/ready" "$(cat "${work}/log")"
out=$(probe "")
expect "empty, it asks nothing" 0 "$(wc -l <"${work}/log" | tr -d ' ')"
case "${out}" in
*"no probe paths"*) ok "and says so" ;;
*) fail "and says so: ${out}" ;;
esac

echo "# install runs the pre-apply hooks after init and the operator secrets"
hooks=${work}/hooks
mkdir -p "${hooks}/pre-apply"
cat >"${hooks}/pre-apply/20-b.sh" <<'EOF'
echo "hook b" >>"${LOG}"
EOF
cat >"${hooks}/pre-apply/10-a.sh" <<'EOF'
echo "hook a" >>"${LOG}"
EOF
cat >"${hooks}/10-after.sh" <<'EOF'
echo "not pre-apply" >>"${LOG}"
EOF
install() { # install <hooks dir>
	: >"${work}/log"
	: >"${work}/fail"
	: >"${work}/cached"
	LOG="${work}/log" FAIL_PULLS="${work}/fail" CACHED="${work}/cached" SMOKE_ENV=/dev/null \
		SMOKE_OPERATOR_SECRETS=admin_password SMOKE_HOOKS="$1" PATH="${bin}:${PATH}" \
		bash "${repo}/scripts/smoke.sh" install "${archive}" RWQfakekey
}
calls() { grep -v '^docker' "${work}/log" | sed 's/^morzer init .*/morzer init/' | paste -sd'|' -; }
install "${hooks}" >/dev/null 2>&1
expect "in name order, between the secrets and apply" \
	"morzer init|morzer secret set admin_password|hook a|hook b|morzer --verbose apply" "$(calls)"

install "${work}/no-such-dir" >/dev/null 2>&1
expect "none, and the install goes on" \
	"morzer init|morzer secret set admin_password|morzer --verbose apply" "$(calls)"

echo 'exit 3' >"${hooks}/pre-apply/15-fails.sh"
if out=$(install "${hooks}" 2>&1); then
	fail "a failing pre-apply hook stops the install: it succeeded"
else
	ok "a failing pre-apply hook stops the install"
fi
case "${out}" in
*"pre-apply hook 15-fails.sh failed"*) ok "the refusal names the hook" ;;
*) fail "the refusal names the hook: ${out}" ;;
esac
expect "apply never runs" 0 "$(grep -c '^morzer --verbose apply' "${work}/log")"

echo "# install adds SMOKE_INIT_ARGS to morzer init"
rm -f "${hooks}/pre-apply/15-fails.sh"
: >"${work}/log"
LOG="${work}/log" FAIL_PULLS="${work}/fail" CACHED="${work}/cached" SMOKE_ENV=/dev/null \
	SMOKE_INIT_ARGS="--domain demo.test  --set smtp_host=mail.test" PATH="${bin}:${PATH}" \
	bash "${repo}/scripts/smoke.sh" install "${archive}" RWQfakekey >/dev/null 2>&1
expect "after the signing key, one word each" \
	"--signing-key RWQfakekey --domain demo.test --set smtp_host=mail.test" \
	"$(sed -n 's/^morzer init .*--install-units=false //p' "${work}/log")"

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "all checks passed"
