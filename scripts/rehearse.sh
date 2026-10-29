#!/usr/bin/env bash
#
# Rehearse on a workstation what bundle.yml's smoke jobs prove on the runner:
# install a published bundle, run the product's smoke hooks, update to the
# working tree's bundle/, roll back, probing between each.
#
#   cd <product> && bash <bundle-ci>/scripts/rehearse.sh [--from <oci ref>] [--keep]
#
# It runs from the product's root. Everything happens in a privileged
# docker:dind rig, `<project>-rehearsal`, which rig.sh starts, enters and
# removes as CI's smoke jobs do; a second run refuses while one exists. The
# rig gets copies of tools.sh, smoke.sh and smoke-lib.sh, of the product's
# smoke hooks and of its bundle/ as git sees it, never a mount of the
# checkout. No credential enters it: the workstation's `oras`, with its
# existing login, pulls the published bundle and copies every image either
# manifest pins into an OCI layout, which the rig's daemon loads.
#
# Environment:
#   REHEARSE_PUBKEY            the minisign public key that signed --from
#                              (the product's MINISIGN_DEV_PUBKEY for :main)
#   REHEARSE_OPERATOR_SECRETS  what bundle.yml's `operator-secrets` names
#   REHEARSE_HEALTH_PORT       `health-port` (default 8081)
#   REHEARSE_PROBE_PATHS       `probe-paths` (default "/__platform_healthz /health")
#   REHEARSE_HOOKS             `smoke-hooks` (default .github/smoke.d)
set -euo pipefail

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(pwd)
rig=${scripts}/rig.sh
keep=false
from=

usage() {
	cat <<EOF
Usage: bash <bundle-ci>/scripts/rehearse.sh [--from <oci ref>] [--keep]

Run from a product's root. Rehearse its bundle's install, smoke hooks, update
and rollback in a privileged docker:29.7.2-dind rig named <project>-rehearsal,
as CI's smoke jobs do.

It installs the --from bundle, runs the smoke hooks, updates to the working
tree's bundle/ built as 0.0.0-rehearsal.<unix time>, and rolls back.

Options:
  --from <oci ref>  the published bundle to start from (default: the product
                    repository's :main on ghcr.io, from its origin remote)
  --keep            leave the rig and its volume for inspection
  -h, --help        print this help

The workstation needs docker, oras logged in to ghcr.io, mikefarah's yq v4,
git and tar. REHEARSE_PUBKEY must hold the minisign public key that signed the
--from bundle; REHEARSE_OPERATOR_SECRETS, REHEARSE_HEALTH_PORT,
REHEARSE_PROBE_PATHS and REHEARSE_HOOKS mirror bundle.yml's inputs.
EOF
}

die() {
	echo "rehearse.sh: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		[ $# -ge 2 ] || die "--from needs an OCI reference"
		from=$2
		shift 2
		;;
	--keep)
		keep=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

for tool in docker oras yq git tar bash; do
	command -v "${tool}" >/dev/null || die "${tool} is not on PATH; see --help"
done
yq --version 2>/dev/null | grep -q mikefarah || die "yq on PATH is not mikefarah's yq v4; see --help"
[ -f "${root}/bundle/manifest.yaml" ] || die "no bundle/manifest.yaml here; run from the product's root"

project=$(yq -r '.runtimes.compose.options.project // .metadata.name' "${root}/bundle/manifest.yaml")
name=${project}-rehearsal

if [ -z "${from}" ]; then
	origin=$(git -C "${root}" remote get-url origin 2>/dev/null || true)
	slug=$(printf '%s\n' "${origin}" | sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/]+)$#\2#p')
	[ -n "${slug}" ] || die "cannot name the product's package from origin '${origin}'; pass --from"
	from=ghcr.io/$(printf '%s' "${slug%.git}" | tr '[:upper:]' '[:lower:]'):main
fi
from_pubkey=${REHEARSE_PUBKEY:-}
[ -n "${from_pubkey}" ] || die "set REHEARSE_PUBKEY to the public key that signed ${from}; see --help"
hooks=${REHEARSE_HOOKS:-.github/smoke.d}

if docker container inspect "${name}" >/dev/null 2>&1; then
	die "container ${name} exists: another rehearsal is up, or a --keep one was left; bash ${rig} stop ${name}"
fi
if docker volume inspect "${name}" >/dev/null 2>&1; then
	die "volume ${name} exists: another rehearsal is up, or a --keep one was left; docker volume rm ${name}"
fi

work=$(mktemp -d)
started=false
cleanup() {
	rm -rf "${work}"
	"${started}" || return 0
	if "${keep}"; then
		echo "rehearse.sh: kept; remove with: bash ${rig} stop ${name}"
	else
		bash "${rig}" stop "${name}" || true
	fi
}
trap cleanup EXIT

in_rig() {
	bash "${rig}" exec "${name}" "$@"
}

# The published bundle, before anything is started.
echo "rehearse.sh: pulling ${from}"
oras pull "${from}" -o "${work}/published" >/dev/null
published=$(find "${work}/published" -maxdepth 1 -name '*.tar.zst' -print -quit)
[ -n "${published}" ] || die "${from} holds no bundle archive"

# rig.sh's start refuses a name already taken, and removes the container and
# its volume itself when the daemon never answers or its packages fail.
echo "rehearse.sh: starting ${name}"
bash "${rig}" start "${name}"
started=true

