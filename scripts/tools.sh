#!/usr/bin/env bash
#
# Install the tools a workflow job names, each pinned by version and checked
# before it is installed: morzer by its release's minisign signature and
# checksum, the rest by a sha256 read off each release (age and minisign
# publish no checksum file: their pins are the archives' hashes on
# 2026-10-24), and zstd by its Ubuntu 24.04 package version. amd64 only, as
# the bundle is.
#
#   bash scripts/tools.sh minisign zstd morzer
#
# Tools install in the order given; morzer needs minisign and zstd first.
set -euo pipefail

MORZER=0.9.0
# `morzer.pub` at the root of morzecrew/morzer, as its install.sh carries it.
MORZER_PUBKEY=RWRS3ZHbN8tEYuF9Se2e+JzQMiUCoLbABbJtzSxBThI/U4Bhw+AR+IbQ
MINISIGN=0.12
MINISIGN_SHA256=9a599b48ba6eb7b1e80f12f36b94ceca7c00b7a5173c95c3efc88d9822957e73
ZSTD=1.5.5+dfsg2-2build1.1
ORAS=1.3.5
ORAS_SHA256=f48a73ea6d026a862c3919fc773da9a8c86fc259c2c737d5baed3b8b9614ad22
SOPS=3.13.3
SOPS_SHA256=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
AGE=1.2.1
AGE_SHA256=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50
YQ=4.54.1
YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f

gh=https://github.com
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
cd "${work}"

check() { # <sha256> <file>
	echo "$1  $2" | sha256sum -c -
}

# A job container runs as root, where `sudo` may not be installed; a
# workstation runs this script as an ordinary user, where it is.
as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

# Where the binaries go: /usr/local/bin, or `BIN_DIR`, a directory the job
# owns, such as `${RUNNER_TEMP}/bin` on a shared runner's host, where the
# runner's user has no sudo. A tool installed first is on PATH for the next.
bin_dir=${BIN_DIR:-/usr/local/bin}
[ -n "${BIN_DIR:-}" ] && mkdir -p "${bin_dir}"
PATH="${bin_dir}:${PATH}"

put() { # <file>...
	if [ -w "${bin_dir}" ]; then
		install -m 0755 "$@" "${bin_dir}/"
	else
		as_root install -m 0755 "$@" "${bin_dir}/"
	fi
}

for tool in "$@"; do
	case "${tool}" in
	minisign)
		curl -fsSLO "${gh}/jedisct1/minisign/releases/download/${MINISIGN}/minisign-${MINISIGN}-linux.tar.gz"
		check "${MINISIGN_SHA256}" "minisign-${MINISIGN}-linux.tar.gz"
		tar -xzf "minisign-${MINISIGN}-linux.tar.gz" minisign-linux/x86_64/minisign
		put minisign-linux/x86_64/minisign
		;;
	zstd)
		as_root apt-get update -qq
		as_root apt-get install -y -qq --no-install-recommends "zstd=${ZSTD}"
		;;
	morzer)
		base="${gh}/morzecrew/morzer/releases/download/v${MORZER}"
		curl -fsSLO "${base}/morzer_${MORZER}_linux_amd64.tar.zst"
		curl -fsSLO "${base}/SHA256SUMS"
		curl -fsSLO "${base}/SHA256SUMS.minisig"
		minisign -Vm SHA256SUMS -P "${MORZER_PUBKEY}"
		grep " morzer_${MORZER}_linux_amd64.tar.zst\$" SHA256SUMS | sha256sum -c -
		tar --zstd -xf "morzer_${MORZER}_linux_amd64.tar.zst" morzer
		put morzer
		;;
	oras)
		curl -fsSLO "${gh}/oras-project/oras/releases/download/v${ORAS}/oras_${ORAS}_linux_amd64.tar.gz"
		check "${ORAS_SHA256}" "oras_${ORAS}_linux_amd64.tar.gz"
		tar -xzf "oras_${ORAS}_linux_amd64.tar.gz" oras
		put oras
		;;
	sops)
		curl -fsSL -o sops "${gh}/getsops/sops/releases/download/v${SOPS}/sops-v${SOPS}.linux.amd64"
		check "${SOPS_SHA256}" sops
		put sops
		;;
	age)
		curl -fsSLO "${gh}/FiloSottile/age/releases/download/v${AGE}/age-v${AGE}-linux-amd64.tar.gz"
		check "${AGE_SHA256}" "age-v${AGE}-linux-amd64.tar.gz"
		tar -xzf "age-v${AGE}-linux-amd64.tar.gz" age/age age/age-keygen
		put age/age age/age-keygen
		;;
	yq)
		curl -fsSL -o yq "${gh}/mikefarah/yq/releases/download/v${YQ}/yq_linux_amd64"
		check "${YQ_SHA256}" yq
		put yq
		;;
	*)
		echo "tools.sh: no pin for '${tool}'" >&2
		exit 2
		;;
	esac
done
