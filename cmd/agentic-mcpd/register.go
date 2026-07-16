package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/enroll"
	"github.com/mutkluge/agentic-mcp/internal/tlsauth"
	"gopkg.in/yaml.v3"
)

// newBearerToken generates a fresh cryptographically random bearer token,
// hex-encoded. Backs both the standalone `--generate-token` flag and the
// `register` subcommand's zero-touch bootstrap, which calls this itself when
// the config has no token yet.
func newBearerToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// runRegister implements `agentic-mcpd register`: the client side of a
// one-time bootstrap handshake with whichever enrollment authority this
// agent is joining — a central Fleet Commander ("Bossman", see
// docs/plan.md's roadmap) or a Selecta (a proxy-mode agent accepting
// dynamically enrolled satellites, see internal/server/enroll.go). Both
// speak the identical wire protocol (internal/enroll.Request/Response), so
// one client-side command works generically against either.
//
// Zero-touch: it bootstraps everything the operator would otherwise do by
// hand — generates a bearer token and a self-signed TLS server cert if
// missing, binds a reachable listen from --address, hands over the agent's
// name/token/address, fetches + trusts the enrolling authority's public key
// (so its mTLS client cert is accepted), writes the fully-wired config.yaml,
// and restarts the service. No enrollment secret (registration is open; the
// SSH-driven deploy is the authenticated path). Existing config is updated in
// place (token/cert kept, trusted key + listen ensured), not clobbered.
// advertisedAddress works out the host:port this agent tells Bossman to reach
// it on, plus the address it should listen on. It must produce a reachable
// result WITHOUT --address (zero-touch): the host defaults to the agent name
// (its hostname/FQDN), the port to the configured listen's port (falling back
// to 8010), and the listener is always bound on 0.0.0.0 — never the
// loopback-only default, which would leave the agent enrolled yet unreachable.
// --address overrides host and/or port; given without a port it's the host.
func advertisedAddress(agentName, addressFlag, cfgListen string) (advertise, listen string) {
	listenPort := "8010"
	if _, port, err := net.SplitHostPort(cfgListen); err == nil && port != "" {
		listenPort = port
	}
	host := agentName
	if addressFlag != "" {
		if h, p, err := net.SplitHostPort(addressFlag); err == nil {
			if h != "" {
				host = h
			}
			if p != "" {
				listenPort = p
			}
		} else {
			host = addressFlag
		}
	}
	return net.JoinHostPort(host, listenPort), net.JoinHostPort("0.0.0.0", listenPort)
}

