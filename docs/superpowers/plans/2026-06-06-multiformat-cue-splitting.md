# Multi-format CUE splitting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend unpackerr's `split_flac` cue-splitter beyond FLAC to APE/WV/M4A/WAV (output always FLAC), by adding an ffmpeg-backed path in the `xtractr` dependency while leaving the pure-Go FLAC path and tagging behavior unchanged.

**Architecture:** The split logic lives in `golift/xtractr` (`cue.go` → `ExtractCUE`). We branch on the resolved audio extension: `.flac` keeps the existing pure-Go path; `.ape/.wv/.m4a/.wav` go through a new `splitViaFFmpeg` (ffprobe for tags/duration → per-track sample-accurate `ffmpeg` cut to FLAC → `go-flac` metadata-only re-tag reusing a shared tag policy). `unpackerr` only needs a `go.mod replace` to the xtractr fork plus ffmpeg in its (already-alpine) image; the `split_flac` flag and Lidarr import flow are unchanged.

**Tech Stack:** Go 1.26 (xtractr `go.mod` pins toolchain `go1.26.1`), `os/exec` (ffmpeg/ffprobe), `github.com/go-flac/go-flac` + `flacvorbis` + `flacpicture` (pure-Go FLAC metadata editing, no audio re-encode), `mewkiz/flac` (existing FLAC path, untouched).

**Spec:** `docs/superpowers/specs/2026-06-06-multiformat-cue-splitting-design.md`

---

## Prerequisites (already done / verify)

- `~/Projects/xtractr` and `~/Projects/unpackerr` cloned, both on branch `enhanced`. Verify: `cd ~/Projects/xtractr && git branch --show-current` → `enhanced` (same for unpackerr).
- Local toolchain: `go version` (Go fetches `go1.26.1` automatically via `GOTOOLCHAIN=auto` if needed), and `ffmpeg -version` + `ffprobe -version` available locally to run the non-skipped tests.
- All xtractr work happens in `~/Projects/xtractr`; all unpackerr work in `~/Projects/unpackerr`. Commit in the repo a task touches.

## Conventions (apply to every task)

- **Test accessors go in `export_test.go`, not production files.** Several tasks below say "add accessor to `cue.go`/`cue_ffmpeg.go`" for helpers named `*ForTest`. Put **all** of those in a single new file `~/Projects/xtractr/export_test.go` with `package xtractr`. Files ending in `_test.go` are excluded from normal builds, so these stay out of the shipped API while remaining callable from the external `xtractr_test` package. (Production `.go` files must contain only production code.)
- **Imports:** add/remove imports per task as the Go compiler directs. The finished `cue_ffmpeg.go` uses `encoding/json`, `fmt`, `os`, `os/exec`, `path/filepath`, `strconv`, `strings`, and the three `go-flac` modules; `export_test.go` uses `path/filepath`, `os/exec`, `strconv`, plus the go-flac modules for read-back. Do not add the `var _ = os.Stat` placeholder shown in Task 6 — it's only there to illustrate; drop it and let imports follow real usage.

---

## Task 1: Generalize the unsupported-audio error and define the supported-extension set

**Files:**
- Modify: `~/Projects/xtractr/errors.go` (the `ErrUnsupportedAudio` line, ~line 29)
- Modify: `~/Projects/xtractr/cue.go` (add a package-level set near the top, after imports)

- [ ] **Step 1: Update the error message and add an ffmpeg-missing error.** In `errors.go`, under the `// CUE sheet.` group, replace the `ErrUnsupportedAudio` line and add `ErrFFmpegNotFound`:

```go
	ErrNoCueFile        = errors.New("cue sheet does not reference a FILE")
	ErrNoTracks         = errors.New("cue sheet contains no tracks")
	ErrAudioNotFound    = errors.New("audio file referenced by cue sheet not found")
	ErrUnsupportedAudio = errors.New("cue sheet references unsupported audio format (supported: flac, ape, wv, m4a, wav)")
	ErrFFmpegNotFound   = errors.New("ffmpeg and ffprobe are required to split non-flac audio but were not found in PATH")
```

- [ ] **Step 2: Add the supported-extension set.** In `cue.go`, immediately after the `import (...)` block, add:

```go
// supportedCueAudioExts lists the audio file extensions (lowercase, with dot)
// that ExtractCUE can split. FLAC uses the pure-Go path; the rest use ffmpeg.
var supportedCueAudioExts = []string{".flac", ".ape", ".wv", ".m4a", ".wav"}

// isSupportedCueAudioExt reports whether ext (lowercase, with leading dot) is splittable.
func isSupportedCueAudioExt(ext string) bool {
	for _, e := range supportedCueAudioExts {
		if e == ext {
			return true
		}
	}

	return false
}
```

- [ ] **Step 3: Verify it compiles.**

Run: `cd ~/Projects/xtractr && go build ./...`
Expected: builds with no errors (the new func is unused for now; that is fine for a package-level func).

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/xtractr
git add errors.go cue.go
git commit -m "feat(cue): generalize unsupported-audio error, add supported-ext set"
```

---

## Task 2: Add the go-flac metadata dependencies

**Files:**
- Modify: `~/Projects/xtractr/go.mod`, `~/Projects/xtractr/go.sum`

- [ ] **Step 1: Add the three go-flac modules.**

Run:
```bash
cd ~/Projects/xtractr
go get github.com/go-flac/go-flac/v2@latest
go get github.com/go-flac/flacvorbis/v2@latest
go get github.com/go-flac/flacpicture/v2@latest
```
Expected: `go.mod` gains the three `github.com/go-flac/...` requires.

- [ ] **Step 2: Verify the import paths resolve.** Create a throwaway file to confirm the API/import paths, then delete it:

```bash
cd ~/Projects/xtractr
cat > /tmp/goflac_probe.go <<'EOF'
package xtractr

