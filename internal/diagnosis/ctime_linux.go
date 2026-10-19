//go:build linux

package diagnosis

import (
	"os"
	"syscall"
	"time"
)

// changedAt is the inode change time: when the file was last written, replaced or re-permissioned ON THIS HOST. The
// modification time is not that — dpkg and rpm keep the mtime from the package archive, so an upgraded program
// shows its build date (measured 2026-10-17: /usr/bin/ls mtime 2026-08-25 = the build, ctime 2026-09-01 06:39:53 =
// the second dpkg.log records "upgrade coreutils").
func changedAt(fi os.FileInfo) time.Time {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return time.Unix(st.Ctim.Sec, st.Ctim.Nsec).UTC()
	}
	return fi.ModTime().UTC()
}
