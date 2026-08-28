package modules

// The embedded codec registry is a GENERATED PROJECTION of configs/config_codecs.json
// (bossman/scripts/unify_codec_registry.py). This test is what stops it from becoming a second source
// again.
//
// It had already happened once: the two files disagreed about the codec of 236 files, and the disagreement
// mattered — the write path reads this embedded registry while the UI decides from the bundled canonical
// one, so the same file could be offered as "freeform, render the whole thing" and then merged per key.
// Nothing detected that for as long as both files were writable, because drift produces no error, only two
// answers.
//
// WHAT THIS GUARDS, precisely: every entry the agent carries must still say exactly what the source says.
// That catches a hand-edit here, a stale generated entry, and a codec corrected in the source but never
// regenerated — i.e. every way the two can come to CONTRADICT each other.
//
// WHAT IT DELIBERATELY DOES NOT GUARD: the source gaining an entry that has not been projected yet. The
// agent then simply has no codec for that file and falls back to whole-file editing, which is a missing
// answer rather than a wrong one. Failing the build for that would make every catalog addition a red test,
// and it is not the failure mode that hurt us.
//
// Skipped when the source file is not reachable (a stripped build tree, a container that mounts only the
// package): a test that cannot see its input must not pretend to have checked it.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestEmbeddedRegistryMatchesItsSource(t *testing.T) {
	source := filepath.Join("..", "..", "configs", "config_codecs.json")
	raw, err := os.ReadFile(source)
	if err != nil {
		t.Skipf("source registry not reachable (%v) — nothing to compare against", err)
	}
	var canonical map[string]codecSpec
	if err := json.Unmarshal(raw, &canonical); err != nil {
		t.Fatalf("parse %s: %v", source, err)
	}

	if len(codecRegistry) == 0 {
		t.Fatal("embedded codec registry is empty")
	}
	for path, got := range codecRegistry {
		want, ok := canonical[path]
		if !ok {
			t.Errorf("%s: embedded registry has an entry the source does not — regenerate with "+
				"bossman/scripts/unify_codec_registry.py", path)
			continue
		}
		if got.Codec != want.Codec || got.Separator != want.Separator || got.Comment != want.Comment {
			t.Errorf("%s: embedded says (%q,%q,%q), source says (%q,%q,%q) — the two registries are "+
				"drifting apart again; regenerate, do not hand-edit",
				path, got.Codec, got.Separator, got.Comment, want.Codec, want.Separator, want.Comment)
		}
		if got.Codec == "" || got.Codec == "none" {
			t.Errorf("%s: projected with codec %q, which lookupCodec ignores — it should not be shipped",
				path, got.Codec)
		}
		// CONSTRUCTIBLE, not merely plausible. 24 records claimed `toml` — recorded from the file extension
		// by an earlier repair pass of mine — and the agent has no toml codec at all, so lookupCodec would
		// hand the config module a format newCodec cannot build and the APPLY would fail, on a record that
		// reads perfectly well in the registry. A codec nobody can construct is not a codec.
		// dirvalue is dispatched BEFORE newCodec (config.go:74) — the path is a DIRECTORY with one file per
		// setting, so there is no byte codec to build. It is implemented; it just is not one of these.
		if got.Codec == "dirvalue" {
			continue
		}
		if _, err := newCodec(got.Codec, map[string]any{}); err != nil {
			t.Errorf("%s: codec %q is recorded but not implemented (%v) — the write path would fail at "+
				"apply time; see the enum in config.go:54", path, got.Codec, err)
		}
	}
}