import (
	_ "github.com/go-flac/flacpicture/v2"
	_ "github.com/go-flac/flacvorbis/v2"
	_ "github.com/go-flac/go-flac/v2"
)
EOF
cp /tmp/goflac_probe.go ./goflac_probe.go
go build ./... && echo "IMPORTS_OK"
rm ./goflac_probe.go
```
Expected: prints `IMPORTS_OK`. If a `/v2` path 404s, fall back to the non-`/v2` modules (`github.com/go-flac/go-flac`, `.../flacvorbis`, `.../flacpicture`) and use those import paths consistently in later tasks.

- [ ] **Step 3: Tidy and commit.**

```bash
cd ~/Projects/xtractr
go mod tidy
git add go.mod go.sum
git commit -m "build(cue): add go-flac metadata libs for ffmpeg re-tag path"
```

---

## Task 3: Extract a shared tag-merge policy (refactor, no behavior change)

**Files:**
- Modify: `~/Projects/xtractr/cue.go` (refactor `buildVorbisCommentBlock`, ~lines 624-677)
- Test: `~/Projects/xtractr/cue_test.go` (add one test)

- [ ] **Step 1: Write a failing test for the shared merge function.** Append to `cue_test.go`:

```go
func TestMergeTrackTags(t *testing.T) {
	t.Parallel()

	cue := &xtractr.CueSheet{Title: "The Album", Performer: "The Band"}
	track := &xtractr.CueTrack{Number: 3, Title: "Song Three", Performer: ""}
	source := [][2]string{
		{"GENRE", "Death Metal"},
		{"DATE", "2002"},
		{"ALBUM", "WRONG - should be ignored, cue wins"},
		{"REPLAYGAIN_TRACK_GAIN", "-6.0 dB"}, // not in merge allowlist -> dropped
	}

	got := xtractr.MergeTrackTags(cue, track, source)

	m := map[string]string{}
	for _, kv := range got {
		m[kv[0]] = kv[1]
	}

	require.Equal(t, "Song Three", m["TITLE"])
	require.Equal(t, "3", m["TRACKNUMBER"])
	require.Equal(t, "The Album", m["ALBUM"])     // cue wins over source
	require.Equal(t, "The Band", m["ARTIST"])     // falls back to album performer
	require.Equal(t, "Death Metal", m["GENRE"])   // merged from source
	require.Equal(t, "2002", m["DATE"])           // merged from source
	_, hasRG := m["REPLAYGAIN_TRACK_GAIN"]
	require.False(t, hasRG, "non-allowlisted source tag must be dropped")
}
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestMergeTrackTags`
Expected: FAIL — `undefined: xtractr.MergeTrackTags`.

- [ ] **Step 3: Implement `MergeTrackTags` and route `buildVorbisCommentBlock` through it.** In `cue.go`, add the exported function (it encodes the exact policy currently inline in `buildVorbisCommentBlock`):

```go
// MergeTrackTags returns the ordered Vorbis tag pairs for one track: TITLE,
// TRACKNUMBER, ALBUM, ARTIST from the CUE sheet, merged with allowlisted source
// tags (GENRE, DATE, ALBUMARTIST, ...). The CUE values win for the keys it owns.
// sourceTags is the source file's existing tags as upper-cased [key,value] pairs.
func MergeTrackTags(cue *CueSheet, track *CueTrack, sourceTags [][2]string) [][2]string {
	artist := track.Performer
	if artist == "" {
		artist = cue.Performer
	}

	title := track.Title
	if title == "" {
		title = fmt.Sprintf("Track %d", track.Number)
	}

	tags := [][2]string{
		{"TITLE", title},
		{"TRACKNUMBER", strconv.Itoa(track.Number)},
	}
	if cue.Title != "" {
		tags = append(tags, [2]string{"ALBUM", cue.Title})
	}

	if artist != "" {
		tags = append(tags, [2]string{"ARTIST", artist})
	}

	haveKey := map[string]bool{}
	for _, pair := range tags {
		haveKey[strings.ToUpper(pair[0])] = true
	}

	for _, pair := range sourceTags {
		tagKey := strings.ToUpper(pair[0])
		if vorbisTagsFromCUE()[tagKey] || haveKey[tagKey] {
			continue
		}

		if vorbisTagsToMergeFromSource()[tagKey] {
			tags = append(tags, [2]string{pair[0], pair[1]})
			haveKey[tagKey] = true
		}
	}

	return tags
}
```

Then replace the body of `buildVorbisCommentBlock` (keep its signature) so it delegates:

```go
func buildVorbisCommentBlock(cue *CueSheet, track *CueTrack, sourceVorbis *meta.VorbisComment) *meta.Block {
	var source [][2]string
	if sourceVorbis != nil {
		source = sourceVorbis.Tags
	}

	pairs := MergeTrackTags(cue, track, source)

	comment := &meta.VorbisComment{
		Vendor: "golift.io/xtractr",
		Tags:   pairs,
	}

	return &meta.Block{
		Header: meta.Header{Type: meta.TypeVorbisComment, Length: 1},
		Body:   comment,
	}
}
```

- [ ] **Step 4: Run the new test and the full FLAC suite to prove no regression.**

Run: `cd ~/Projects/xtractr && go test ./... -run 'TestMergeTrackTags|TestExtractCUE|Cue'`
Expected: PASS (new test passes; existing cue tests still pass — the FLAC path output is unchanged).

- [ ] **Step 5: Commit.**

```bash
cd ~/Projects/xtractr
git add cue.go cue_test.go
git commit -m "refactor(cue): extract shared MergeTrackTags policy (no behavior change)"
```

---

## Task 4: Add CUE timestamp → seconds and per-track boundary helpers

**Files:**
- Modify: `~/Projects/xtractr/cue.go` (add methods near `toSamples`, ~line 63)
- Test: `~/Projects/xtractr/cue_test.go`

- [ ] **Step 1: Write failing tests.** Append to `cue_test.go`:

```go
func TestCueTimestampSeconds_And_Boundaries(t *testing.T) {
	t.Parallel()

	// 1:30:37 -> 90 + 37/75 = 90.4933... seconds
	require.InDelta(t, 90.49333, xtractr.SecondsForTest(1, 30, 37), 0.0001)

	// Three tracks starting at 0, 60.0, 150.0 seconds; total 200s.
	starts := []float64{0, 60.0, 150.0}
	durs := xtractr.TrackDurationsForTest(starts, 200.0)
	require.Len(t, durs, 3)
	require.InDelta(t, 60.0, durs[0], 0.0001)
	require.InDelta(t, 90.0, durs[1], 0.0001)
	require.Equal(t, 0.0, durs[2]) // last track: 0 means "to EOF"
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestCueTimestampSeconds_And_Boundaries`
Expected: FAIL — `undefined: xtractr.SecondsForTest` / `xtractr.TrackDurationsForTest`.

- [ ] **Step 3: Implement the helpers.** In `cue.go` add:

```go
// toSeconds converts a CUE timestamp (MM:SS:FF) to seconds.
func (t cueTimestamp) toSeconds() float64 {
	const (
		secondsPerMinute = 60
		framesPerSecond  = cdFramesPerSecond // 75
	)

	return float64(t.minutes*secondsPerMinute+t.seconds) + float64(t.frames)/framesPerSecond
}

// trackDurations returns the duration (seconds) of each track given the ordered
// start times and the total source duration. The final track's duration is 0,
// signalling "encode to EOF" (no -t flag) so it captures any trailing samples.
func trackDurations(starts []float64, total float64) []float64 {
	durs := make([]float64, len(starts))
	for i := range starts {
		if i < len(starts)-1 {
			durs[i] = starts[i+1] - starts[i]
		} else {
			durs[i] = 0 // last track -> to EOF
		}
	}

	return durs
}
```

Also add test-only exported shims at the end of `cue.go` (kept tiny; they let the external `xtractr_test` package exercise unexported helpers):

```go
// SecondsForTest exposes cueTimestamp.toSeconds for tests.
func SecondsForTest(min, sec, frames int) float64 {
	return cueTimestamp{minutes: min, seconds: sec, frames: frames}.toSeconds()
}

// TrackDurationsForTest exposes trackDurations for tests.
func TrackDurationsForTest(starts []float64, total float64) []float64 {
	return trackDurations(starts, total)
}
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestCueTimestampSeconds_And_Boundaries`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
cd ~/Projects/xtractr
git add cue.go cue_test.go
git commit -m "feat(cue): add timestamp->seconds and per-track duration helpers"
```

---

## Task 5: Extend `resolveCueAudioPath` to try all supported extensions

**Files:**
- Modify: `~/Projects/xtractr/cue.go` (`resolveCueAudioPath`, ~lines 303-332)
- Test: `~/Projects/xtractr/cue_test.go`

- [ ] **Step 1: Write a failing test.** Append to `cue_test.go`:

```go
func TestResolveCueAudioPath_AltExtensions(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	// CUE names album.wav, but only album.ape exists on disk.
	apePath := filepath.Join(dir, "album.ape")
	require.NoError(t, os.WriteFile(apePath, []byte("not really ape"), 0o644))
	cuePath := filepath.Join(dir, "album.cue")
	require.NoError(t, os.WriteFile(cuePath, []byte(`FILE "album.wav" WAVE`+"\n"), 0o644))

	got, err := xtractr.ResolveCueAudioPathForTest(dir, "album.wav", cuePath)
	require.NoError(t, err)
	require.Equal(t, apePath, got)
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestResolveCueAudioPath_AltExtensions`
Expected: FAIL — `undefined: xtractr.ResolveCueAudioPathForTest` (and the logic doesn't try `.ape` yet).

- [ ] **Step 3: Rewrite `resolveCueAudioPath` to probe all supported extensions, and add a test shim.** Replace the function body:

```go
// resolveCueAudioPath returns the path to the audio file referenced by the CUE.
// It first tries the exact FILE reference, then the same basename with each
// supported audio extension, then the CUE's own basename with each supported
// extension (handles encoding mismatches like O vs Ö and wrong-container CUEs).
func resolveCueAudioPath(cueDir, cueFile, cueFilePath string) (string, error) {
	// 1) Exact path from the FILE line.
	exact := filepath.Join(cueDir, cueFile)
	if _, err := os.Stat(exact); err == nil {
		return exact, nil
	}

	// 2) FILE basename + each supported extension.
	fileBase := strings.TrimSuffix(cueFile, filepath.Ext(cueFile))
	// 3) CUE basename + each supported extension (fallback for name mismatches).
	cueBase := strings.TrimSuffix(filepath.Base(cueFilePath), filepath.Ext(cueFilePath))

	for _, base := range []string{fileBase, cueBase} {
		for _, ext := range supportedCueAudioExts {
			candidate := filepath.Join(cueDir, base+ext)
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
		}
	}

	return "", fmt.Errorf("%w: %s", ErrAudioNotFound, exact)
}
```

Add the test shim at the end of `cue.go`:

```go
// ResolveCueAudioPathForTest exposes resolveCueAudioPath for tests.
func ResolveCueAudioPathForTest(cueDir, cueFile, cueFilePath string) (string, error) {
	return resolveCueAudioPath(cueDir, cueFile, cueFilePath)
}
```

- [ ] **Step 4: Run the new test plus the existing FLAC cue tests (the original `.wav→.flac` case must still pass).**

Run: `cd ~/Projects/xtractr && go test ./... -run 'TestResolveCueAudioPath|TestExtractCUE|Cue'`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
cd ~/Projects/xtractr
git add cue.go cue_test.go
git commit -m "feat(cue): resolve cue audio across all supported extensions"
```

---

## Task 6: ffmpeg/ffprobe detection + `probeAudio`

**Files:**
- Create: `~/Projects/xtractr/cue_ffmpeg.go`
- Create: `~/Projects/xtractr/cue_ffmpeg_test.go`

- [ ] **Step 1: Create `cue_ffmpeg.go` with detection + probe.**

```go
package xtractr

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// ffmpegAvailable reports whether both ffmpeg and ffprobe are on PATH.
func ffmpegAvailable() bool {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		return false
	}

	_, err := exec.LookPath("ffprobe")

	return err == nil
}

// audioProbe holds the bits of ffprobe output we use.
type audioProbe struct {
	durationSec float64
	tags        [][2]string // upper-cased source tags (album-level)
	hasCover    bool        // an attached_pic video stream is present
}

// ffprobeFormat mirrors the JSON we read from ffprobe.
type ffprobeOutput struct {
	Format struct {
		Duration string            `json:"duration"`
		Tags     map[string]string `json:"tags"`
	} `json:"format"`
	Streams []struct {
		CodecType  string `json:"codec_type"`
		Disposition struct {
			AttachedPic int `json:"attached_pic"`
		} `json:"disposition"`
		Tags map[string]string `json:"tags"`
	} `json:"streams"`
}

// probeAudio runs ffprobe and returns duration, album-level source tags, and
// whether the file carries embedded cover art.
func probeAudio(path string) (*audioProbe, error) {
	cmd := exec.Command("ffprobe", "-v", "error", "-print_format", "json",
		"-show_format", "-show_streams", path)

	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe %s: %w", path, err)
	}

	var parsed ffprobeOutput
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("parsing ffprobe json: %w", err)
	}

	probe := &audioProbe{}
	probe.durationSec, _ = strconv.ParseFloat(strings.TrimSpace(parsed.Format.Duration), 64)

	for key, val := range parsed.Format.Tags {
		probe.tags = append(probe.tags, [2]string{strings.ToUpper(key), val})
	}

	for _, s := range parsed.Streams {
		if s.CodecType == "video" && s.Disposition.AttachedPic == 1 {
			probe.hasCover = true
		}
	}

	return probe, nil
}

