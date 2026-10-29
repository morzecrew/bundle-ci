#!/usr/bin/env bash
#
# A rig: the privileged Docker-in-Docker container a smoke job installs a
# bundle inside; a product's rehearsal script can drive the same container on
# a workstation.
#
#   rig.sh start <name>
#   rig.sh cp <name> <src> <dst>
#   rig.sh exec <name> <command...>
#   rig.sh login <name> <registry> <user>   token on stdin
#   rig.sh stop <name>
#
# `start` runs a privileged dind container pinned by digest, with a Docker
# volume of the same name for its /var/lib/docker, waits for its daemon and
# adds the packages the scripts inside it need. `stop` removes the container
# and its volume, so nothing a rig installs outlives it.
set -euo pipefail

image=docker:29.7.2-dind@sha256:3ef33f2e220b79ed3ef3b99d81746f06f306cd6340e2cb7331d17ae996e74cb6

usage() {
	cat <<EOF
Usage: rig.sh start <name>
       rig.sh cp <name> <src> <dst>
       rig.sh exec <name> <command...>
       rig.sh login <name> <registry> <user>
       rig.sh stop <name>

A rig is a privileged docker:29.7.2-dind container named <name>, with a
Docker volume of the same name for its /var/lib/docker.

  start   create the container and its volume, wait for the daemon, and add
          bash, curl, jq, openssl, sudo, zstd, minisign and GNU tar
  cp      copy <src> to <dst> inside the rig; <src> may be - for a tar on stdin
  exec    run a command inside the rig
  login   log the rig's Docker in to <registry> as <user>, reading the token
          on stdin
  stop    remove the container and its volume

The rig's root runs smoke.sh's sudo commands, and the loopback a rig probes
is its own.
EOF
}

die() {
	echo "rig.sh: $*" >&2
	exit 1
}

start() {
	local name=$1 ready=false
	if docker container inspect "${name}" >/dev/null 2>&1; then
		die "container ${name} exists; remove it with: rig.sh stop ${name}"
	fi
	if docker volume inspect "${name}" >/dev/null 2>&1; then
		die "volume ${name} exists; remove it with: docker volume rm ${name}"
	fi

	# The runner's proxy reaches the rig's daemon and its commands, unless it is
	# a loopback address: that is the host's, which a rig cannot reach.
	local var proxy=()
	for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
		case "${!var:-}" in
		"" | *://127.* | *://localhost* | *://\[::1\]*) ;;
		*) proxy+=(-e "${var}=${!var}") ;;
		esac
	done

	# The volume of the same name holds /var/lib/docker, so a rig's images die
	# with the rig, and no second rig shares them.
	docker run -d --privileged --name "${name}" ${proxy[@]+"${proxy[@]}"} \
		-v "${name}:/var/lib/docker" "${image}" >/dev/null \
		|| die "could not start the container ${name}"

	for _ in $(seq 60); do
		if docker exec "${name}" docker info >/dev/null 2>&1; then
			ready=true
			break
		fi
		sleep 1
	done
	if ! "${ready}"; then
		stop "${name}"
		die "the daemon in ${name} did not start"
	fi

	# GNU tar and zstd: busybox's tar reads no zstd, and both tools.sh
	# and smoke.sh unpack .tar.zst. sudo lets smoke.sh run unchanged as root.
	if ! docker exec "${name}" apk add --no-cache --quiet \
		bash curl jq openssl sudo zstd minisign tar; then
		stop "${name}"
		die "the packages in ${name} did not install"
	fi
}

copy() {
	local name=$1 src=$2 dst=$3
	if [ "${src}" = - ]; then
		docker exec "${name}" mkdir -p "${dst}"
	else
		docker exec "${name}" mkdir -p "$(dirname "${dst}")"
	fi
	docker cp "${src}" "${name}:${dst}"
}

stop() {
	local name=$1
	if docker container inspect "${name}" >/dev/null 2>&1; then
		docker rm -f "${name}" >/dev/null
	fi
	if docker volume inspect "${name}" >/dev/null 2>&1; then
		docker volume rm "${name}" >/dev/null
	fi
}

case "${1:-}" in
start)
	[ $# -eq 2 ] || die "usage: rig.sh start <name>"
	start "$2"
	;;
cp)
	[ $# -eq 4 ] || die "usage: rig.sh cp <name> <src> <dst>"
	copy "$2" "$3" "$4"
	;;
exec)
	[ $# -ge 3 ] || die "usage: rig.sh exec <name> <command...>"
	# -i: a command may read a tar, a token or a secret on stdin.
	name=$2
	shift 2
	docker exec -i "${name}" "$@"
	;;
login)
	[ $# -eq 4 ] || die "usage: rig.sh login <name> <registry> <user>"
	docker exec -i "$2" docker login "$3" -u "$4" --password-stdin
	;;
stop)
	[ $# -eq 2 ] || die "usage: rig.sh stop <name>"
	stop "$2"
	;;
*)
	usage >&2
	exit 2
	;;
esac