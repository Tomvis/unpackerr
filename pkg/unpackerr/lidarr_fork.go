package unpackerr

import "golift.io/starr/lidarr"

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