// SupportedExt is the dot-extension test exported for callers/tests.
func SupportedExt(ext string) bool { return isSupportedCueAudioExt(strings.ToLower(ext)) }

var _ = os.Stat // keep os imported for later steps in this file
```

- [ ] **Step 2: Write a probe test (skips without ffmpeg).** Create `cue_ffmpeg_test.go`:

```go
package xtractr_test

import (
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"golift.io/xtractr"
)

// ffmpegOrSkip skips the test when ffmpeg/ffprobe are not installed.
func ffmpegOrSkip(t *testing.T) {
	t.Helper()

	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not found in PATH; skipping ffmpeg-backed test")
	}

	if _, err := exec.LookPath("ffprobe"); err != nil {
		t.Skip("ffprobe not found in PATH; skipping ffmpeg-backed test")
	}
}

// makeSineSource writes a `seconds`-long stereo source at outPath using ffmpeg's
// sine generator, encoded by extension (.wav/.flac/.ape/.wv).
func makeSineSource(t *testing.T, outPath string, seconds int) {
	t.Helper()

	cmd := exec.Command("ffmpeg", "-y", "-v", "error",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration="+
			intToStr(seconds), "-ac", "2", outPath)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "ffmpeg gen: %s", string(out))
}

func intToStr(i int) string { return strconvItoa(i) }

