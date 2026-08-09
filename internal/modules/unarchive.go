package modules

import (
	"archive/tar"
	"archive/zip"
	"compress/bzip2"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Unarchive extracts a zip or tar (optionally gzip/bzip2-compressed)
// archive already present on this host to a destination directory,
// mirroring ansible.builtin.unarchive. Implemented with Go's standard
// library archive packages — no external tar/unzip binary needed, matching
// this project's general preference for native Go over shelling out where
// reasonable.
//
// Idempotency here is deliberately simple, the same way real Ansible users
// actually drive this module in practice: if `creates` is given and that
// path already exists, extraction is skipped entirely (changed=false).
// Without `creates`, there is no cheap way to know in advance whether an
// archive's contents already match dest without extracting it, so every
// call without `creates` extracts (changed=true) — real Ansible has the
// same practical limitation without a working `creates` check.
type Unarchive struct{}

// NewUnarchive returns an Unarchive module.
func NewUnarchive() *Unarchive { return &Unarchive{} }

func (u *Unarchive) Name() string { return "unarchive" }

func (u *Unarchive) Description() string {
	return "" +
		"Extract a zip or tar archive (optionally .tar.gz/.tgz or .tar.bz2) already present on " +
		"this host to a destination directory. Archive type is detected from the `src` file's " +
		"extension. Idempotency relies on `creates`: if given and that path already exists, " +
		"extraction is skipped entirely; without it, every call extracts (there is no cheap way " +
		"to know in advance whether an archive's contents already match dest without extracting " +
		"it — the same practical limitation real Ansible has without a working `creates` " +
		"check). Supports check_mode via dry_run=true. There is no separate control-node " +
		"filesystem in this agent's model, so `src` is always a path on this same host " +
		"(equivalent to Ansible's remote_src=true).\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.unarchive. Same src/dest/creates semantics (a focused " +
		"subset — Ansible also supports owner/group/mode/exclude/include, not implemented " +
		"here).\n" +
		"- Chef: the `archive_file` resource.\n" +
		"- Puppet: the voxpupuli-archive module's `archive` type.\n" +
		"- Salt: the `archive.extracted` state.\n" +
		"- Terraform: the `archive_file` data source works in the opposite direction " +
		"(creating an archive, not extracting one) — not applicable here."
}

func (u *Unarchive) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"src":     stringProp(`Archive file already on this host, e.g. "/tmp/release.tar.gz".`),
		"dest":    stringProp(`Destination directory to extract into, e.g. "/opt/app".`),
		"creates": stringProp("Optional path; if it already exists, extraction is skipped (the idempotency mechanism)."),
		"dry_run": boolProp("When true, report what would happen without extracting (check_mode).", false),
	}, "src", "dest")
}

func (u *Unarchive) Writes() bool { return true }

func (u *Unarchive) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	src, err := stringParam(params, "src", true, "")
	if err != nil {
		return Result{}, err
	}
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	creates, err := stringParam(params, "creates", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if creates != "" {
		if _, err := os.Stat(creates); err == nil {
			return Result{Changed: false, Msg: "creates path already exists", Data: map[string]any{"dest": dest}}, nil
		}
	}

	if dryRun {
		return Result{Changed: true, Msg: "would extract (dry run)", Data: map[string]any{"dest": dest}}, nil
	}

	if err := os.MkdirAll(dest, 0o755); err != nil {
		return Result{}, fmt.Errorf("unarchive: creating dest %q: %w", dest, err)
	}

	if err := extractArchive(src, dest); err != nil {
		return Result{}, fmt.Errorf("unarchive: extracting %q: %w", src, err)
	}

	return Result{Changed: true, Msg: "extracted", Data: map[string]any{"dest": dest}}, nil
}

// extractArchive dispatches to the right extractor based on src's
// extension.
func extractArchive(src, dest string) error {
	switch {
	case strings.HasSuffix(src, ".zip"):
		return extractZip(src, dest)
	case strings.HasSuffix(src, ".tar.gz"), strings.HasSuffix(src, ".tgz"):
		return extractTar(src, dest, "gzip")
	case strings.HasSuffix(src, ".tar.bz2"):
		return extractTar(src, dest, "bzip2")
	case strings.HasSuffix(src, ".tar"):
		return extractTar(src, dest, "")
	default:
		return fmt.Errorf("unrecognized archive extension for %q (want .zip, .tar, .tar.gz/.tgz, or .tar.bz2)", src)
	}
}

func extractZip(src, dest string) error {
	r, err := zip.OpenReader(src)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		target, err := safeJoin(dest, f.Name)
		if err != nil {
			return err
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		if err := writeExtractedFile(target, rc, f.Mode()); err != nil {
			rc.Close()
			return err
		}
		rc.Close()
	}
	return nil
}

func extractTar(src, dest, compression string) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()

	var r io.Reader = f
	switch compression {
	case "gzip":
		gz, err := gzip.NewReader(f)
		if err != nil {
			return err
		}
		defer gz.Close()
		r = gz
	case "bzip2":
		r = bzip2.NewReader(f)
	}

	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		target, err := safeJoin(dest, hdr.Name)
		if err != nil {
			return err
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := writeExtractedFile(target, tr, os.FileMode(hdr.Mode)); err != nil {
				return err
			}
		}
	}
	return nil
}

// safeJoin joins dest with an archive-member name, rejecting any result
// that would escape dest via ".." path traversal — a hostile or malformed
// archive must not be able to write outside the requested destination.
func safeJoin(dest, name string) (string, error) {
	target := filepath.Join(dest, name)
	if target != dest && !strings.HasPrefix(target, dest+string(os.PathSeparator)) {
		return "", fmt.Errorf("archive member %q escapes destination directory", name)
	}
	return target, nil
}

func writeExtractedFile(target string, r io.Reader, mode os.FileMode) error {
	if mode == 0 {
		mode = 0o644
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, r)
	return err
}
