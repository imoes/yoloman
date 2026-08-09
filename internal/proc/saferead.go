package proc

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// DefaultMaxReadBytes caps how much of a /proc file SafeRead will return,
// guarding against pathological files (e.g. /proc/kcore) or attacker-supplied
// paths pointing at huge or infinite streams.
const DefaultMaxReadBytes = 4 << 20 // 4 MiB

// SafeRead reads relPath under root (intended to be "/proc") and returns its
// contents, capped at maxBytes. It rejects paths that escape root either
// lexically (e.g. "../../etc/passwd") or via a symlink that resolves outside
// root (e.g. /proc/<pid>/exe, /proc/<pid>/cwd, /proc/<pid>/root, which point
// at real filesystem locations by design and are deliberately not readable
// through this generic path).
func SafeRead(root, relPath string, maxBytes int64) ([]byte, error) {
	if maxBytes <= 0 {
		maxBytes = DefaultMaxReadBytes
	}

	cleanRel := filepath.Clean("/" + relPath) // leading "/" neutralizes any ".." prefix
	joined := filepath.Join(root, cleanRel)

	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("resolving root %q: %w", root, err)
	}
	realPath, err := filepath.EvalSymlinks(joined)
	if err != nil {
		return nil, fmt.Errorf("resolving path %q: %w", relPath, err)
	}
	if realPath != realRoot && !strings.HasPrefix(realPath, realRoot+string(filepath.Separator)) {
		return nil, fmt.Errorf("path %q escapes %q", relPath, root)
	}

	f, err := os.Open(realPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	data, err := io.ReadAll(io.LimitReader(f, maxBytes))
	if err != nil {
		return nil, err
	}
	return data, nil
}
