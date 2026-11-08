#!/usr/bin/env bash
#
# Smoke-test a bundle archive the way a machine installs it: inside a rig, as
# root, with what smoke-lib.sh reads from /rig/smoke.env.
#
#   smoke.sh install <archive> <pubkey>...  fresh `sudo morzer init` and `apply`
#   smoke.sh update <archive>               `sudo morzer update` to the archive
#   smoke.sh probe                          the edge's loopback health port
#   smoke.sh pins <archive>                 every image the archive pins by digest
#   smoke.sh manifest <archive>             the archive's manifest.yaml
#   smoke.sh rollback <published> <new>     `sudo morzer rollback` from <new> to <published>
#   smoke.sh tamper <archive>               `sudo morzer update` refuses altered copies
#   smoke.sh diagnose                       `morzer status` and the Compose logs
#   smoke.sh free-disk                      room for the release's disk requirement
#
# `install` and `update` first pull every image the archive pins, retrying,
# because a registry that drops one connection fails morzer's own pull.
# `install` trusts every key it is given and refuses an unsigned release. It
# adds SMOKE_INIT_ARGS to `morzer init`, then sets each of
# SMOKE_OPERATOR_SECRETS, the secrets only an operator sets, from `random`;
# `init` generates the rest, and nothing here prints a secret. Last, before the
# first `apply`, it runs the product's pre-apply hooks,
# SMOKE_HOOKS/pre-apply/*.sh, in name order.
# `rollback` passes when the rollback succeeds, or when morzer refuses it
# (exit 9) and either the new archive declares `rollback_safe: false` or the
# two archives produce different database schemas.
#
# What only one product checks -- its data surviving a backup, a password
# rotation, a task -- is a hook of that product's, which bundle.yml runs after
# `install` and follows with `probe`.
set -euo pipefail

# shellcheck source=scripts/smoke-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/smoke-lib.sh"

# morzer pulls the image a backup reads its volumes through itself, on `apply`
# and on `update` (morzer#142), so nothing here pulls it.

