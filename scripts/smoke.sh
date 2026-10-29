#!/usr/bin/env bash
#
# Smoke-test a bundle archive the way a machine installs it: inside a rig, as
# root, with what smoke-lib.sh reads from /rig/smoke.env.
#
#   smoke.sh install <archive> <pubkey>...  fresh `sudo morzer init` and `apply`
#   smoke.sh update <archive>               `sudo morzer update` to the archive
#   smoke.sh probe                          the edge's loopback health port
#   smoke.sh rollback <published> <new>     `sudo morzer rollback` from <new> to <published>
#   smoke.sh diagnose                       `morzer status` and the Compose logs
#   smoke.sh free-disk                      room for the release's disk requirement
#
# `install` trusts every key it is given and refuses an unsigned release. It
# sets each of SMOKE_OPERATOR_SECRETS, the secrets only an operator sets, from
# `random`; `init` generates the rest, and nothing here prints a secret.
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
	local keys=()
	for key in "$@"; do
		[ -n "${key}" ] && keys+=(--signing-key "${key}")
	done
	[ ${#keys[@]} -gt 0 ] || die "install needs at least one signing key"

	sudo morzer init --mode dev --release "${archive}" --require-signature \
		--no-recovery-recipient --install-units=false "${keys[@]}"

	for name in ${SMOKE_OPERATOR_SECRETS}; do
		random | sudo morzer secret set "${name}"
	done

	# --verbose: morzer prints a one-shot's output, a migration's error, only then.
	sudo morzer --verbose apply
}

# A field an archive's manifest declares, by its key: `rollback_safe`,
# `database_schema_produces`.
manifest_field() {
	local manifest
	manifest=$(tar -I zstd -tf "$1" | grep -E '(^|/)manifest\.yaml$' | awk '{ print length, $0 }' \
		| sort -n | sed -n '1s/^[0-9]* //p')
	[ -n "${manifest}" ] || die "$1 holds no manifest.yaml"
	tar -I zstd -xOf "$1" "${manifest}" \
		| sed -n "s/^[[:space:]]*$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" | sed -n 1p
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
	sudo morzer --verbose update "$2"
	;;
probe) probe ;;
rollback)
	[ $# -eq 3 ] || die "usage: smoke.sh rollback <published archive> <new archive>"
	rollback "$2" "$3"
	;;
free-disk) free_disk ;;
diagnose) diagnose ;;
*) die "usage: smoke.sh install|update|probe|rollback|diagnose|free-disk" ;;
esac
