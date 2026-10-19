//go:build !linux

package diagnosis

import (
	"os"
	"time"
)

// changedAt falls back to the modification time where the inode change time is not exposed.
func changedAt(fi os.FileInfo) time.Time { return fi.ModTime().UTC() }
