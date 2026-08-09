package modules

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// BlockInFile inserts, updates, or removes a multi-line block of text
// surrounded by marker comments in a file, mirroring
// ansible.builtin.blockinfile. It is idempotent: it only rewrites the file
// when the block's content actually needs to change.
type BlockInFile struct{}

// NewBlockInFile returns a BlockInFile module.
func NewBlockInFile() *BlockInFile { return &BlockInFile{} }

func (b *BlockInFile) Name() string { return "blockinfile" }

func (b *BlockInFile) Description() string {
	return "" +
		"Insert, update, or remove a multi-line block of text surrounded by marker comments in " +
		"a file, without touching the rest of the file's content — the block is identified by " +
		"its markers, so re-running with different content replaces the old block in place " +
		"rather than appending a duplicate. If the markers aren't found yet, the block (with " +
		"markers) is appended at the end of the file. Idempotent — a repeat call with the same " +
		"content reports changed=false. Supports check_mode via dry_run=true.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.blockinfile. Same path/block/state/marker/create semantics " +
		"(a focused subset — Ansible also supports insertafter/insertbefore/backup, not yet " +
		"implemented here; a missing block is always appended at end of file).\n" +
		"- Chef: no single built-in resource; typically hand-rolled with Ruby string " +
		"manipulation in a custom resource.\n" +
		"- Puppet: no core equivalent; third-party modules (e.g. augeasproviders) or " +
		"puppetlabs-stdlib's `file_line` used repeatedly approximate it.\n" +
		"- Salt: the `file.blockreplace` state — nearly identical marker-comment-block model.\n" +
		"- Terraform: not applicable — no line/block-level file-editing primitive."
}

func (b *BlockInFile) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path":    stringProp(`File to edit, e.g. "/etc/ssh/sshd_config".`),
		"block":   stringProp("The desired block content, without markers. Required for state=present."),
		"state":   stringEnumProp(`Whether the block should be present or absent. Default "present".`, "present", "absent"),
		"marker":  stringProp(`Marker line template; the literal "{mark}" is replaced with BEGIN/END. Default "# {mark} ANSIBLE MANAGED BLOCK".`),
		"create":  boolProp("For state=present: if the file does not exist, create it instead of failing. Default false.", false),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "path")
}

func (b *BlockInFile) Writes() bool { return true }

func (b *BlockInFile) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	path, err := stringParam(params, "path", true, "")
	if err != nil {
		return Result{}, err
	}
	block, err := stringParam(params, "block", false, "")
	if err != nil {
		return Result{}, err
	}
	state, err := stringParam(params, "state", false, "present")
	if err != nil {
		return Result{}, err
	}
	marker, err := stringParam(params, "marker", false, "# {mark} ANSIBLE MANAGED BLOCK")
	if err != nil {
		return Result{}, err
	}
	create, err := boolParam(params, "create", false)
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	if state != "present" && state != "absent" {
		return Result{}, fmt.Errorf("state: unsupported value %q (want present|absent)", state)
	}
	if state == "present" && block == "" {
		return Result{}, fmt.Errorf("block: required when state=present")
	}
	if !strings.Contains(marker, "{mark}") {
		return Result{}, fmt.Errorf(`marker: must contain the literal "{mark}" placeholder`)
	}

	beginMarker := strings.ReplaceAll(marker, "{mark}", "BEGIN")
	endMarker := strings.ReplaceAll(marker, "{mark}", "END")

	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if state == "absent" {
				return Result{Changed: false, Msg: "file does not exist, nothing to remove", Data: map[string]any{"path": path}}, nil
			}
			if !create {
				return Result{}, fmt.Errorf("blockinfile: %q does not exist and create=false", path)
			}
			raw = nil
		} else {
			return Result{}, err
		}
	}

	newContent, changed := applyBlock(string(raw), beginMarker, endMarker, block, state)
	if !changed {
		return Result{Changed: false, Msg: "no change needed", Data: map[string]any{"path": path}}, nil
	}

	if !dryRun {
		if err := os.WriteFile(path, []byte(newContent), 0o644); err != nil {
			return Result{}, fmt.Errorf("blockinfile: writing %q: %w", path, err)
		}
	}

	return Result{Changed: true, Msg: "block " + state, Data: map[string]any{"path": path}}, nil
}

// applyBlock computes the new file content and whether it differs from
// original, for either state=present (replace an existing marked block in
// place, or append a new one at EOF if no markers are found) or
// state=absent (remove the marked block including its markers, if found).
func applyBlock(original, beginMarker, endMarker, block, state string) (string, bool) {
	lines := strings.Split(original, "\n")
	beginIdx, endIdx := -1, -1
	for i, l := range lines {
		if beginIdx == -1 && l == beginMarker {
			beginIdx = i
			continue
		}
		if beginIdx != -1 && l == endMarker {
			endIdx = i
			break
		}
	}
	found := beginIdx != -1 && endIdx != -1

	if state == "absent" {
		if !found {
			return original, false
		}
		out := append(append([]string{}, lines[:beginIdx]...), lines[endIdx+1:]...)
		return strings.Join(out, "\n"), true
	}

	blockLines := append([]string{beginMarker}, append(strings.Split(block, "\n"), endMarker)...)

	if found {
		current := strings.Join(lines[beginIdx:endIdx+1], "\n")
		desired := strings.Join(blockLines, "\n")
		if current == desired {
			return original, false
		}
		out := append(append([]string{}, lines[:beginIdx]...), append(blockLines, lines[endIdx+1:]...)...)
		return strings.Join(out, "\n"), true
	}

	prefix := original
	if prefix != "" && !strings.HasSuffix(prefix, "\n") {
		prefix += "\n"
	}
	return prefix + strings.Join(blockLines, "\n") + "\n", true
}