func TestProbeAudio_Duration(t *testing.T) {
	t.Parallel()
	ffmpegOrSkip(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "src.flac")
	makeSineSource(t, src, 5)

	got := xtractr.ProbeDurationForTest(t, src)
	require.InDelta(t, 5.0, got, 0.2)
}
```

Add the two tiny helpers the test references to the bottom of `cue_ffmpeg_test.go`:

```go
import "strconv"

func strconvItoa(i int) string { return strconv.Itoa(i) }
```

(If your linter dislikes the mid-file import, move `import "strconv"` into the top import block and delete this line; keep `strconvItoa`.)

And add the test accessor to `cue_ffmpeg.go` (so the external test package can call `probeAudio`):

```go
// ProbeDurationForTest exposes probeAudio's duration for tests.
func ProbeDurationForTest(t interface{ Fatalf(string, ...any) }, path string) float64 {
	p, err := probeAudio(path)
	if err != nil {
		t.Fatalf("probeAudio: %v", err)
	}

	return p.durationSec
}
```

- [ ] **Step 3: Run the probe test.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestProbeAudio_Duration -v`
Expected: PASS (or SKIP if no ffmpeg — install ffmpeg to actually exercise it).

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/xtractr
git add cue_ffmpeg.go cue_ffmpeg_test.go
git commit -m "feat(cue): ffmpeg detection and ffprobe audio probe"
```

---

## Task 7: Per-track ffmpeg cut to FLAC

**Files:**
- Modify: `~/Projects/xtractr/cue_ffmpeg.go`
- Modify: `~/Projects/xtractr/cue_ffmpeg_test.go`

- [ ] **Step 1: Add `cutTrackFLAC`.** Append to `cue_ffmpeg.go`:

```go
// cutTrackFLAC encodes one track to FLAC from src, starting at startSec.
// If durSec > 0 a -t duration is applied; durSec == 0 means "to EOF" (last track).
// No metadata is copied from the source (-map_metadata -1); tagging happens later.
// Input -ss + default accurate_seek yields sample-accurate cuts for lossless audio.
func cutTrackFLAC(src, outPath string, startSec, durSec float64) error {
	args := []string{"-nostdin", "-v", "error", "-ss", formatSeconds(startSec), "-i", src}
	if durSec > 0 {
		args = append(args, "-t", formatSeconds(durSec))
	}

	args = append(args, "-vn", "-c:a", "flac", "-compression_level", "8",
		"-map_metadata", "-1", "-y", outPath)

	cmd := exec.Command("ffmpeg", args...)

	stderr, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg cut %s: %w: %s", outPath, err, strings.TrimSpace(string(stderr)))
	}

	return nil
}

