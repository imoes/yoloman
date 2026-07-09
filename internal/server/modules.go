package server

import (
	"context"
	"fmt"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/audit"
	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// NewDefaultModuleRegistry returns a registry populated with all of v1's
// modules: the read/facts set (setup, stat, find, slurp, service_facts,
// package_facts, getent, fetch, wait_for, ping), always active, plus the
// write set (file, copy, lineinfile, systemd, systemd_service, service,
// apt, command, script, blockinfile, replace, assemble, tempfile, template,
// user, group, cron, hostname, timezone, apt_key, apt_repository,
// deb822_repository, dpkg_selections, yum, dnf, dnf5, yum_repository,
// rpm_key, get_url, uri, known_hosts, iptables, package, git, unarchive,
// pip, debconf, sysvinit, subversion, expect, reboot, raw, shell — batch-
// implemented against ansible.builtin per docs/plan.md's module coverage
// plan, which this list now completes. shell is this registry's one
// deliberate exception to "no shell interpreter" (see its own doc
// comment) — confirmed explicitly with the project owner), only ever
// exposed as tools when the write gate (config.Write) is open — see
// RegisterModules.
func NewDefaultModuleRegistry() *modules.Registry {
	reg := modules.NewRegistry()
	for _, m := range []modules.Module{
		modules.NewSetup(),
		modules.NewStat(),
		modules.NewFind(),
		modules.NewSlurp(),
		modules.NewServiceFacts(),
		modules.NewPackageFacts(),
		modules.NewGetent(),
		modules.NewJournal(),
		modules.NewStorageFacts(),
		modules.NewVirtFacts(),
		modules.NewQM(),
		modules.NewVirsh(),
		modules.NewFile(),
		modules.NewCopy(),
		modules.NewLineInFile(),
		modules.NewSystemd(),
		modules.NewService(),
		modules.NewApt(),
		modules.NewCommand(),
		modules.NewBlockInFile(),
		modules.NewReplace(),
		modules.NewAssemble(),
		modules.NewTempfile(),
		modules.NewTemplate(),
		modules.NewUser(),
		modules.NewGroup(),
		modules.NewCron(),
		modules.NewHostname(),
		modules.NewTimezone(),
		modules.NewAptKey(),
		modules.NewAptRepository(),
		modules.NewDeb822Repository(),
		modules.NewDpkgSelections(),
		modules.NewYum(),
		modules.NewDnf(),
		modules.NewDnf5(),
		modules.NewYumRepository(),
		modules.NewRpmKey(),
		modules.NewFetch(),
		modules.NewWaitFor(),
		modules.NewGetURL(),
		modules.NewURI(),
		modules.NewKnownHosts(),
		modules.NewIptables(),
		modules.NewPing(),
		modules.NewSystemdService(),
		modules.NewPackage(),
		modules.NewScript(),
		modules.NewGit(),
		modules.NewUnarchive(),
		modules.NewPip(),
		modules.NewDebconf(),
		modules.NewSysvinit(),
		modules.NewSubversion(),
		modules.NewExpect(),
		modules.NewReboot(),
		modules.NewRaw(),
		modules.NewShell(),
	} {
		if err := reg.Register(m); err != nil {
			// Registration only fails on a duplicate name among modules
			// defined in this same file, i.e. a programming error.
			panic(fmt.Sprintf("registering built-in module: %v", err))
		}
	}
	return reg
}

// RegisterModules exposes every module in reg as an MCP tool. Read-only
// modules (Writes() == false) are always registered; writing modules are
// only registered when write is true — the write gate. acl may be nil (no
// ACL enforcement beyond the write gate); when set, every call is also
// checked against acl.Authorize using the caller's Identity — resolved from
// the request context via authz.IdentityFromContext, attached there by the
// bearer-auth middleware (see cmd/agentic-mcpd/http.go's withBearerAuth),
// falling back to the fixed authz.TokenIdentity if none was attached (e.g.
// auth disabled entirely in dev mode). This is what makes per-token RBAC
// (docs/plan.md) actually apply to MCP calls: a named token's ACL rules are
// only meaningful if MCP dispatch resolves *that* token's identity instead
// of always attributing every caller to the same fixed principal. al may be
// nil (no audit logging).
func RegisterModules(s *mcp.Server, reg *modules.Registry, write bool, acl *authz.ACL, al *audit.Logger) {
	for _, m := range reg.All() {
		if m.Writes() && !write {
			continue
		}
		registerModuleTool(s, m, acl, al)
	}
}

// moduleResultOutputSchema is used instead of the schema auto-inferred from
// modules.Result, whose Data field is `any`. The Go jsonschema-go inferrer
// renders an `any` field as the bare boolean schema `true` ("matches
// anything"), which is valid JSON Schema but not accepted by every client's
// schema validator (observed with the MCP Inspector CLI). An empty object
// schema `{}` means the same thing and is far more broadly compatible —
// important here since the whole point is working with many different
// orchestrators/clients, not just one.
var moduleResultOutputSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"changed": map[string]any{"type": "boolean"},
		"msg":     map[string]any{"type": "string"},
		"data":    map[string]any{},
	},
	"required": []string{"changed"},
}

