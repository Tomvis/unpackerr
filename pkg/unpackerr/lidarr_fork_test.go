package unpackerr

import (
	"testing"

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
