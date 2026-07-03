package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/enroll"
)

// newBearerToken generates a fresh cryptographically random bearer token,
// hex-encoded. Backs both the standalone `--generate-token` flag and
// (indirectly, via the operator pasting it into config.yaml first) the
// `register` subcommand below, which reads the token back out of config.yaml
// rather than generating one itself — the two stay deliberately independent.
func newBearerToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// runRegister implements `agentic-mcpd register`: the client side of a
// one-time bootstrap handshake with a future central Fleet Commander
// ("Bossman", see docs/plan.md's roadmap). It exchanges a shared enrollment
// secret for Bossman's public key, writes that key to disk, and prints the
// config.yaml snippet the operator needs to add to tls.trusted_client_keys
// — it does not modify config.yaml itself, to avoid corrupting a hand-edited
// file.
func runRegister(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd register", flag.ContinueOnError)
	bossmanURL := fs.String("bossman-url", "", "Bossman enrollment endpoint, e.g. https://bossman.internal:8443")
	enrollSecret := fs.String("enroll-secret", "", "shared bootstrap secret provided by the Bossman operator")
	name := fs.String("name", "", "this agent's name as reported to Bossman (default: hostname)")
	address := fs.String("address", "", "this agent's own reachable host:port, so Bossman can reach it later (optional)")
	configPath := fs.String("config", "/etc/agentic-mcp/config.yaml", "path to config.yaml (read for this agent's own bearer token)")
	trustedKeyPath := fs.String("trusted-key-path", "/etc/agentic-mcp/trusted/bossman.pub.pem", "where to write Bossman's public key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bossmanURL == "" {
		return fmt.Errorf("register: --bossman-url is required")
	}
	if *enrollSecret == "" {
		return fmt.Errorf("register: --enroll-secret is required")
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return fmt.Errorf("register: loading %q: %w", *configPath, err)
	}
	if cfg.Token == "" {
		return fmt.Errorf("register: %q has no token set — run 'agentic-mcpd --generate-token', put the result in config.yaml's token field, then retry", *configPath)
	}

	agentName := *name
	if agentName == "" {
		h, err := os.Hostname()
		if err != nil {
			return fmt.Errorf("register: determining hostname: %w", err)
		}
		agentName = h
	}

	result, err := enroll.Register(context.Background(), *bossmanURL, enroll.Request{
		Name:         agentName,
		EnrollSecret: *enrollSecret,
		Token:        cfg.Token,
		Address:      *address,
	})
	if err != nil {
		return fmt.Errorf("register: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(*trustedKeyPath), 0o755); err != nil {
		return fmt.Errorf("register: creating %q: %w", filepath.Dir(*trustedKeyPath), err)
	}
	if err := os.WriteFile(*trustedKeyPath, result.PublicKeyPEM, 0o644); err != nil {
		return fmt.Errorf("register: writing %q: %w", *trustedKeyPath, err)
	}

	fmt.Printf("Registered %q with Bossman", agentName)
	if result.AgentID != "" {
		fmt.Printf(" (agent id: %s)", result.AgentID)
	}
	fmt.Println(".")
	fmt.Printf("Bossman's public key written to %s\n\n", *trustedKeyPath)
	fmt.Println("Add this to config.yaml to let Bossman authenticate to /mcp and /api/v1/:")
	fmt.Println()
	fmt.Println("tls:")
	fmt.Println("  enabled: true")
	fmt.Println("  trusted_client_keys:")
	fmt.Println("    - name: bossman")
	fmt.Printf("      public_key_path: %s\n", *trustedKeyPath)
	fmt.Println()
	fmt.Println("Then restart agentic-mcpd for the change to take effect.")
	return nil
}
