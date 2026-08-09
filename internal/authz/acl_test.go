package authz

import (
	"context"
	"path/filepath"
	"testing"
)

func openTestACL(t *testing.T) *ACL {
	t.Helper()
	a, err := OpenACL(filepath.Join(t.TempDir(), "acl.db"))
	if err != nil {
		t.Fatalf("OpenACL: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	return a
}

func TestACL_ToolEnabledByDefault(t *testing.T) {
	a := openTestACL(t)
	enabled, err := a.IsToolEnabled(context.Background(), "stat")
	if err != nil {
		t.Fatalf("IsToolEnabled: %v", err)
	}
	if !enabled {
		t.Error("expected tool to be enabled by default with no explicit state")
	}
}

func TestACL_DisableTool(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if err := a.SetToolEnabled(ctx, "apt", false); err != nil {
		t.Fatalf("SetToolEnabled: %v", err)
	}
	enabled, err := a.IsToolEnabled(ctx, "apt")
	if err != nil {
		t.Fatal(err)
	}
	if enabled {
		t.Error("expected apt to be disabled after SetToolEnabled(false)")
	}
}

func TestACL_ReenableTool(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	_ = a.SetToolEnabled(ctx, "apt", false)
	if err := a.SetToolEnabled(ctx, "apt", true); err != nil {
		t.Fatal(err)
	}
	enabled, err := a.IsToolEnabled(ctx, "apt")
	if err != nil {
		t.Fatal(err)
	}
	if !enabled {
		t.Error("expected apt to be re-enabled")
	}
}

func TestACL_Authorize_NoRulesAllowsEverythingEnabled(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	dec, err := a.Authorize(ctx, TokenIdentity, "stat", false)
	if err != nil {
		t.Fatalf("Authorize: %v", err)
	}
	if !dec.Allowed {
		t.Errorf("expected allowed with no rules configured, got %+v", dec)
	}
}

func TestACL_Authorize_DisabledToolAlwaysDenied(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	_ = a.SetToolEnabled(ctx, "disk_list", false)

	dec, err := a.Authorize(ctx, TokenIdentity, "disk_list", false)
	if err != nil {
		t.Fatal(err)
	}
	if dec.Allowed {
		t.Error("expected disabled tool to be denied regardless of ACL rules")
	}
}

func TestACL_Authorize_TokenIdentity(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if _, err := a.AddRule(ctx, Rule{PrincipalKind: PrincipalToken, PrincipalName: TokenPrincipalName, Tools: []string{"stat"}, AllowWrite: false}); err != nil {
		t.Fatal(err)
	}

	dec, err := a.Authorize(ctx, TokenIdentity, "stat", false)
	if err != nil || !dec.Allowed {
		t.Errorf("expected token identity allowed for stat, got %+v, err=%v", dec, err)
	}

	dec2, err := a.Authorize(ctx, TokenIdentity, "copy", false)
	if err != nil {
		t.Fatal(err)
	}
	if dec2.Allowed {
		t.Error("expected token identity denied for a tool not covered by any rule (default-deny once rules exist)")
	}
}

func TestACL_Authorize_GroupWithoutWritePermissionBlocked(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if _, err := a.AddRule(ctx, Rule{
		PrincipalKind: PrincipalGroup, PrincipalName: "ops", Tools: nil, AllowWrite: false,
	}); err != nil {
		t.Fatal(err)
	}

	opsUser := Identity{Kind: KindUser, Name: "trainee", Groups: []string{"ops"}}

	readDec, err := a.Authorize(ctx, opsUser, "stat", false)
	if err != nil || !readDec.Allowed {
		t.Errorf("expected read access allowed for group 'ops', got %+v, err=%v", readDec, err)
	}

	writeDec, err := a.Authorize(ctx, opsUser, "copy", true)
	if err != nil {
		t.Fatal(err)
	}
	if writeDec.Allowed {
		t.Error("expected write access to be blocked for a group rule with allow_write=false")
	}
}

func TestACL_Authorize_GroupWithWritePermissionAllowed(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if _, err := a.AddRule(ctx, Rule{
		PrincipalKind: PrincipalGroup, PrincipalName: "wheel", Tools: nil, AllowWrite: true,
	}); err != nil {
		t.Fatal(err)
	}

	admin := Identity{Kind: KindUser, Name: "root-ish", Groups: []string{"wheel"}}
	dec, err := a.Authorize(ctx, admin, "copy", true)
	if err != nil || !dec.Allowed {
		t.Errorf("expected write access allowed for group 'wheel', got %+v, err=%v", dec, err)
	}
}

func TestACL_Authorize_UnrelatedUserDeniedOnceRulesExist(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if _, err := a.AddRule(ctx, Rule{PrincipalKind: PrincipalUser, PrincipalName: "alice", AllowWrite: true}); err != nil {
		t.Fatal(err)
	}

	other := Identity{Kind: KindUser, Name: "mallory", Groups: []string{"users"}}
	dec, err := a.Authorize(ctx, other, "stat", false)
	if err != nil {
		t.Fatal(err)
	}
	if dec.Allowed {
		t.Error("expected an identity with no matching rule to be denied once any rule exists")
	}
}

func TestACL_ListAndDeleteRule(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	id, err := a.AddRule(ctx, Rule{PrincipalKind: PrincipalUser, PrincipalName: "dave", AllowWrite: true})
	if err != nil {
		t.Fatal(err)
	}

	rules, err := a.ListRules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 1 || rules[0].PrincipalName != "dave" {
		t.Fatalf("unexpected rules: %+v", rules)
	}

	if err := a.DeleteRule(ctx, id); err != nil {
		t.Fatal(err)
	}
	rules, err = a.ListRules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 0 {
		t.Errorf("expected no rules after delete, got %+v", rules)
	}
}

func TestACL_RuleScopedToSpecificTools(t *testing.T) {
	a := openTestACL(t)
	ctx := context.Background()
	if _, err := a.AddRule(ctx, Rule{
		PrincipalKind: PrincipalUser, PrincipalName: "scoped", Tools: []string{"stat", "find"}, AllowWrite: false,
	}); err != nil {
		t.Fatal(err)
	}

	identity := Identity{Kind: KindUser, Name: "scoped"}
	dec, err := a.Authorize(ctx, identity, "stat", false)
	if err != nil || !dec.Allowed {
		t.Errorf("expected 'stat' allowed for scoped rule, got %+v", dec)
	}
	dec2, err := a.Authorize(ctx, identity, "copy", false)
	if err != nil {
		t.Fatal(err)
	}
	if dec2.Allowed {
		t.Error("expected 'copy' denied since it's not in the rule's tool list")
	}
}
