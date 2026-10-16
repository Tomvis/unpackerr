package unpackerr

import (
	"testing"

	"golift.io/starr/lidarr"
	"golift.io/xtractr"
)

// Fork: an unset ape_format must not forward APE options, or xtractr skips its ffmpeg FLAC path.
func TestLidarrTweakExtractAPEOptsOnlyWhenChosen(t *testing.T) {
	t.Parallel()

	cases := []struct {
		format      string
		wantFormat  xtractr.AudioFormat
		wantCompLvl int
	}{
		{"", "", 0},
		{"wav", "wav", apeCompressionNormal},
		{"APE", "ape", apeCompressionNormal},
	}

	for _, tc := range cases {
		cfg := &LidarrConfig{APEFormat: tc.format}
		if err := cfg.validateSettings(); err != nil {
			t.Fatalf("validateSettings(%q): %v", tc.format, err)
		}

		item := &Extract{}
		cfg.tweakExtract(item, queueView{})

		if item.APEFormat != tc.wantFormat || item.APECompression != tc.wantCompLvl {
			t.Errorf("ape_format %q: got (%q, %d), want (%q, %d)",
				tc.format, item.APEFormat, item.APECompression, tc.wantFormat, tc.wantCompLvl)
		}
	}
}

// Fork (MUSIC-101): a file Lidarr matched to no track must not reach ManualImport;
// Lidarr throws "Sequence contains no elements" importing it.
func TestDropTracklessOutputs(t *testing.T) {
	t.Parallel()

	keep := &lidarr.ManualImportOutput{Path: "/d/CD2/01 - Rip It Up.flac", Tracks: []*lidarr.Track{{ID: 1}}}
	outputs := []*lidarr.ManualImportOutput{
		keep,
		{Path: "/d/CD2/13 - I Want You.flac"},
		{Path: "/d/CD2/14 - Hound Dog.flac", Tracks: []*lidarr.Track{nil}},
		nil,
	}

	got, dropped := dropTracklessOutputs(outputs)
	if len(got) != 1 || got[0] != keep {
		t.Fatalf("kept %v, want only %q", got, keep.Path)
	}

	if len(dropped) != 2 || dropped[0] != "13 - I Want You.flac" || dropped[1] != "14 - Hound Dog.flac" {
		t.Errorf("dropped %v", dropped)
	}
}
