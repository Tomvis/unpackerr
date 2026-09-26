# Fork image build (tomvaisbort/unpackerr)

`unpackerr-two-context.Dockerfile` builds the enhanced-fork image. It is
fork-only: the fork's `go.mod` carries `replace golift.io/xtractr => ../xtractr`,
which cannot resolve inside a single-repo context, so upstream's `Dockerfile` and
`make docker` cannot build it. The build context holds two trees side by side:

    <ctx>/unpackerr   git archive HEAD of this repo
    <ctx>/xtractr     git archive HEAD of the sibling xtractr fork (branch enhanced)

`scripts/build-fork-image.sh <version>` stages both trees from the Mac onto the
Docker host (10.0.0.120, `~/build/unp-ctx`), builds with this file, and checks
that ffmpeg is in the image (`PUSH=1` pushes). ffmpeg is a silent dependency:
without it split_flac stops splitting APE/WV/M4A/WAV CUE albums and nothing errors.

Until 2026-09-26 this file lived only on the Docker host as
`~/build/unpackerr-two-context.Dockerfile`. It was generated from
`init/docker/Dockerfile` until upstream deleted that path in the 2026-09-11 merge
(f852cdc), and it has been hand-maintained since. Edit it here; do not regenerate it.

## How 1.4.1 was built

`tomvaisbort/unpackerr:1.4.1` is the image deployed on TrueNAS (10.0.0.101). It was
built on 2026-09-11 at 14:12 IDT by `scripts/build-fork-image.sh 1.4.1` (PUSH=1):

- Sources: unpackerr `enhanced` at 714221f, and xtractr `enhanced` at bf09cb9, which
  was that branch's HEAD at build time. The image records only the unpackerr commit.
- Dockerfile: this file, byte-identical (sha256 `086ce3d8…`). Base images have been
  pinned by digest since 2026-09-11, matching upstream: `golang:1.27-alpine` and
  `alpine:3.24`. Before that they were the floating `golang:1-alpine` and `alpine`.
- Result: image ID `sha256:98015572e283…`, labels
  `org.opencontainers.image.version=1.4.1-1` and `revision=714221f`, registry
  digest `sha256:b0698c1649c8…`.
