package authz

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

const aclSchemaSQL = `
CREATE TABLE IF NOT EXISTS tool_state (
	name TEXT PRIMARY KEY,
	enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS acl_rules (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	principal_kind TEXT NOT NULL,
	principal_name TEXT NOT NULL,
	tools TEXT NOT NULL DEFAULT '*',
	allow_write INTEGER NOT NULL DEFAULT 0
);
`

// PrincipalKind identifies what an acl_rules row's principal_name refers to.
type PrincipalKind string

const (
	PrincipalUser  PrincipalKind = "user"
	PrincipalGroup PrincipalKind = "group"
	PrincipalToken PrincipalKind = "token"
)

// Rule is one ACL rule: grants principal access to a set of tools (or "*"
// for all), with or without write permission.
type Rule struct {
	ID            int64         `json:"id"`
	PrincipalKind PrincipalKind `json:"principal_kind"`
	PrincipalName string        `json:"principal_name"`
	Tools         []string      `json:"tools,omitempty"` // nil/empty is treated as "*" (all tools)
	AllowWrite    bool          `json:"allow_write"`
}

// Decision is the result of an authorization check.
type Decision struct {
	Allowed bool
	Reason  string
}

// ACL is the SQLite-backed store for tool enable/disable state and
// per-principal access rules, plus the Authorize entrypoint enforcing both
// alongside the global write gate.
type ACL struct {
	db *sql.DB
}

// OpenACL opens (creating if necessary) the ACL store at path.
func OpenACL(path string) (*ACL, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, fmt.Errorf("creating ACL store directory for %q: %w", path, err)
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("opening ACL store %q: %w", path, err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(aclSchemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("creating ACL schema in %q: %w", path, err)
	}
	return &ACL{db: db}, nil
}

func (a *ACL) Close() error { return a.db.Close() }

// SetToolEnabled sets whether name is enabled — the global per-tool kill
// switch, independent of ACL rules and the write gate.
func (a *ACL) SetToolEnabled(ctx context.Context, name string, enabled bool) error {
	_, err := a.db.ExecContext(ctx, `
		INSERT INTO tool_state (name, enabled) VALUES (?, ?)
		ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled
	`, name, boolToInt(enabled))
	return err
}

// IsToolEnabled reports whether name is enabled. A tool with no explicit
// row is enabled by default (the kill switch is opt-out, not opt-in).
func (a *ACL) IsToolEnabled(ctx context.Context, name string) (bool, error) {
	var enabled int
	err := a.db.QueryRowContext(ctx, `SELECT enabled FROM tool_state WHERE name = ?`, name).Scan(&enabled)
	if err == sql.ErrNoRows {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return enabled != 0, nil
}

// ListToolStates returns every tool with an explicit enable/disable row
// (tools never toggled are enabled by default and not listed here).
func (a *ACL) ListToolStates(ctx context.Context) (map[string]bool, error) {
	rows, err := a.db.QueryContext(ctx, `SELECT name, enabled FROM tool_state`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string]bool{}
	for rows.Next() {
		var name string
		var enabled int
		if err := rows.Scan(&name, &enabled); err != nil {
			return nil, err
		}
		out[name] = enabled != 0
	}
	return out, rows.Err()
}

// AddRule inserts rule and returns its assigned ID.
func (a *ACL) AddRule(ctx context.Context, rule Rule) (int64, error) {
	toolsStr := "*"
	if len(rule.Tools) > 0 {
		toolsStr = strings.Join(rule.Tools, ",")
	}
	res, err := a.db.ExecContext(ctx, `
		INSERT INTO acl_rules (principal_kind, principal_name, tools, allow_write) VALUES (?, ?, ?, ?)
	`, string(rule.PrincipalKind), rule.PrincipalName, toolsStr, boolToInt(rule.AllowWrite))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// DeleteRule removes the rule with the given ID.
func (a *ACL) DeleteRule(ctx context.Context, id int64) error {
	_, err := a.db.ExecContext(ctx, `DELETE FROM acl_rules WHERE id = ?`, id)
	return err
}

// ListRules returns every configured ACL rule.
func (a *ACL) ListRules(ctx context.Context) ([]Rule, error) {
	rows, err := a.db.QueryContext(ctx, `SELECT id, principal_kind, principal_name, tools, allow_write FROM acl_rules`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var rules []Rule
	for rows.Next() {
		var r Rule
		var kind, toolsStr string
		var allowWrite int
		if err := rows.Scan(&r.ID, &kind, &r.PrincipalName, &toolsStr, &allowWrite); err != nil {
			return nil, err
		}
		r.PrincipalKind = PrincipalKind(kind)
		r.AllowWrite = allowWrite != 0
		if toolsStr != "*" {
			r.Tools = strings.Split(toolsStr, ",")
		}
		rules = append(rules, r)
	}
	return rules, rows.Err()
}

// Authorize decides whether identity may call tool (which writes if
// writes is true), checking, in order: (1) the tool's enable/disable
// state, (2) ACL rules.
//
// ACL rule semantics: if no rules are configured at all, every enabled
// tool is allowed (matching v1's earlier tool-gated-only behavior — ACL is
// an opt-in layer, not a mandatory one for fresh installs). Once at least
// one rule exists, access becomes default-deny: identity must match a rule
// covering tool, and if writes is true, at least one matching rule must
// have AllowWrite.
func (a *ACL) Authorize(ctx context.Context, identity Identity, tool string, writes bool) (Decision, error) {
	enabled, err := a.IsToolEnabled(ctx, tool)
	if err != nil {
		return Decision{}, fmt.Errorf("checking tool state: %w", err)
	}
	if !enabled {
		return Decision{Allowed: false, Reason: fmt.Sprintf("tool %q is disabled", tool)}, nil
	}

	rules, err := a.ListRules(ctx)
	if err != nil {
		return Decision{}, fmt.Errorf("loading ACL rules: %w", err)
	}
	if len(rules) == 0 {
		return Decision{Allowed: true}, nil
	}

	matched := false
	allowWrite := false
	for _, r := range rules {
		if !ruleMatchesIdentity(r, identity) || !ruleMatchesTool(r, tool) {
			continue
		}
		matched = true
		if r.AllowWrite {
			allowWrite = true
		}
	}
	if !matched {
		return Decision{Allowed: false, Reason: fmt.Sprintf("no ACL rule grants %s access to %q", identity.Kind, tool)}, nil
	}
	if writes && !allowWrite {
		return Decision{Allowed: false, Reason: fmt.Sprintf("no ACL rule grants %s write access to %q", identity.Kind, tool)}, nil
	}
	return Decision{Allowed: true}, nil
}

func ruleMatchesIdentity(r Rule, identity Identity) bool {
	switch r.PrincipalKind {
	case PrincipalToken:
		return identity.Kind == KindToken && r.PrincipalName == identity.Name
	case PrincipalUser:
		return identity.Kind == KindUser && r.PrincipalName == identity.Name
	case PrincipalGroup:
		if identity.Kind != KindUser {
			return false
		}
		for _, g := range identity.Groups {
			if g == r.PrincipalName {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func ruleMatchesTool(r Rule, tool string) bool {
	if len(r.Tools) == 0 {
		return true // "*"
	}
	for _, t := range r.Tools {
		if t == tool {
			return true
		}
	}
	return false
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