// formatSeconds renders seconds for ffmpeg with microsecond precision.
func formatSeconds(s float64) string {
	return strconv.FormatFloat(s, 'f', 6, 64)
}
```

- [ ] **Step 2: Write a failing test for an accurate cut.** Append to `cue_ffmpeg_test.go`:

```go
func TestCutTrackFLAC_Duration(t *testing.T) {
	t.Parallel()
	ffmpegOrSkip(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "src.flac")
	makeSineSource(t, src, 10)

	out := filepath.Join(dir, "track.flac")
	require.NoError(t, xtractr.CutTrackFLACForTest(src, out, 2.0, 3.0)) // 2s..5s -> 3s

	got := xtractr.ProbeDurationForTest(t, out)
	require.InDelta(t, 3.0, got, 0.05) // sample-accurate within ~50ms
}
```

Add the accessor to `cue_ffmpeg.go`:

```go
// CutTrackFLACForTest exposes cutTrackFLAC for tests.
func CutTrackFLACForTest(src, out string, startSec, durSec float64) error {
	return cutTrackFLAC(src, out, startSec, durSec)
}
```

- [ ] **Step 3: Run it.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestCutTrackFLAC_Duration -v`
Expected: PASS (or SKIP without ffmpeg).

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/xtractr
git add cue_ffmpeg.go cue_ffmpeg_test.go
git commit -m "feat(cue): per-track sample-accurate ffmpeg cut to flac"
```

---

## Task 8: go-flac re-tag + cover extraction

**Files:**
- Modify: `~/Projects/xtractr/cue_ffmpeg.go`
- Modify: `~/Projects/xtractr/cue_ffmpeg_test.go`

- [ ] **Step 1: Add cover extraction and the metadata-only re-tag.** Append to `cue_ffmpeg.go` (adjust import paths to match Task 2's resolved modules):

```go
import (
	goflac "github.com/go-flac/go-flac/v2"
	"github.com/go-flac/flacpicture/v2"
	"github.com/go-flac/flacvorbis/v2"
)

// extractCover writes embedded cover art from src to destNoExt + the right
// extension and returns the written path, or "" if there is no cover.
func extractCover(src, destNoExt string) string {
	// Try to copy the attached picture stream verbatim to a .jpg, then .png.
	for _, ext := range []string{".jpg", ".png"} {
		dest := destNoExt + ext

		cmd := exec.Command("ffmpeg", "-nostdin", "-v", "error", "-y",
			"-i", src, "-an", "-c:v", "copy", "-frames:v", "1", dest)
		if err := cmd.Run(); err == nil {
			if fi, statErr := os.Stat(dest); statErr == nil && fi.Size() > 0 {
				return dest
			}
		}

		_ = os.Remove(dest)
	}

	return ""
}

// retagFLAC writes Vorbis tags (and an optional cover) onto an existing FLAC
// using metadata-only edits — the audio frames are not re-encoded.
func retagFLAC(path string, tagPairs [][2]string, coverPath string, fileMode os.FileMode) error {
	f, err := goflac.ParseFile(path)
	if err != nil {
		return fmt.Errorf("parsing flac for retag: %w", err)
	}

	// Drop any existing VORBIS_COMMENT / PICTURE blocks (ffmpeg wrote none, but be safe).
	kept := f.Meta[:0]
	for _, b := range f.Meta {
		if b.Type == goflac.VorbisComment || b.Type == goflac.Picture {
			continue
		}

		kept = append(kept, b)
	}

	f.Meta = kept

	cmt := flacvorbis.New()
	cmt.Vendor = "golift.io/xtractr"

	for _, kv := range tagPairs {
		if addErr := cmt.Add(kv[0], kv[1]); addErr != nil {
			return fmt.Errorf("adding tag %s: %w", kv[0], addErr)
		}
	}

	cmtBlock := cmt.Marshal()
	f.Meta = append(f.Meta, &cmtBlock)

	if coverPath != "" {
		data, readErr := os.ReadFile(coverPath)
		if readErr == nil {
			mime := "image/jpeg"
			if strings.HasSuffix(strings.ToLower(coverPath), ".png") {
				mime = "image/png"
			}

			pic, picErr := flacpicture.NewFromImageData(
				flacpicture.PictureTypeFrontCover, "", data, mime)
			if picErr == nil {
				picBlock := pic.Marshal()
				f.Meta = append(f.Meta, &picBlock)
			}
		}
	}

	if err := f.Save(path); err != nil {
		return fmt.Errorf("saving retagged flac: %w", err)
	}

	_ = os.Chmod(path, fileMode)

	return nil
}
```

Merge the new `import (...)` block with the file's existing imports (one import block per file). Keep `strconv`, `strings`, `os`, `os/exec`, `encoding/json`, `fmt`.

- [ ] **Step 2: Write a re-tag test.** Append to `cue_ffmpeg_test.go`:

```go
func TestRetagFLAC_WritesTags(t *testing.T) {
	t.Parallel()
	ffmpegOrSkip(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "src.flac")
	makeSineSource(t, src, 2)

	pairs := [][2]string{{"TITLE", "Hello"}, {"TRACKNUMBER", "1"}, {"ALBUM", "Demo"}}
	require.NoError(t, xtractr.RetagFLACForTest(src, pairs, "", 0o644))

	got := xtractr.ReadVorbisTagForTest(t, src, "TITLE")
	require.Equal(t, "Hello", got)
}
```

Add accessors to `cue_ffmpeg.go`:

```go
// RetagFLACForTest exposes retagFLAC for tests.
func RetagFLACForTest(path string, tagPairs [][2]string, coverPath string, mode os.FileMode) error {
	return retagFLAC(path, tagPairs, coverPath, mode)
}

