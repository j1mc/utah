#!/usr/bin/bash
# Acceptance test for utah#313: build the image twice and prove the two runs
# produced the same layers, in the same order.
#
# The unit tests around clean-stage.sh assert what the script does to a scratch
# tree -- that it pins the mtimes the build wrote and leaves RPM's alone. They
# cannot assert the thing the issue actually asks for, which is an outcome: that
# a rebuild changing nothing commits an identical image. Only two builds can say
# that, and only two builds can find the residue nobody thought of, so this runs
# them and diffs the result.
#
#   bash scripts/check-reproducible-build.sh [flavor]   # or: just check-reproducible
#
# Two things make the comparison honest:
#
#   --no-cache  A second `podman build` of an unchanged Containerfile replays
#               the layer cache and reports identical digests whatever the
#               build scripts do. Every RUN has to execute again for the diff
#               to mean anything.
#   Fixed build args  VERSION normally carries `date -u +%Y%m%d` and the short
#               SHA. Those land in a label, so they would differ between the two
#               runs for a reason that has nothing to do with build residue.
#               Both runs are given the same literal values.
#
# What is compared is RootFS.Layers: the ordered list of uncompressed layer
# digests, which is a function of the tar stream and therefore of every mtime,
# mode, owner and byte in it. The image config is deliberately not compared --
# it records a creation timestamp that is wall-clock by construction, and
# `podman build --timestamp` is the separate knob for that.
#
# Known limitation, stated so a passing run is not read as more than it is: this
# builds with podman, so it sees the layers the Containerfile declares, not the
# chunked layers the published image ships -- chunkah re-splits /usr and /etc in
# the reusable build workflow (projectbluefin/actions). mtime churn in the
# rootfs shows up in both, which is what this is for; a chunkah-side ordering
# instability would not (projectbluefin/actions#591).

set -euo pipefail

FLAVOR="${1:-main}"
# A seam for the tests, and for anyone who wants to point this at a different
# engine: everything below goes through it.
PODMAN="${PODMAN:-podman}"
# Held constant across both runs on purpose; see the header.
VERSION="${VERSION:-reproducibility-probe}"
SHA_HEAD_SHORT="${SHA_HEAD_SHORT:-probe}"
REPO_ORGANIZATION="${REPO_ORGANIZATION:-projectbluefin}"

case "${FLAVOR}" in
    main | nvidia | gaming | nvidia-gaming) ;;
    *)
        echo "unknown flavor: ${FLAVOR} (expected main, nvidia, gaming or nvidia-gaming)" >&2
        exit 2
        ;;
esac

build() {
    # $1 is the tag. Each run is a full, uncached build of the same inputs.
    local tag="$1"
    local base_args=()
    if [ -n "${BASE_IMAGE:-}" ]; then
        base_args=(--build-arg BASE_IMAGE="${BASE_IMAGE}")
    fi
    if [ -n "${PACKAGE_IMAGE_REF:-}" ]; then
        base_args+=(--build-arg PACKAGE_IMAGE_REF="${PACKAGE_IMAGE_REF}")
    fi
    "${PODMAN}" build \
        --no-cache \
        "${base_args[@]}" \
        --build-arg IMAGE_NAME=utah \
        --build-arg IMAGE_ID=utah \
        --build-arg IMAGE_FLAVOR="${FLAVOR}" \
        --build-arg IMAGE_VENDOR="${REPO_ORGANIZATION}" \
        --build-arg VERSION="${VERSION}" \
        --build-arg SHA_HEAD_SHORT="${SHA_HEAD_SHORT}" \
        --build-arg ENABLE_SSHD=0 \
        --tag "${tag}" \
        --file Containerfile .
}

layers() {
    "${PODMAN}" image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$1"
}

first_tag="localhost/utah-repro-a:${FLAVOR}"
second_tag="localhost/utah-repro-b:${FLAVOR}"

echo "Build 1 of 2 (${FLAVOR})"
build "${first_tag}"
echo "Build 2 of 2 (${FLAVOR})"
build "${second_tag}"

first_layers="$(layers "${first_tag}")"
second_layers="$(layers "${second_tag}")"

if [ "${first_layers}" = "${second_layers}" ]; then
    count="$(printf '%s\n' "${first_layers}" | grep -c . || true)"
    echo "Reproducible: both builds of ${FLAVOR} produced the same ${count} layers in the same order."
    exit 0
fi

echo "NOT reproducible: the two builds of ${FLAVOR} disagree." >&2
echo "A layer that differs with no input change is build residue -- a wall-clock" >&2
echo "mtime, a generated file with a timestamp inside it, or a nondeterministic" >&2
echo "ordering. diff is build 1 (<) against build 2 (>):" >&2
diff <(printf '%s\n' "${first_layers}") <(printf '%s\n' "${second_layers}") >&2 || true
echo >&2
echo "To find what moved, export both and compare the tar members of the first" >&2
echo "differing layer:" >&2
echo "  podman image save --format oci-dir -o /tmp/utah-repro-a ${first_tag}" >&2
echo "  podman image save --format oci-dir -o /tmp/utah-repro-b ${second_tag}" >&2
exit 1
