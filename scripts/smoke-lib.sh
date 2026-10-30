# What smoke.sh and a product's smoke hooks share, sourced by both inside a rig.
#
# It reads /rig/smoke.env (or SMOKE_ENV), which bundle.yml writes from the
# product's manifest and its inputs:
#
#   SMOKE_PROJECT           the Compose project: the manifest's
#                           runtimes.compose.options.project, else metadata.name
#   SMOKE_HEALTH_PORT       the edge's loopback health port (default 8081)
#   SMOKE_PROBE_PATHS       what `probe` asks the port for, space-separated
#                           (default "/__platform_healthz /health"); empty for
#                           a bundle that serves no HTTP, whose release health
#                           checks are then all a probe has
#   SMOKE_OPERATOR_SECRETS  the secrets only an operator sets, which `install`
#                           sets from `random`, space-separated
#
# A hook starts with `. /rig/smoke-lib.sh` and has `die`, `random`,
# `service_container` and `probe`. Nothing here, and nothing a hook does, may
# print a secret.
# shellcheck shell=bash

if [ -f "${SMOKE_ENV:-/rig/smoke.env}" ]; then
	# shellcheck disable=SC1090
	. "${SMOKE_ENV:-/rig/smoke.env}"
fi
SMOKE_HEALTH_PORT=${SMOKE_HEALTH_PORT:-8081}
SMOKE_PROBE_PATHS=${SMOKE_PROBE_PATHS-/__platform_healthz /health}
SMOKE_OPERATOR_SECRETS=${SMOKE_OPERATOR_SECRETS:-}

die() {
	echo "${0##*/}: $*" >&2
	exit 1
}

random() {
	openssl rand -hex 24
}

# The running container of one of the project's services, by the labels
# Compose puts on it. A restore recreates it, so each call looks it up again.
service_container() {
	local container
	[ -n "${SMOKE_PROJECT:-}" ] || die "SMOKE_PROJECT is not set; smoke.env names the Compose project"
	container=$(sudo docker ps --quiet \
		--filter "label=com.docker.compose.project=${SMOKE_PROJECT}" \
		--filter "label=com.docker.compose.service=$1" | sed -n 1p)
	[ -n "${container}" ] || die "no running $1 container of the ${SMOKE_PROJECT} project"
	printf '%s\n' "${container}"
}

probe() {
	local path
	if [ -z "${SMOKE_PROBE_PATHS}" ]; then
		echo "${0##*/}: no probe paths; morzer's health checks passed at apply"
		return 0
	fi
	for path in ${SMOKE_PROBE_PATHS}; do
		curl -fsS --max-time 10 --retry 10 --retry-delay 3 --retry-all-errors \
			-o /dev/null "http://127.0.0.1:${SMOKE_HEALTH_PORT}${path}" \
			|| die "127.0.0.1:${SMOKE_HEALTH_PORT}${path} did not answer 2xx"
		echo "${0##*/}: ${path} ok"
	done
}