// ReadVorbisTagForTest reads back a single Vorbis tag value (first match).
func ReadVorbisTagForTest(t interface{ Fatalf(string, ...any) }, path, key string) string {
	f, err := goflac.ParseFile(path)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	for _, b := range f.Meta {
		if b.Type != goflac.VorbisComment {
			continue
		}

		cmt, perr := flacvorbis.ParseFromMetaDataBlock(*b)
		if perr != nil {
			t.Fatalf("parse vorbis: %v", perr)
		}

		vals, _ := cmt.Get(key)
		if len(vals) > 0 {
			return vals[0]
		}
	}

	return ""
}
```

- [ ] **Step 3: Run it.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestRetagFLAC_WritesTags -v`
Expected: PASS (or SKIP without ffmpeg). If `flacvorbis.New()` / `cmt.Vendor` / `ParseFromMetaDataBlock` / `cmt.Get` differ in the resolved module version, fix the call to match its API (the test will tell you) and keep going.

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/xtractr
git add cue_ffmpeg.go cue_ffmpeg_test.go
git commit -m "feat(cue): metadata-only go-flac re-tag and cover extraction"
```

---

## Task 9: `splitViaFFmpeg` orchestration

**Files:**
- Modify: `~/Projects/xtractr/cue_ffmpeg.go`
- Modify: `~/Projects/xtractr/cue_ffmpeg_test.go`

- [ ] **Step 1: Add the orchestrator.** Append to `cue_ffmpeg.go`:

```go
// splitViaFFmpeg splits a non-FLAC source referenced by a CUE into per-track
// FLACs in xFile.OutputDir, tagging each via go-flac. Mirrors ExtractCUE's
// return contract: (totalBytes, outputFiles, [cue, audio]).
func splitViaFFmpeg(xFile *XFile, audioPath string, cue *CueSheet, timestamps []cueTimestamp) (uint64, []string, error) {
	if !ffmpegAvailable() {
		return 0, nil, ErrFFmpegNotFound
	}

	probe, err := probeAudio(audioPath)
	if err != nil {
		return 0, nil, err
	}

	if err := os.MkdirAll(xFile.OutputDir, xFile.DirMode); err != nil {
		return 0, nil, fmt.Errorf("creating output directory: %w", err)
	}

	starts := make([]float64, len(timestamps))
	for i, ts := range timestamps {
		starts[i] = ts.toSeconds()
	}

	durs := trackDurations(starts, probe.durationSec)

	// Cover art once, shared by all tracks (named like the FLAC path: cover.jpg/png).
	var coverPath string
	if probe.hasCover {
		coverPath = extractCover(audioPath, filepath.Join(xFile.OutputDir, "cover"))
	}

	var (
		total uint64
		files = make([]string, 0, len(cue.Tracks)+2)
	)

	for i := range cue.Tracks {
		track := &cue.Tracks[i]
		outName := formatTrackFilename(track) // shared with FLAC path
		outPath := filepath.Join(xFile.OutputDir, outName)

		if err := cutTrackFLAC(audioPath, outPath, starts[i], durs[i]); err != nil {
			return total, files, err
		}

		pairs := MergeTrackTags(cue, track, probe.tags)
		if err := retagFLAC(outPath, pairs, coverPath, xFile.FileMode); err != nil {
			return total, files, err
		}

		if fi, statErr := os.Stat(outPath); statErr == nil {
			total += uint64(fi.Size())
		}

		files = append(files, outPath)
		xFile.Debugf("Wrote track %d via ffmpeg: %s", track.Number, outPath)
	}

	if coverPath != "" {
		files = append(files, coverPath)
	}

	return total, files, nil
}
```

- [ ] **Step 2: Write an end-to-end split test (WAV source + cue).** Append to `cue_ffmpeg_test.go`:

```go
func TestSplitViaFFmpeg_EndToEnd(t *testing.T) {
	t.Parallel()
	ffmpegOrSkip(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "album.wav")
	makeSineSource(t, src, 9) // 9-second source

	cue := `PERFORMER "The Band"
TITLE "The Album"
FILE "album.wav" WAVE
  TRACK 01 AUDIO
    TITLE "One"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Two"
    INDEX 01 00:03:00
  TRACK 03 AUDIO
    TITLE "Three"
    INDEX 01 00:06:00`
	cuePath := filepath.Join(dir, "album.cue")
	require.NoError(t, os.WriteFile(cuePath, []byte(cue), 0o644))

	out := t.TempDir()
	size, files := xtractr.SplitViaFFmpegForTest(t, dir, "album.wav", cuePath, out)

	require.Equal(t, 3, len(files), "expected 3 track files (no cover)")
	require.Greater(t, size, uint64(0))

	// Each track ~3s; second track should be tagged "Two".
	require.Equal(t, "Two", xtractr.ReadVorbisTagForTest(t, filepath.Join(out, "02 - Two.flac"), "TITLE"))
	require.Equal(t, "The Album", xtractr.ReadVorbisTagForTest(t, filepath.Join(out, "02 - Two.flac"), "ALBUM"))
}
```

Add the test accessor to `cue_ffmpeg.go` (parses the cue with the existing parser, then runs the orchestrator):

```go
// SplitViaFFmpegForTest wires parse + resolve + split for end-to-end tests.
func SplitViaFFmpegForTest(t interface{ Fatalf(string, ...any) }, cueDir, cueFile, cuePath, outDir string) (uint64, []string) {
	cue, timestamps, err := parseCueSheetFile(cuePath)
	if err != nil {
		t.Fatalf("parse cue: %v", err)
	}

	audioPath, err := resolveCueAudioPath(cueDir, cueFile, cuePath)
	if err != nil {
		t.Fatalf("resolve audio: %v", err)
	}

	xFile := &XFile{OutputDir: outDir, FileMode: 0o644, DirMode: 0o755}

	size, files, err := splitViaFFmpeg(xFile, audioPath, cue, timestamps)
	if err != nil {
		t.Fatalf("split: %v", err)
	}

	return size, files
}
```

- [ ] **Step 3: Run it.**

Run: `cd ~/Projects/xtractr && go test ./... -run TestSplitViaFFmpeg_EndToEnd -v`
Expected: PASS (or SKIP without ffmpeg).

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/xtractr
git add cue_ffmpeg.go cue_ffmpeg_test.go
git commit -m "feat(cue): splitViaFFmpeg orchestration (probe, cut, retag, art)"
```

