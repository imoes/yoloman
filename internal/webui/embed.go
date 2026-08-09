// Package webui serves the embedded admin single-page app: PAM/token login,
// tool enable/disable switches, an ACL rule editor, and a facts/metrics
// viewer — all talking to the same REST API used by other clients, so the
// UI has no privileged access the API itself doesn't already expose.
package webui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed assets
var assetsFS embed.FS

// Handler serves the admin UI at the given mount prefix (e.g. "/ui"),
// self-contained (no external CDN/network dependencies).
func Handler(prefix string) (http.Handler, error) {
	sub, err := fs.Sub(assetsFS, "assets")
	if err != nil {
		return nil, err
	}
	fileServer := http.FileServerFS(sub)
	return http.StripPrefix(prefix, fileServer), nil
}
