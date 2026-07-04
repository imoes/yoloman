package modules

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
)

// GetURL downloads a file from HTTP(S) to a destination path, mirroring
// ansible.builtin.get_url. It is idempotent in the same conservative way
// as real Ansible: if dest already exists and neither force nor checksum
// is given, it is left alone entirely (no re-download, no comparison) —
// only force=true or a checksum mismatch triggers a re-download.
type GetURL struct {
	HTTPGet HTTPGetFunc
}

// NewGetURL returns a GetURL module backed by a real HTTP client.
func NewGetURL() *GetURL { return &GetURL{HTTPGet: defaultHTTPGet} }

func (g *GetURL) Name() string { return "get_url" }

func (g *GetURL) Description() string {
	return "" +
		"Download a file from an HTTP(S) URL to a destination path. Conservative idempotency, " +
		"matching real Ansible: if `dest` already exists, it is left alone entirely unless " +
		"`force=true` or a `checksum` is given that doesn't match the existing file's hash — " +
		"there is no download at all just to \"check\", to avoid needless network traffic for a " +
		"file that's presumably already correct. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.get_url. Same url/dest/checksum/force/owner/group/mode " +
		"semantics (a focused subset — Ansible also supports headers/url_username/timeout and " +
		"more, not yet implemented here).\n" +
		"- Chef: the `remote_file` resource.\n" +
		"- Puppet: the `archive` module (voxpupuli-archive) or an `exec` wrapping curl/wget.\n" +
		"- Salt: the `file.managed` state's `source` parameter with an `http://`/`https://` URL.\n" +
		"- Terraform: not applicable at apply time for a running host; closest analogue is a " +
		"provisioner shelling out to curl/wget."
}

func (g *GetURL) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"url":      stringProp("Source URL to download from."),
		"dest":     stringProp(`Destination path to write to, e.g. "/opt/app/release.tar.gz".`),
		"checksum": stringProp(`Optional expected checksum as "sha256:<hex>". If dest exists and matches, no download occurs.`),
		"force":    boolProp("When true, always (re-)download and overwrite dest even if it already exists. Default false.", false),
		"owner":    stringProp("Optional desired owner (username or numeric uid)."),
		"group":    stringProp("Optional desired group (group name or numeric gid)."),
		"mode":     stringProp(`Optional desired permission mode as an octal string, e.g. "0644".`),
		"dry_run":  boolProp("When true, report what would change without downloading (check_mode).", false),
	}, "url", "dest")
}

func (g *GetURL) Writes() bool { return true }

func (g *GetURL) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	url, err := stringParam(params, "url", true, "")
	if err != nil {
		return Result{}, err
	}
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	checksum, err := stringParam(params, "checksum", false, "")
	if err != nil {
		return Result{}, err
	}
	force, err := boolParam(params, "force", false)
	if err != nil {
		return Result{}, err
	}
	owner, err := stringParam(params, "owner", false, "")
	if err != nil {
		return Result{}, err
	}
	group, err := stringParam(params, "group", false, "")
	if err != nil {
		return Result{}, err
	}
	mode, err := stringParam(params, "mode", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	var wantHex string
	if checksum != "" {
		parts := strings.SplitN(checksum, ":", 2)
		if len(parts) != 2 || parts[0] != "sha256" {
			return Result{}, fmt.Errorf(`checksum: must be in the form "sha256:<hex>"`)
		}
		wantHex = strings.ToLower(parts[1])
	}

	_, statErr := os.Stat(dest)
	exists := statErr == nil

	needDownload := !exists || force
	if exists && !force && checksum != "" {
		actual, err := sha256File(dest)
		if err != nil {
			return Result{}, fmt.Errorf("get_url: hashing existing %q: %w", dest, err)
		}
		if actual != wantHex {
			needDownload = true
		}
	}

	if !needDownload {
		changed, err := g.applyAttrsIfExists(dest, owner, group, mode, dryRun)
		if err != nil {
			return Result{}, err
		}
		msg := "already up to date"
		if changed {
			msg = "attributes updated"
		}
		return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest}}, nil
	}

	if !dryRun {
		body, err := g.HTTPGet(url)
		if err != nil {
			return Result{}, fmt.Errorf("get_url: downloading %q: %w", url, err)
		}
		if checksum != "" {
			sum := sha256.Sum256(body)
			got := hex.EncodeToString(sum[:])
			if got != wantHex {
				return Result{}, fmt.Errorf("get_url: checksum mismatch for %q: got sha256:%s, want sha256:%s", url, got, wantHex)
			}
		}
		if err := os.WriteFile(dest, body, 0o644); err != nil {
			return Result{}, fmt.Errorf("get_url: writing %q: %w", dest, err)
		}
		if _, err := g.applyAttrsIfExists(dest, owner, group, mode, false); err != nil {
			return Result{}, err
		}
	}

	return Result{Changed: true, Msg: "downloaded", Data: map[string]any{"dest": dest, "url": url}}, nil
}

func (g *GetURL) applyAttrsIfExists(dest, owner, group, mode string, dryRun bool) (bool, error) {
	if owner == "" && group == "" && mode == "" {
		return false, nil
	}
	if _, err := os.Lstat(dest); err != nil {
		return false, nil
	}
	return applyOwnerGroupMode(dest, owner, group, mode, dryRun)
}

// sha256File returns the lowercase hex SHA-256 of path's contents.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
