#!/usr/bin/env bash
#
# Build and optionally push the enhanced-fork unpackerr image
# (tomvaisbort/unpackerr) from this Mac, using 10.0.0.120 as the Docker host.
#
# WHY THIS EXISTS
#   Until 2026-09-11 this procedure lived only in a Claude Code session
#   transcript. It is fork-only (upstream has no two-context build) and is not
#   reachable through `make docker`, because the fork's go.mod carries
#   `replace golift.io/xtractr => ../xtractr`, which cannot resolve inside a
#   single-repo Docker context.
#
# HOW IT WORKS
#   The build needs TWO source trees side by side so that replace directive
#   resolves (/src/../xtractr):
#
#       <ctx>/unpackerr   git archive HEAD of this repo
#       <ctx>/xtractr     git archive HEAD of the sibling xtractr fork
#
#   Both come from THIS Mac, which is git truth. The copies under
#   ~/Projects on 10.0.0.120 are stale non-git snapshots and are NOT inputs.
#
#   The Dockerfile is DOCKER_HOST-side and standalone: ~/build/unpackerr-two-context.Dockerfile.
#   It used to be generated from unpackerr/init/docker/Dockerfile, but upstream
#   deleted that path in the 2026-09-11 merge (f852cdc0), so it is now hand-maintained.
#   Edit it there; do not try to regenerate it.
#
#   ffmpeg is installed in the runtime stage and is a SILENT dependency: without
#   it, splitting APE/WV/M4A/WAV CUE albums simply stops working. Nothing errors.
#
# USAGE
#   scripts/build-fork-image.sh <version> [iteration]      # build only
#   PUSH=1 scripts/build-fork-image.sh <version>           # build, then push
#
#   Example: scripts/build-fork-image.sh 1.4.0
#
# AFTER BUILDING
#   Update the image tag in the media-server stack on TrueNAS (10.0.0.101):
#     /mnt/Fast/docker/stacks/media-server/compose.yaml
#   then recreate just that service. This script deliberately does not deploy.

set -euo pipefail

VERSION="${1:-}"
ITERATION="${2:-1}"
PUSH="${PUSH:-0}"

DOCKER_HOST_SSH="${DOCKER_HOST_SSH:-tom@10.0.0.120}"
CTX="${CTX:-\$HOME/build/unp-ctx}"
DOCKERFILE_SRC="${DOCKERFILE_SRC:-\$HOME/build/unpackerr-two-context.Dockerfile}"
IMAGE="${IMAGE:-tomvaisbort/unpackerr}"

UNPACKERR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XTRACTR_DIR="${XTRACTR_DIR:-$(cd "$UNPACKERR_DIR/../xtractr" && pwd)}"

die() { echo "error: $*" >&2; exit 1; }

[ -n "$VERSION" ] || die "usage: $0 <version> [iteration]   (e.g. $0 1.4.0)"

# Both trees are shipped with `git archive HEAD`, which silently ignores
# uncommitted work. Refuse rather than build something that matches no commit.
for d in "$UNPACKERR_DIR" "$XTRACTR_DIR"; do
    [ -d "$d/.git" ] || die "$d is not a git repository"
    if [ -n "$(git -C "$d" status --porcelain)" ]; then
        die "$d has uncommitted changes; git archive would silently skip them"
    fi
done

UNP_COMMIT="$(git -C "$UNPACKERR_DIR" rev-parse --short HEAD)"
XTR_COMMIT="$(git -C "$XTRACTR_DIR" rev-parse --short HEAD)"
BRANCH="$(git -C "$UNPACKERR_DIR" rev-parse --abbrev-ref HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "unpackerr $BRANCH@$UNP_COMMIT + xtractr @$XTR_COMMIT -> $IMAGE:$VERSION-$ITERATION"
echo "docker host: $DOCKER_HOST_SSH"

# Stage both trees. The Dockerfile lives outside CTX precisely because this wipes it.
ssh "$DOCKER_HOST_SSH" "rm -rf $CTX && mkdir -p $CTX/unpackerr $CTX/xtractr"
git -C "$UNPACKERR_DIR" archive HEAD | ssh "$DOCKER_HOST_SSH" "tar -x -C $CTX/unpackerr"
git -C "$XTRACTR_DIR"   archive HEAD | ssh "$DOCKER_HOST_SSH" "tar -x -C $CTX/xtractr"
ssh "$DOCKER_HOST_SSH" "cp $DOCKERFILE_SRC $CTX/Dockerfile.build"

# Fail early and loudly if the sibling checkout predates the API the fork uses.
ssh "$DOCKER_HOST_SSH" "grep -q 'func IsLimitError' $CTX/xtractr/*.go" \
    || die "staged xtractr lacks IsLimitError - sibling checkout at $XTRACTR_DIR is stale"

ssh "$DOCKER_HOST_SSH" "cd $CTX && docker build -f Dockerfile.build \
    --build-arg VERSION='$VERSION' \
    --build-arg ITERATION='$ITERATION' \
    --build-arg COMMIT='$UNP_COMMIT' \
    --build-arg BRANCH='$BRANCH' \
    --build-arg BUILD_DATE='$BUILD_DATE' \
    -t $IMAGE:$VERSION ."

# ffmpeg's absence is invisible at runtime, so prove it is in the image we just built.
echo "verifying ffmpeg is present in $IMAGE:$VERSION"
ssh "$DOCKER_HOST_SSH" "docker run --rm --entrypoint /bin/sh $IMAGE:$VERSION -c 'command -v ffmpeg'" \
    || die "ffmpeg missing from the built image - split_flac would be silently dead"

if [ "$PUSH" = "1" ]; then
    ssh "$DOCKER_HOST_SSH" "docker push $IMAGE:$VERSION"
    echo "pushed $IMAGE:$VERSION"
else
    echo "built $IMAGE:$VERSION (not pushed; re-run with PUSH=1 to push)"
fi
