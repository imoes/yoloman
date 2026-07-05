package modules

import (
	"fmt"
	"os"
	"os/user"
	"strconv"
	"syscall"
)

// resolveOwner resolves a username to a uid, accepting a plain uid string too.
func resolveOwner(name string) (int, error) {
	if u, err := user.Lookup(name); err == nil {
		return strconv.Atoi(u.Uid)
	}
	return strconv.Atoi(name)
}

// resolveGroup resolves a group name to a gid, accepting a plain gid string too.
func resolveGroup(name string) (int, error) {
	if g, err := user.LookupGroup(name); err == nil {
		return strconv.Atoi(g.Gid)
	}
	return strconv.Atoi(name)
}

// parseMode parses an octal mode string ("644" or "0644") into an
// os.FileMode permission bitmask.
func parseMode(s string) (os.FileMode, error) {
	v, err := strconv.ParseUint(s, 8, 32)
	if err != nil {
		return 0, fmt.Errorf("mode: invalid octal value %q: %w", s, err)
	}
	return os.FileMode(v) & os.ModePerm, nil
}

// currentOwnerGroup returns the uid/gid currently owning path.
func currentOwnerGroup(path string) (uid, gid int, err error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return 0, 0, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, fmt.Errorf("owner/group information unavailable for %q", path)
	}
	return int(st.Uid), int(st.Gid), nil
}

// applyOwnerGroupMode ensures path's owner/group/mode match the (optional)
// desired values, applying only the attributes that differ. It reports
// whether anything changed or would change; when dryRun is true, no
// filesystem mutation happens.
func applyOwnerGroupMode(path, owner, group, mode string, dryRun bool) (changed bool, err error) {
	if owner != "" || group != "" {
		curUID, curGID, err := currentOwnerGroup(path)
		if err != nil {
			return false, err
		}
		wantUID, wantGID := curUID, curGID
		if owner != "" {
			wantUID, err = resolveOwner(owner)
			if err != nil {
				return false, fmt.Errorf("owner: %w", err)
			}
		}
		if group != "" {
			wantGID, err = resolveGroup(group)
			if err != nil {
				return false, fmt.Errorf("group: %w", err)
			}
		}
		if wantUID != curUID || wantGID != curGID {
			changed = true
			if !dryRun {
				if err := os.Chown(path, wantUID, wantGID); err != nil {
					return changed, fmt.Errorf("chown: %w", err)
				}
			}
		}
	}

	if mode != "" {
		wantMode, err := parseMode(mode)
		if err != nil {
			return changed, err
		}
		fi, err := os.Lstat(path)
		if err != nil {
			return changed, err
		}
		if fi.Mode().Perm() != wantMode {
			changed = true
			if !dryRun {
				if err := os.Chmod(path, wantMode); err != nil {
					return changed, fmt.Errorf("chmod: %w", err)
				}
			}
		}
	}

	return changed, nil
}

// applyOwnerGroupOnLink is applyOwnerGroupMode's counterpart for a symlink
// itself (state=link in file.go): it reads and writes the link's own
// uid/gid via lchown, never following it into the target. Mode is
// intentionally not supported here — symlink permission bits are ignored
// by Linux for nearly every operation that matters, unlike a real file.
func applyOwnerGroupOnLink(path, owner, group string, dryRun bool) (changed bool, err error) {
	curUID, curGID, err := currentOwnerGroup(path)
	if err != nil {
		return false, err
	}
	wantUID, wantGID := curUID, curGID
	if owner != "" {
		wantUID, err = resolveOwner(owner)
		if err != nil {
			return false, fmt.Errorf("owner: %w", err)
		}
	}
	if group != "" {
		wantGID, err = resolveGroup(group)
		if err != nil {
			return false, fmt.Errorf("group: %w", err)
		}
	}
	if wantUID != curUID || wantGID != curGID {
		changed = true
		if !dryRun {
			if err := os.Lchown(path, wantUID, wantGID); err != nil {
				return changed, fmt.Errorf("lchown: %w", err)
			}
		}
	}
	return changed, nil
}
