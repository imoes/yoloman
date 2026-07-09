// Package embedded holds the curated built-in Starlark module set that is
// baked into the agent binary via go:embed (Block J4 / Item 3c). Unlike the
// pushed collection library (delivered at runtime to /var/lib/.../modules.d),
// these ship inside the binary and are always present — the yolo-man-owned
// network module and the storage stack (LVM/VDO/ZFS) the host-management page
// depends on. Modules land here only once they actually run (validated, and
// verified against a real host), so the set grows as each is proven.
package embedded

import (
	"embed"
	"io/fs"
)

//go:embed modules
var modulesFS embed.FS

// FS returns the baked module tree rooted so paths look like
// "community.general/vdo.star" (or "yoloman/network_interface.star"),
// matching the <collection>/<name>.star layout LoadFS/LoadDir expect.
func FS() (fs.FS, error) {
	return fs.Sub(modulesFS, "modules")
}
