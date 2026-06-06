# Multi-format CUE splitting for unpackerr (`enhanced` fork)

**Date:** 2026-06-06
**Repos/branch:** `golift/xtractr` @ `enhanced` (most code) + `Unpackerr/unpackerr` @ `enhanced` (wiring/image)
**Status:** Design approved, ready for implementation plan

## Context

unpackerr v0.15.x added `split_flac` for Lidarr: it splits a single-file album (one big audio file + a `.cue`) into per-track FLACs and manually imports them into Lidarr. The implementation lives in the `golift/xtractr` dependency (`cue.go` → `ExtractCUE`), is pure-Go (`mewkiz/flac`), and **only supports FLAC** — `cue.go:95` returns `ErrUnsupportedAudio` for anything else.

On the TrueNAS media stack this replaced a hand-rolled qBittorrent `cue-split.bash` that also handled **APE / WavPack (.wv) / ALAC-AAC (.m4a) / WAV** by transcoding to FLAC with ffmpeg, then splitting with `shnsplit`. Dropping those formats is the one regression from the migration. Upstream deliberately refuses an ffmpeg dependency (maintainer, issue #141: *"Not super fond of calling out to ffprobe… I'm not one to do things half way"*), so adding the formats must be a **fork**.

**Goal:** extend the cue splitter to APE/WV/M4A/WAV (output always FLAC), matching the old script's format coverage, while keeping the FLAC path and tagging/art behavior identical to upstream.

**Non-goals:** changing the FLAC path; changing how originals are handled (we keep `delete_orig=false` → seed preserved); upstreaming (the ffmpeg dep won't be accepted). No new config surface — the existing `split_flac` toggle is reused.

## Architecture

```
Lidarr queue item (single audio file + .cue)
        │  unpackerr (split_flac=true): appends ".cue" to extractable types, calls xtractr
        ▼
xtractr  ExtractCUE(.cue)            cue.go  (dispatch on resolved audio ext)
   ├── .flac  → splitFLAC()          existing pure-Go path  (UNCHANGED, no ffmpeg)
   └── .ape/.wv/.m4a/.wav → splitViaFFmpeg()   cue_ffmpeg.go  (NEW)
        ├─ ffprobe  : sample rate, total samples, source tags
        ├─ ffmpeg   : per-track accurate cut → FLAC (-map_metadata -1)
        └─ go-flac  : metadata-only re-tag (Vorbis + cover art) — reuses shared tag policy
        ▼
unpackerr importSplitFlacTracks() → Lidarr manual import  (UNCHANGED)
```

- **unpackerr changes are minimal:** `go.mod` `replace golift.io/xtractr => ../xtractr`, Dockerfile `apk add ffmpeg`, and generalized log/doc wording. The `split_flac` flag, `.cue` trigger (`handlers.go:128`), and import flow (`lidarr.go:229`) are untouched.
- **xtractr holds the real change**, isolated to keep future upstream rebases easy: one new file (`cue_ffmpeg.go`), a small branch in `ExtractCUE`, an extended `resolveCueAudioPath`, and a shared-tag-policy refactor.

## Detailed design — `xtractr`

### 1. Dispatch (`cue.go` `ExtractCUE`)
Replace the FLAC-only gate (`cue.go:93-96`) with:
- `.flac` → `splitFLAC(...)` (existing, unchanged).
- `.ape`, `.wv`, `.m4a`, `.wav` → `splitViaFFmpeg(...)` (new).
- otherwise → `ErrUnsupportedAudio` (kept; message generalized to "only FLAC/APE/WV/M4A/WAV supported").

`ExtractCUE` keeps returning the same `(size, files, archives)` shape (`archives = [cue, audioPath]`, `files = [tracks…, cue copy, art]`) so the unpackerr import flow is identical for all formats.

### 2. Multi-format audio resolution (`resolveCueAudioPath`, `cue.go:304`)
**(The one behavior added at user request — parity with the old script's alt-extension fallback.)**
Today it tries the FILE-referenced path, then `.wav→.flac`, then `<cuebasename>.flac`. Extend so that when the referenced file is missing it also probes the other supported audio extensions (`.flac/.ape/.wv/.m4a/.wav`, case-insensitive) for both the FILE basename and the cue basename. This handles cues that name the wrong container (e.g. `FILE "album.wav"` next to `album.ape`).

### 3. Shared tag policy (refactor)
Extract the tag-key policy currently inline in `cue.go` — `vorbisTagsFromCUE()`, `vorbisTagsToMergeFromSource()`, `formatTrackFilename()`/`sanitizeFilename()`, picture naming (`pictureTypeNames`/`writePicturesToFiles`) — into helpers callable by both the FLAC path and `splitViaFFmpeg`, so tags, filenames, and art naming are **byte-for-byte consistent** across formats. No behavior change for the FLAC path.

### 4. `splitViaFFmpeg` (new file `cue_ffmpeg.go`)
Inputs: `xFile`, resolved `audioPath` (non-FLAC), parsed `cue`, `timestamps`.

1. **Probe** (`ffprobe -v error -print_format json -show_format -show_streams audioPath`): read source tags (GENRE/DATE/ALBUMARTIST/…) and duration. Track boundaries come from the cue timestamps directly (`MM:SS:FF → seconds`), so the source sample rate is *not* needed for cutting; the probe is for tag merging and a duration sanity check (last-track end).
2. **Per-track cut → FLAC**: from the cue `INDEX 01` timestamps, compute each track's `start` and duration `dur = next_start − start`. Run, per track:
   `ffmpeg -nostdin -v error -ss <start> -i <audioPath> -t <dur> -vn -c:a flac -compression_level 8 -map_metadata -1 <OutputDir>/<NN - Title>.flac`
   Use `-t <dur>` (duration), **not** `-to`, to avoid the input-seek `-to` relative-vs-absolute ambiguity. The final track omits `-t` and runs to EOF. Input-seek + `accurate_seek` (default on) yields sample-accurate cuts for all-keyframe lossless codecs without an O(N²) decode-from-zero. Streaming → **no whole-file decode into RAM** (lighter than the FLAC path).
3. **Re-tag (metadata-only, no re-encode)** via `github.com/go-flac/go-flac`: build the Vorbis comment block (TITLE/TRACKNUMBER/ALBUM/ARTIST from the cue, merged with ffprobe source tags per the shared policy) and a Picture block for cover art, and write them onto each output FLAC by replacing its metadata block chain (audio frames untouched).
4. **Album art**: extract embedded cover once (`ffmpeg -i audioPath -an -vcodec copy cover.jpg` / from the probe's attached pic) → `cover.<ext>` using the shared naming, and embed into each track's Picture block.
5. **Finish**: copy the `.cue` into `OutputDir`, return `(totalSize, files, archives)` exactly like `ExtractCUE`.

### 5. Dependencies & runtime guard
- New Go dep: `github.com/go-flac/go-flac` (pure-Go FLAC metadata editor — metadata only, no audio re-encode).
- External binaries: `ffmpeg`, `ffprobe` (in the image).
- **Graceful degradation:** detect `ffmpeg`/`ffprobe` on `PATH` at split time. If missing and a non-FLAC cue is hit, return a clear error and skip that item (FLAC keeps working). The binary never hard-depends on ffmpeg; the image provides it.

## Detailed design — `unpackerr`
- `go.mod`: `replace golift.io/xtractr => ../xtractr` (local fork during dev; swap to the pushed fork branch for CI/image builds).
- `init/docker/Dockerfile`: add `ffmpeg` to the final `apk add --no-cache openssl tzdata` line.
- `lidarr.go` log line + `examples`/docs: reword "FLAC+CUE" → "single-file (FLAC/APE/WV/M4A/WAV) + CUE". Flag name stays `split_flac` (deployed config `UN_LIDARR_0_SPLIT_FLAC=true` keeps working).

## Build & deploy
- Build image from the `enhanced` Dockerfile → tag `tomvaisbort/unpackerr:enhanced` (build locally where the push-capable Docker Hub login exists, as with the music-assistant image).
- Stack swap: change the `unpackerr` service `image:` from `golift/unpackerr:0.15.2` → `tomvaisbort/unpackerr:enhanced` (one line in `media-server/compose.yaml`), `docker compose up -d unpackerr`. All other config unchanged.

## Testing
- **Unit (`xtractr/cue_ffmpeg_test.go`):** generate tiny synthetic sources in-test via ffmpeg — a sine WAV, transcode to `.ape`/`.wv`/`.flac` — with a known multi-track cue. Assert: correct track count, sample-accurate boundaries (±0), tags present and matching the FLAC path, cover art embedded. `t.Skip` automatically when ffmpeg is absent so upstream/CI without ffmpeg still passes.
- **Extend `resolveCueAudioPath` tests** for the new alt-extension fallback.
- **End-to-end:** build image, deploy to the stack, drop a real **APE+cue** album into Lidarr's queue, confirm split → tagged import → preserved seed (same verification path already used for FLAC).

## Behavior parity with the old `cue-split.bash`
| Old script behavior | New design |
|---|---|
| `label==lidarr` gate | ✅ unpackerr is Lidarr-queue-only |
| recursive cue scan / multi-disc | ✅ unpackerr recurses; each cue extracted |
| alt-extension fallback | ✅ extended `resolveCueAudioPath` (§2) |
| ape/m4a/wv → FLAC transcode + split | ✅ `splitViaFFmpeg` |
| remove `00 - pregap.flac` (HTOA) | ✅ equivalent — xtractr never creates a pregap track |
| delete original cue + audio | 🔄 intentionally changed → `delete_orig=false` preserves seed |
| keep originals on failure | ✅ error → no import, no delete |
| (none — shnsplit was untagged) | ➕ new path adds Vorbis tags, album art, UTF-16/BOM cue handling |

## Risks / edge cases
- **Sample accuracy:** input-seek + `accurate_seek` is the standard ffcuesplitter approach; verified against a known cue in tests.
- **Lossy M4A (AAC):** lossy→FLAC doesn't gain quality and AAC encoder delay can shift cuts slightly; fine for ALAC, accepted caveat for AAC (parity was requested).
- **Memory:** non-FLAC path streams per track → *lower* peak RAM than the existing FLAC path (which decodes the whole file). 4g limit stays comfortable.
- **Rebase-friendliness:** change surface is one new file + a small `ExtractCUE` branch + `resolveCueAudioPath` extension + a non-behavioral refactor, so pulling future upstream updates stays easy.