{
	printf 'SMOKE_PROJECT=%q\n' "${project}"
	printf 'SMOKE_HEALTH_PORT=%q\n' "${REHEARSE_HEALTH_PORT:-8081}"
	printf 'SMOKE_PROBE_PATHS=%q\n' "${REHEARSE_PROBE_PATHS:-/__platform_healthz /health}"
	printf 'SMOKE_OPERATOR_SECRETS=%q\n' "${REHEARSE_OPERATOR_SECRETS:-}"
} >"${work}/smoke.env"
bash "${rig}" cp "${name}" "${work}/smoke.env" /rig/smoke.env
for script in tools.sh smoke.sh smoke-lib.sh; do
	bash "${rig}" cp "${name}" "${scripts}/${script}" "/rig/${script}"
done
in_rig bash /rig/tools.sh morzer sops age

# The tree as git sees it, so nothing it ignores enters the rig.
in_rig mkdir -p /rig/rehearsal /rig/dist /rig/published
git -C "${root}" ls-files -z --cached --others --exclude-standard -- bundle \
	| tar -C "${root}" --null -T - -cf - \
	| bash "${rig}" cp "${name}" - /rig/rehearsal

version=0.0.0-rehearsal.$(date +%s)
archive=/rig/dist/${project}-${version}.tar.zst
echo "rehearse.sh: building ${version}"
# shellcheck disable=SC2016 # expanded by the rig's bash
in_rig bash -c '
	set -euo pipefail
	cd /rig/rehearsal
	if ! out=$(morzer release build bundle --version "$1" --json); then
		printf "%s\n" "${out}" >&2
		exit 1
	fi
	umask 077
	minisign -G -W -p rehearsal.pub -s rehearsal.key >/dev/null
	minisign -S -s rehearsal.key -m bundle/SHA256SUMS >/dev/null
	morzer release verify bundle --signing-key "$(sed -n 2p rehearsal.pub)"
	if ! out=$(morzer release archive bundle -o "$2" --json); then
		printf "%s\n" "${out}" >&2
		exit 1
	fi
' rehearse "${version}" "${archive}"
pubkey=$(in_rig sed -n 2p /rig/rehearsal/rehearsal.pub)

rig_published=/rig/published/$(basename "${published}")
bash "${rig}" cp "${name}" "${published}" "${rig_published}"
# shellcheck disable=SC2016 # expanded by the rig's bash
in_rig bash -c '
	manifest=$(tar -I zstd -tf "$1" | grep -E "(^|/)manifest\.yaml$" | awk "{ print length, \$0 }" \
		| sort -n | sed -n "1s/^[0-9]* //p")
	[ -n "${manifest}" ] || { echo "$1 holds no manifest.yaml" >&2; exit 1; }
	tar -I zstd -xOf "$1" "${manifest}"
' rehearse "${rig_published}" >"${work}/published-manifest.yaml"

# Load one pinned image into the rig's daemon under the name a pull by its pin
# would give it. morzer pulls the image a backup reads volumes through itself
# (morzer#142), and that one is public.
load_image() {
	local pin=$1 ref digest first source image layout
	case "${pin}" in
	*@sha256:*) ;;
	*) die "${pin} is not pinned by digest" ;;
	esac
	ref=${pin%@*}
	digest=${pin##*@}
	first=${ref%%/*}
	if [[ ${ref} != */* ]]; then
		ref=docker.io/library/${ref}
	elif [[ ${first} != *.* && ${first} != *:* && ${first} != localhost ]]; then
		ref=docker.io/${ref}
	fi
	[[ ${ref##*/} != *:* ]] || ref=${ref%:*}
	# By digest, never by tag: the published bundle and the working tree can
	# pin two digests under one tag, and a second load under the tag would
	# leave the first unnamed and its pin unresolvable.
	image=${ref}@${digest}
	# Docker Hub's registry answers at registry-1.docker.io, not docker.io.
	source=${ref/#docker.io\//registry-1.docker.io/}@${digest}
	echo "rehearse.sh: loading ${image}"
	layout=$(mktemp -d "${work}/layout.XXXXXX")
	oras copy --to-oci-layout "${source}" "${layout}:rehearsal" >/dev/null
	# oras lists the platform and attestation manifests it copied beside the
	# tagged index; named too, the last would take the name from it.
	IMAGE=${image} yq -i -p json -o json '
		.manifests |= map(select(.annotations."org.opencontainers.image.ref.name" == "rehearsal")) |
		.manifests[0].annotations."io.containerd.image.name" = strenv(IMAGE)' "${layout}/index.json"
	tar -C "${layout}" -cf - oci-layout index.json blobs | in_rig docker load >/dev/null
	rm -rf "${layout}"
}

{
	yq -r '.images[]' "${root}/bundle/manifest.yaml"
	yq -r '.images[]' "${work}/published-manifest.yaml"
} | sort -u >"${work}/images"
while read -r pin; do
	load_image "${pin}"
done <"${work}/images"

smoke() {
	echo "rehearse.sh: smoke.sh $1"
	if ! in_rig bash /rig/smoke.sh "$@"; then
		in_rig bash /rig/smoke.sh diagnose || true
		die "smoke.sh $1 failed"
	fi
}

smoke install "${rig_published}" "${from_pubkey}" "${pubkey}"
smoke probe
shopt -s nullglob
for hook in "${root}/${hooks}"/*.sh; do
	hook_name=$(basename "${hook}")
	echo "rehearse.sh: hook ${hook_name}"
	bash "${rig}" cp "${name}" "${hook}" "/rig/smoke.d/${hook_name}"
	if ! in_rig bash "/rig/smoke.d/${hook_name}"; then
		in_rig bash /rig/smoke.sh diagnose || true
		die "the hook ${hook_name} failed"
	fi
	smoke probe
done
smoke update "${archive}"
smoke probe
smoke rollback "${rig_published}" "${archive}"
smoke probe
echo "rehearse.sh: ${from} -> ${version} rehearsed"
