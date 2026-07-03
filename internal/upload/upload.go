// Package upload implements file-staging: writing a caller-supplied file
// into a fixed staging directory, never an arbitrary destination path (see
// docs/plan.md's "File upload (staging)"). Placing a staged file at its
// final destination — with the right owner/group/mode — is the copy
// module's job, not this package's; this package only handles the
// transport/staging half.
package upload

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ValidateFilename rejects anything that isn't a plain filename: empty,
// containing a path separator, or a "." / ".." component. This is what
// keeps WriteStaged from ever writing outside dir.
func ValidateFilename(name string) error {
	if name == "" {
		return fmt.Errorf("filename must not be empty")
	}
	if strings.ContainsAny(name, "/\\") {
		return fmt.Errorf("filename must not contain path separators")
	}
	if name == "." || name == ".." {
		return fmt.Errorf("invalid filename %q", name)
	}
	return nil
}

// WriteStaged reads at most maxSize+1 bytes from r into a temp file inside
// dir, then atomically renames it to dir/name once fully written — so an
// interrupted transfer never leaves a half-written file at the final path.
// Re-uploading the same name overwrites the previous staged file (staging
// is a transient holding area, not a versioned store). Returns the number
// of bytes written, or an error if that exceeds maxSize.
func WriteStaged(dir, name string, r io.Reader, maxSize int64) (int64, error) {
	if err := ValidateFilename(name); err != nil {
		return 0, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, fmt.Errorf("creating staging directory %q: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return 0, fmt.Errorf("creating temp file in %q: %w", dir, err)
	}
	tmpPath := tmp.Name()
	defer func() {
		tmp.Close()
		os.Remove(tmpPath) // no-op once successfully renamed away
	}()

	n, err := io.CopyN(tmp, r, maxSize+1)
	if err != nil && err != io.EOF {
		return 0, fmt.Errorf("writing upload: %w", err)
	}
	if n > maxSize {
		return 0, fmt.Errorf("upload exceeds max_upload_size (%d bytes)", maxSize)
	}
	if err := tmp.Close(); err != nil {
		return 0, fmt.Errorf("closing temp file: %w", err)
	}

	dest := filepath.Join(dir, name)
	if err := os.Rename(tmpPath, dest); err != nil {
		return 0, fmt.Errorf("finalizing upload to %q: %w", dest, err)
	}
	return n, nil
}