install_release() {
	local archive=$1 key name
	shift
	local keys=() init_args=()
	for key in "$@"; do
		[ -n "${key}" ] && keys+=(--signing-key "${key}")
	done
	[ ${#keys[@]} -gt 0 ] || die "install needs at least one signing key"
	read -ra init_args <<<"${SMOKE_INIT_ARGS}"

	pull_images "${archive}"
	sudo morzer init --mode dev --release "${archive}" --require-signature \
		--no-recovery-recipient --install-units=false "${keys[@]}" ${init_args[@]+"${init_args[@]}"}

	for name in ${SMOKE_OPERATOR_SECRETS}; do
		random | sudo morzer secret set "${name}"
	done

	# What a machine has before its first apply and a rig does not: a domain,
	# a parameter with no default, a service the product reaches.
	local hook
	for hook in "${SMOKE_HOOKS}"/pre-apply/*.sh; do
		[ -f "${hook}" ] || continue
		echo "smoke.sh: pre-apply hook ${hook##*/}"
		bash "${hook}" || die "pre-apply hook ${hook##*/} failed"
	done

	# --verbose: morzer prints a one-shot's output, a migration's error, only then.
	sudo morzer --verbose apply
}

# An archive's manifest.yaml: the shallowest one it holds.
manifest_of() {
	local manifest
	manifest=$(tar -I zstd -tf "$1" | grep -E '(^|/)manifest\.yaml$' | awk '{ print length, $0 }' \
		| sort -n | sed -n '1s/^[0-9]* //p')
	[ -n "${manifest}" ] || die "$1 holds no manifest.yaml"
	tar -I zstd -xOf "$1" "${manifest}"
}

# A field an archive's manifest declares, by its key: `rollback_safe`,
# `database_schema_produces`.
manifest_field() {
	manifest_of "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" | sed -n 1p
}

# Every image an archive's manifest pins by digest, one per line.
pins_of() {
	manifest_of "$1" | grep -oE '[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}' | sort -u
}

# Pull every image an archive's manifest pins by digest, before morzer does.
# morzer pulls each once and fails the whole operation on one dropped
# connection; it skips an image already present under the reference it pins,
# so these pulls, each tried 4 times, leave it nothing to fetch.
pull_images() {
	local pin attempt pins
	pins=$(pins_of "$1")
	for pin in ${pins}; do
		# Loaded from a runner's image cache already: nothing to fetch.
		if sudo docker image inspect "${pin}" >/dev/null 2>&1; then
			continue
		fi
		for attempt in 1 2 3 4; do
			sudo docker pull --quiet "${pin}" >/dev/null && break
			[ "${attempt}" -lt 4 ] || die "could not pull ${pin} in 4 attempts"
			echo "smoke.sh: pulling ${pin} failed (attempt ${attempt}); retrying in $((attempt * 15))s" >&2
			sleep $((attempt * 15))
		done
	done
	echo "smoke.sh: $(printf '%s\n' "${pins}" | grep -c .) pinned image(s) present"
}

rollback() {
	local published=$1 new=$2 status=0 from to
	sudo morzer --verbose rollback || status=$?
	[ "${status}" -ne 0 ] || { echo "smoke.sh: rolled back"; return; }
	[ "${status}" -eq 9 ] || die "morzer rollback exited ${status}"
	# A release takes rollback_safe from components.yaml, and false refuses
	# any rollback from it, on one schema or not.
	if [ "$(manifest_field "${new}" rollback_safe)" = false ]; then
		echo "smoke.sh: rollback refused, as the new release declares rollback_safe: false"
		return
	fi
	from=$(manifest_field "${new}" database_schema_produces)
	to=$(manifest_field "${published}" database_schema_produces)
	if [ -z "${from}" ] || [ -z "${to}" ]; then
		die "an archive declares no database_schema_produces"
	fi
	[ "${from}" != "${to}" ] \
		|| die "morzer rollback refused (exit 9) between two releases on schema ${from}"
	echo "smoke.sh: rollback refused across the schema change ${from} -> ${to}, as it must be"
}

# `morzer update` must refuse two copies of <archive> with one byte changed in
# a file morzer does not parse (so nothing but the check can refuse it): one
# under the signed SHA256SUMS, refused as a checksum mismatch, and one with
# SHA256SUMS rewritten to match, refused as a signature that does not verify.
# Either way the installed release stays. The update to <archive> itself,
# which bundle.yml runs next, is the control.
tamper() {
	local archive=$1 work release root file byte
	work=$(mktemp -d)
	release=$(sudo morzer status --json | jq -c '.data.current_release')
	tar -I zstd -tf "${archive}" >"${work}/list"
	mkdir "${work}/x"
	tar -I zstd -xf "${archive}" -C "${work}/x"
	# The bundle's root: where its shallowest SHA256SUMS is.
	root=$(grep -E '(^|/)SHA256SUMS$' "${work}/list" | awk '{ print length, $0 }' | sort -n | sed -n '1s/^[0-9]* //p')
	[ -n "${root}" ] || die "${archive} holds no SHA256SUMS"
	root=${work}/x/$(dirname "${root}")
	file=$(awk '$2 != "manifest.yaml" && $2 != "VERSION" { print $2; exit }' "${root}/SHA256SUMS")
	[ -s "${root}/${file:-.}" ] || die "${archive} lists no file but its manifest and VERSION in SHA256SUMS"
	pull_images "${archive}"

	byte=A
	[ "$(head -c1 "${root}/${file}")" != A ] || byte=B
	printf '%s' "${byte}" | dd of="${root}/${file}" bs=1 count=1 conv=notrunc 2>/dev/null
	refuse_tampered "a byte of ${file} changed under the signed SHA256SUMS" 'checksum mismatch'
	awk -v f="${file}" -v h="$(sha256sum "${root}/${file}" | cut -d' ' -f1)" \
		'$2 == f { $0 = h "  " f } { print }' "${root}/SHA256SUMS" >"${work}/sums"
	cat "${work}/sums" >"${root}/SHA256SUMS"
	refuse_tampered "SHA256SUMS rewritten to match" 'signature does not verify'
	rm -rf "${work}"
}

refuse_tampered() { # <what was altered> <what morzer must say>: with tamper's locals
	tar -I zstd -C "${work}/x" --no-recursion -cf "${work}/tampered.tar.zst" -T "${work}/list"
	# shellcheck disable=SC2024 # the output file is this script's own
	if sudo morzer update --allow-older "${work}/tampered.tar.zst" >"${work}/out" 2>&1; then
		die "morzer updated to an archive with $1"
	fi
	grep -qF "$2" "${work}/out" || die "morzer refused an archive with $1, but not with \"$2\": $(tail -3 "${work}/out")"
	[ "$(sudo morzer status --json | jq -c '.data.current_release')" = "${release}" ] \
		|| die "after refusing an archive with $1, the installed release changed"
	echo "smoke.sh: update refuses an archive with $1 ($2)"
}

# A hosted runner's root has about 14 GiB free, and a release's preflight may
# want 20 GiB; the preinstalled toolchains hold about 25.
free_disk() {
	[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] \
		|| die "free-disk deletes the runner's toolchains; GitHub-hosted runners only"
	sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /opt/hostedtoolcache/CodeQL
	df -h /
}

diagnose() {
	sudo morzer status || true
	[ -n "${SMOKE_PROJECT:-}" ] || return 0
	sudo docker compose -p "${SMOKE_PROJECT}" ps -a || true
	sudo docker compose -p "${SMOKE_PROJECT}" logs --no-color --timestamps || true
}

case "${1:-}" in
install)
	[ $# -ge 3 ] || die "usage: smoke.sh install <archive> <pubkey>..."
	shift
	install_release "$@"
	;;
update)
	[ $# -eq 2 ] || die "usage: smoke.sh update <archive>"
	pull_images "$2"
	# A pull request's build, 0.0.0-pr.N, and a rehearsal's sort below the
	# published dev version they update, which morzer refuses without this.
	sudo morzer --verbose update --allow-older "$2"
	;;
probe) probe ;;
pins)
	[ $# -eq 2 ] || die "usage: smoke.sh pins <archive>"
	pins_of "$2"
	;;
manifest)
	[ $# -eq 2 ] || die "usage: smoke.sh manifest <archive>"
	manifest_of "$2"
	;;
rollback)
	[ $# -eq 3 ] || die "usage: smoke.sh rollback <published archive> <new archive>"
	rollback "$2" "$3"
	;;
tamper)
	[ $# -eq 2 ] || die "usage: smoke.sh tamper <archive>"
	tamper "$2"
	;;
free-disk) free_disk ;;
diagnose) diagnose ;;
*) die "usage: smoke.sh install|update|probe|pins|manifest|rollback|tamper|diagnose|free-disk" ;;
esac
