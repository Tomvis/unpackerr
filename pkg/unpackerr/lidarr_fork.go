package unpackerr

import (
	"strings"

	"golift.io/starr/lidarr"
)

// dropTracklessOutputs removes files Lidarr matched to no track (e.g. a bonus track in a disc folder
// identified as another album). Lidarr throws importing them, so they never import (MUSIC-101).
// Returns the kept outputs and the dropped file names.
func dropTracklessOutputs(outputs []*lidarr.ManualImportOutput) ([]*lidarr.ManualImportOutput, []string) {
	kept := make([]*lidarr.ManualImportOutput, 0, len(outputs))

	var dropped []string

	for _, out := range outputs {
		if out == nil {
			continue
		}

		hasTrack := false

		for _, t := range out.Tracks {
			if t != nil {
				hasTrack = true
				break
			}
		}

		if hasTrack {
			kept = append(kept, out)
		} else {
			dropped = append(dropped, crossPlatformBase(out.Path))
		}
	}

	return kept, dropped
}

// heldEditionRejection returns the first rejection marking a download as held for the edition judge
// (the Tomvis Lidarr fork's HeldEditionSpecification), or "". ManualImport skips import specs, so a
// split import that sent such a download would import it without the judge (MUSIC-103).
func heldEditionRejection(outputs []*lidarr.ManualImportOutput) string {
	for _, out := range outputs {
		if out == nil {
			continue
		}

		for _, r := range out.Rejections {
			if r != nil && strings.Contains(r.Reason, "awaiting edition judge") {
				return r.Reason
			}
		}
	}

	return ""
}