func registerModuleTool(s *mcp.Server, m modules.Module, acl *authz.ACL, al *audit.Logger) {
	mcp.AddTool(s, &mcp.Tool{
		Name:         m.Name(),
		Description:  m.Description(),
		InputSchema:  m.InputSchema(),
		OutputSchema: moduleResultOutputSchema,
	}, func(ctx context.Context, req *mcp.CallToolRequest, in map[string]any) (*mcp.CallToolResult, modules.Result, error) {
		start := time.Now()
		identity := mcpCallerIdentity(ctx)
		if err := checkACL(ctx, acl, identity, m.Name(), m.Writes()); err != nil {
			al.LogCall(identityLabel(identity), m.Name(), m.Writes(), false, in, start, err)
			return nil, modules.Result{}, err
		}
		res, err := m.Run(ctx, in, false)
		al.LogCall(identityLabel(identity), m.Name(), m.Writes(), res.Changed, in, start, err)
		if err != nil {
			return nil, modules.Result{}, err
		}
		return nil, res, nil
	})
}

// mcpCallerIdentity resolves the caller's Identity attached to ctx by the
// bearer-auth middleware (cmd/agentic-mcpd/http.go's withBearerAuth),
// falling back to the fixed authz.TokenIdentity when none is set (auth
// disabled entirely, or a transport that doesn't go through that
// middleware, e.g. tests using in-memory transports). This is what makes
// per-token RBAC (docs/plan.md) actually apply to MCP calls: a named
// token's ACL rules only matter if dispatch resolves *that* token's
// identity instead of always attributing every caller to one fixed
// principal.
func mcpCallerIdentity(ctx context.Context) authz.Identity {
	if identity := authz.IdentityFromContext(ctx); identity.Kind != "" {
		return identity
	}
	return authz.TokenIdentity
}

// identityLabel formats an authz.Identity as a compact "kind:name" string
// for audit log entries.
func identityLabel(identity authz.Identity) string {
	return fmt.Sprintf("%s:%s", identity.Kind, identity.Name)
}

// checkACL enforces acl (if non-nil) for identity, returning an error
// (surfaced as an MCP tool error) if access is denied.
func checkACL(ctx context.Context, acl *authz.ACL, identity authz.Identity, tool string, writes bool) error {
	if acl == nil {
		return nil
	}
	dec, err := acl.Authorize(ctx, identity, tool, writes)
	if err != nil {
		return fmt.Errorf("checking ACL: %w", err)
	}
	if !dec.Allowed {
		return fmt.Errorf("access denied: %s", dec.Reason)
	}
	return nil
}