---

## Task 10: Wire the dispatch in `ExtractCUE`

**Files:**
- Modify: `~/Projects/xtractr/cue.go` (`ExtractCUE`, the ext gate ~lines 93-99)

- [ ] **Step 1: Replace the FLAC-only gate with the codec branch.** In `ExtractCUE`, the current block is:

```go
	// Only FLAC is supported for now.
	ext := strings.ToLower(filepath.Ext(audioPath))
	if ext != ".flac" {
		return 0, nil, nil, fmt.Errorf("%w: %s", ErrUnsupportedAudio, ext)
	}

	size, files, err = splitFLAC(xFile, audioPath, cue, timestamps)
	if err != nil {
		return 0, nil, nil, err
	}
```

Replace it with:

```go
	ext := strings.ToLower(filepath.Ext(audioPath))

	switch {
	case ext == ".flac":
		size, files, err = splitFLAC(xFile, audioPath, cue, timestamps)
	case isSupportedCueAudioExt(ext): // .ape/.wv/.m4a/.wav -> ffmpeg path
		size, files, err = splitViaFFmpeg(xFile, audioPath, cue, timestamps)
	default:
		return 0, nil, nil, fmt.Errorf("%w: %s", ErrUnsupportedAudio, ext)
	}

	if err != nil {
		return 0, nil, nil, err
	}
```

The code after this (copying the CUE into the output, building `archives = [cue, audioPath]`, returning) is unchanged and now applies to all formats.

- [ ] **Step 2: Write an integration test that drives `ExtractCUE` on a non-FLAC source.** Append to `cue_ffmpeg_test.go`:

```go
func TestExtractCUE_APE_EndToEnd(t *testing.T) {
	t.Parallel()
	ffmpegOrSkip(t)

	// Build a real .ape source if the encoder is available; else .wv; else skip.
	dir := t.TempDir()
	src := filepath.Join(dir, "album.ape")
	if err := tryMakeSource(src, 6); err != nil {
		t.Skipf("no ape encoder in this ffmpeg build: %v", err)
	}

	cue := `TITLE "Album"
FILE "album.ape" WAVE
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 01 00:03:00`
	require.NoError(t, os.WriteFile(filepath.Join(dir, "album.cue"), []byte(cue), 0o644))

	out := t.TempDir()
	size, files, archives := xtractr.ExtractCUEForTest(t, filepath.Join(dir, "album.cue"), out)

	require.Greater(t, size, uint64(0))
	require.GreaterOrEqual(t, len(files), 2)   // 2 tracks (+ copied cue)
	require.Len(t, archives, 2)                // [cue, audio]
}

// tryMakeSource attempts to encode a sine source at outPath; returns the ffmpeg error.
func tryMakeSource(outPath string, seconds int) error {
	cmd := exec.Command("ffmpeg", "-y", "-v", "error", "-f", "lavfi",
		"-i", "sine=frequency=440:sample_rate=44100:duration="+strconvItoa(seconds),
		"-ac", "2", outPath)

	return cmd.Run()
}
```

Add the `ExtractCUE` test accessor to `cue_ffmpeg.go`:

```go
// ExtractCUEForTest runs the full ExtractCUE on a .cue path for integration tests.
func ExtractCUEForTest(t interface{ Fatalf(string, ...any) }, cuePath, outDir string) (uint64, []string, []string) {
	xFile := &XFile{FilePath: cuePath, OutputDir: outDir, FileMode: 0o644, DirMode: 0o755}

	size, files, archives, err := ExtractCUE(xFile)
	if err != nil {
		t.Fatalf("ExtractCUE: %v", err)
	}

	return size, files, archives
}
```

- [ ] **Step 3: Run the full xtractr suite.**

Run: `cd ~/Projects/xtractr && go test ./...`
Expected: PASS (ffmpeg tests run if ffmpeg present, else skip; all existing tests pass).

- [ ] **Step 4: Vet, then commit.**

```bash
cd ~/Projects/xtractr
go vet ./...
git add cue.go cue_ffmpeg.go cue_ffmpeg_test.go
git commit -m "feat(cue): dispatch non-flac cue audio through ffmpeg path"
```

---

## Task 11: Point unpackerr at the xtractr fork and build

**Files:**
- Modify: `~/Projects/unpackerr/go.mod`

- [ ] **Step 1: Add the replace directive.**

Run:
```bash
cd ~/Projects/unpackerr
go mod edit -replace golift.io/xtractr=../xtractr
go mod tidy
```
Expected: `go.mod` gains `replace golift.io/xtractr => ../xtractr`.

- [ ] **Step 2: Build unpackerr against the fork.**