func runRegister(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd register", flag.ContinueOnError)
	enrollURL := fs.String("enroll-url", "", "enrollment endpoint of the Bossman or Selecta this agent is joining, e.g. https://selecta.internal:8443")
	enrollSecret := fs.String("enroll-secret", "", "optional shared bootstrap secret — Bossman enrollment is open and ignores it; a Selecta proxy may still require it")
	name := fs.String("name", "", "this agent's name as reported to the enrollment authority (default: hostname)")
	address := fs.String("address", "", "override this agent's auto-detected reachable host:port (default: <name>:<listen-port>); rarely needed")
	configPath := fs.String("config", "/etc/agentic-mcp/config.yaml", "path to config.yaml (read for this agent's own bearer token)")
	keyName := fs.String("key-name", "enroller", "name under which to pin the fetched key in tls.trusted_client_keys")
	trustedKeyPath := fs.String("trusted-key-path", "/etc/agentic-mcp/trusted/enroller.pub.pem", "where to write the enrollment authority's public key")
	noRestart := fs.Bool("no-restart", false, "don't try to restart agentic-mcp.service after writing the config (e.g. in a container)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *enrollURL == "" {
		return fmt.Errorf("register: --enroll-url is required")
	}

	// Zero-touch bootstrap: load the config if it exists, else start from
	// defaults — the operator never has to pre-create it or hand-paste a token.
	var (
		cfg config.Config
		err error
	)
	if _, statErr := os.Stat(*configPath); statErr == nil {
		cfg, err = config.Load(*configPath)
		if err != nil {
			return fmt.Errorf("register: loading %q: %w", *configPath, err)
		}
	} else {
		cfg = config.Default()
	}

	// Generate a bearer token if there isn't one yet.
	if cfg.Token == "" {
		tok, tErr := newBearerToken()
		if tErr != nil {
			return fmt.Errorf("register: %w", tErr)
		}
		cfg.Token = tok
		fmt.Println("register: generated a new bearer token")
	}

	// TLS server cert so Bossman can pull over https (it verifies by bearer
	// token + its own client cert, not a CA chain — a self-signed cert is
	// fine). Generate one if missing; enable TLS.
	confDir := filepath.Dir(*configPath)
	if cfg.TLS.CertFile == "" {
		cfg.TLS.CertFile = filepath.Join(confDir, "tls.crt")
	}
	if cfg.TLS.KeyFile == "" {
		cfg.TLS.KeyFile = filepath.Join(confDir, "tls.key")
	}
	agentName := *name
	if agentName == "" {
		h, hErr := os.Hostname()
		if hErr != nil {
			return fmt.Errorf("register: determining hostname: %w", hErr)
		}
		agentName = h
	}
	if err := tlsauth.EnsureSelfSigned(cfg.TLS.CertFile, cfg.TLS.KeyFile, agentName); err != nil {
		return fmt.Errorf("register: TLS cert: %w", err)
	}
	cfg.TLS.Enabled = true

	// Work out this agent's own reachable address (host:port) so Bossman can
	// pull from it — the whole point of enrolling. This MUST work without
	// --address: a zero-touch enroll shouldn't require the operator to know
	// and type the host's reachable address. So default the host to the agent
	// name (its hostname/FQDN, which is also how Bossman refers to it) and the
	// port to the configured listen port, and ALWAYS bind the listener on
	// 0.0.0.0 — the config default 127.0.0.1 is loopback-only, so an agent
	// registered without --address used to enroll fine yet be unreachable
	// (empty address in Bossman + a loopback listen). --address stays as an
	// override for when the auto-detected name isn't the reachable one.
	advAddress, listenBind := advertisedAddress(agentName, *address, cfg.Listen)
	cfg.Listen = listenBind
	fmt.Printf("register: advertising reachable address %s (listening on %s)\n", advAddress, cfg.Listen)

	result, err := enroll.Register(context.Background(), *enrollURL, enroll.Request{
		Name:         agentName,
		EnrollSecret: *enrollSecret,
		Token:        cfg.Token,
		Address:      advAddress,
	})
	if err != nil {
		return fmt.Errorf("register: %w", err)
	}

	// Trust the enrolling authority's key so its mTLS client cert is accepted
	// on /api/v1/ + /mcp (otherwise every pull is 403).
	if err := os.MkdirAll(filepath.Dir(*trustedKeyPath), 0o755); err != nil {
		return fmt.Errorf("register: creating %q: %w", filepath.Dir(*trustedKeyPath), err)
	}
	if err := os.WriteFile(*trustedKeyPath, result.PublicKeyPEM, 0o644); err != nil {
		return fmt.Errorf("register: writing %q: %w", *trustedKeyPath, err)
	}
	hasKey := false
	for _, k := range cfg.TLS.TrustedClientKeys {
		if k.PublicKeyPath == *trustedKeyPath {
			hasKey = true
			break
		}
	}
	if !hasKey {
		cfg.TLS.TrustedClientKeys = append(cfg.TLS.TrustedClientKeys, config.TrustedClientKey{
			Name: *keyName, PublicKeyPath: *trustedKeyPath,
		})
	}

	// Persist the fully-wired config — no hand-editing, no restart prompt.
	out, err := yaml.Marshal(&cfg)
	if err != nil {
		return fmt.Errorf("register: marshaling config: %w", err)
	}
	if err := os.MkdirAll(confDir, 0o755); err != nil {
		return fmt.Errorf("register: creating %q: %w", confDir, err)
	}
	if err := os.WriteFile(*configPath, out, 0o600); err != nil {
		return fmt.Errorf("register: writing %q: %w", *configPath, err)
	}

	fmt.Printf("Registered %q with %s", agentName, *enrollURL)
	if result.AgentID != "" {
		fmt.Printf(" (agent id: %s)", result.AgentID)
	}
	fmt.Println(".")
	fmt.Printf("Config written to %s (token, TLS cert, trusted enroller key — all set up).\n", *configPath)

	// Restart the service so the new config takes effect — best-effort, since
	// there's no systemd in a container (there the caller re-execs the daemon).
	if !*noRestart {
		if _, lookErr := exec.LookPath("systemctl"); lookErr == nil {
			if rErr := exec.Command("systemctl", "restart", "agentic-mcp.service").Run(); rErr == nil {
				fmt.Println("Restarted agentic-mcp.service.")
			} else {
				fmt.Printf("Could not restart agentic-mcp.service automatically (%v) — restart it manually.\n", rErr)
			}
		}
	}
	return nil
}