Run: `cd ~/Projects/unpackerr && go build ./...`
Expected: builds cleanly (the new xtractr exported names don't change unpackerr's existing calls).

- [ ] **Step 3: Run unpackerr's tests.**

Run: `cd ~/Projects/unpackerr && go test ./...`
Expected: PASS.

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/unpackerr
git add go.mod go.sum
git commit -m "build: use enhanced xtractr fork (multi-format cue splitting)"
```

---

## Task 12: Add ffmpeg to the image and reword the Lidarr log line

**Files:**
- Modify: `~/Projects/unpackerr/init/docker/Dockerfile` (the final-stage `apk add` line)
- Modify: `~/Projects/unpackerr/pkg/unpackerr/lidarr.go` (the `split_flac` log line, ~line 48)

- [ ] **Step 1: Add ffmpeg to the runtime image.** In `init/docker/Dockerfile`, change:

```dockerfile
RUN apk add --no-cache openssl tzdata
```
to:
```dockerfile
RUN apk add --no-cache openssl tzdata ffmpeg
```

- [ ] **Step 2: Reword the startup log so it isn't FLAC-specific.** In `lidarr.go`, find the `split_flac:%v` log format string (~line 48/57) and change the literal label from `split_flac` to `split_audio(flac,ape,wv,m4a,wav)` in the **printed text only** — do not rename the struct field or toml key. Example (match your exact line):

```go
		u.Printf(" => Lidarr Config: 1 server: "+starrLogLine+", split_audio(flac/ape/wv/m4a/wav):%v",
```

(Leave the second occurrence's format string consistent.)

- [ ] **Step 3: Build to confirm the Go change compiles.**

Run: `cd ~/Projects/unpackerr && go build ./...`
Expected: builds cleanly.

- [ ] **Step 4: Commit.**

```bash
cd ~/Projects/unpackerr
git add init/docker/Dockerfile pkg/unpackerr/lidarr.go
git commit -m "feat: ship ffmpeg in image; reword split log for multi-format"
```

---

## Task 13: Build the enhanced image and verify end-to-end on the stack

**Files:** none (build/deploy/verify). This task is run by a human-in-the-loop; it touches the live TrueNAS stack.

- [ ] **Step 1: Build the image locally (push-capable Docker login is on this machine).**

For a local-only `replace ../xtractr` build, build with the xtractr source in context. From `~/Projects`:
```bash
cd ~/Projects
docker build -f unpackerr/init/docker/Dockerfile -t tomvaisbort/unpackerr:enhanced \
  --build-arg VERSION=0.15.2-enhanced --build-arg BRANCH=enhanced .
```
If the Dockerfile's `COPY` context assumes the unpackerr repo root (it copies `main.go pkg ...`), instead vendor the fork into the build: either (a) push the xtractr `enhanced` branch to a fork remote and switch `go.mod` to `replace golift.io/xtractr => github.com/<you>/xtractr enhanced`, or (b) add a build stage that copies `../xtractr` in. Choose (a) for a clean reproducible image; note which you used.
Expected: image `tomvaisbort/unpackerr:enhanced` built.

- [ ] **Step 2: Push (explicit, outward-facing — confirm with the user first).**

```bash
docker push tomvaisbort/unpackerr:enhanced
```

- [ ] **Step 3: Swap the stack image.** On TrueNAS (`ssh -i ~/.ssh/id_ed25519 root@truenas`), in `/mnt/Fast/docker/stacks/media-server/compose.yaml`, change the `unpackerr` service `image:` to `tomvaisbort/unpackerr:enhanced` (back up the compose first), then:

```bash
cd /mnt/Fast/docker/stacks/media-server && docker compose up -d unpackerr
docker logs media-server-unpackerr-1 2>&1 | head -25
```
Expected: startup banner shows the Lidarr server with the split flag enabled; `[Lidarr] Updated ...` connects.

- [ ] **Step 4: Real-album verification.** Ensure a single-file **APE+cue** album is in Lidarr's queue (grab one, or temporarily move an existing `*.ape` + `.cue` into a Lidarr-queued download path). Watch:

```bash
docker logs -f media-server-unpackerr-1 2>&1 | grep -iE "Extract|Imported|error"
```
Expected: `Extraction Queued` → `Extraction Finished ... files extracted: N` → `Manual import triggered` → Lidarr import; library gets tagged FLAC tracks; original `.ape`+`.cue` preserved (moves to `lidarr-imported`, seed intact).

- [ ] **Step 5: Record results.** Note any ffmpeg build gaps (e.g. no APE encoder in the alpine ffmpeg — decode is what matters, alpine ffmpeg decodes APE/WV/ALAC) and confirm WAV/APE/WV/M4A each split correctly with at least one real sample.

---

## Self-Review notes (author)

- **Spec coverage:** dispatch (T10), resolveCueAudioPath multi-ext (T5), splitViaFFmpeg probe/cut/retag/art (T6-T9), shared tag policy (T3), go-flac dep (T2), unpackerr replace + image ffmpeg + log (T11-T12), tests + e2e (T6-T10, T13), graceful ffmpeg-missing (T9 `ErrFFmpegNotFound`). All spec sections map to a task.
- **Type consistency:** `MergeTrackTags(cue,track,[][2]string) [][2]string`, `probeAudio→*audioProbe{durationSec,tags,hasCover}`, `cutTrackFLAC(src,out,start,dur)`, `retagFLAC(path,pairs,cover,mode)`, `splitViaFFmpeg(xFile,audioPath,cue,timestamps)` are used consistently across tasks.
- **Known risk to watch during execution:** exact go-flac/flacvorbis/flacpicture API (constructor, `Add`, `Marshal`, `ParseFromMetaDataBlock`, `Get`, block `Type` constants) can differ by module version — Task 8's test surfaces mismatches immediately; adjust calls to the resolved version and continue.
