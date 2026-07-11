// Package console gives a host a Proxmox-style web shell: an interactive PTY
// exposed over a WebSocket. On connect the agent spawns a login program
// (/bin/login by default) inside a pseudo-terminal, so the OS login prompt
// appears in the browser terminal and PAM authenticates the operator — the
// shell then runs as that user, not as the (root) agent.
//
// Wire protocol (kept trivial so the Bossman proxy can forward frames blind):
//   - client → server BINARY frame : raw keystrokes, written to the PTY
//   - client → server TEXT frame   : a JSON control message, {"type":"resize",
//     "cols":N,"rows":M}
//   - server → client BINARY frame : raw PTY output
//
// Access is already gated upstream (mTLS + the REST identity middleware, and
// the Bossman proxy's per-host ACL); this handler assumes an authorized caller.
package console

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

// DefaultCommand is the program spawned in the PTY: /bin/login, so the OS login
// prompt appears in the terminal and the operator authenticates via PAM (the
// shell then runs as that user, not the root agent).
//
// It is wrapped in script(1) deliberately. util-linux login does vhangup() on
// its controlling terminal then reopens it; run directly in our PTY that reopen
// fails with EIO ("can't reopen tty"). script allocates a FRESH pty for login
// and keeps its master open, so login's vhangup/reopen works — the standard
// trick for running login-like programs under a pseudo-terminal.
var DefaultCommand = []string{"/usr/bin/script", "-qc", "/bin/login", "/dev/null"}

type ctrl struct {
	Type string `json:"type"`
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

// Handler returns an http.Handler that upgrades to a WebSocket and runs
// `command` (empty → DefaultCommand) in a PTY. The handler does no auth of its
// own by design — mount it behind the same middleware as the rest of /api/v1/.
func Handler(command []string) http.Handler {
	if len(command) == 0 {
		command = DefaultCommand
	}
	upgrader := websocket.Upgrader{
		// Auth is enforced by mTLS + the REST identity middleware upstream, and
		// browsers reach this only via the Bossman proxy — no Origin to check.
		CheckOrigin: func(*http.Request) bool { return true },
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return // Upgrade already wrote the error response
		}
		defer conn.Close()
		serve(conn, command)
	})
}

func serve(conn *websocket.Conn, command []string) {
	cmd := exec.Command(command[0], command[1:]...) // #nosec G204 — command is operator config, not request input
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	// pty.Start makes the child a fresh session leader with the pty as its
	// controlling terminal (Setsid + Setctty), so interactive shells and job
	// control work.
	ptmx, err := pty.Start(cmd)
	if err != nil {
		_ = conn.WriteMessage(websocket.TextMessage, []byte("failed to start console: "+err.Error()))
		return
	}
	var once sync.Once
	done := make(chan struct{})
	stop := func() { once.Do(func() { close(done) }) }

	// The session ends when the login/shell process exits — reap it here (not
	// in a defer) so we can surface WHY it ended. A silent disconnect on an
	// otherwise-working host (e.g. an IPA/SSSD login that authenticates over
	// SSH but not here) is almost always the login/shell exiting; logging its
	// status + echoing it to the terminal makes that diagnosable.
	exit := make(chan error, 1)
	go func() { exit <- cmd.Wait(); stop() }()

	// PTY → WebSocket: stream output as binary frames.
	go func() {
		defer stop()
		buf := make([]byte, 32*1024)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return // PTY closed (shell exited) or read error
			}
		}
	}()

	// WebSocket → PTY: binary = keystrokes, text = control (resize).
	go func() {
		defer stop()
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			switch mt {
			case websocket.BinaryMessage:
				if _, werr := ptmx.Write(data); werr != nil {
					return
				}
			case websocket.TextMessage:
				var c ctrl
				if json.Unmarshal(data, &c) == nil && c.Type == "resize" && c.Cols > 0 && c.Rows > 0 {
					if serr := pty.Setsize(ptmx, &pty.Winsize{Rows: c.Rows, Cols: c.Cols}); serr != nil {
						slog.Debug("console resize failed", "error", serr)
					}
				}
			}
		}
	}()

	<-done
	// Tear down the PTY + ensure the process is reaped, then report the exit.
	_ = ptmx.Close()
	_ = cmd.Process.Kill()
	var werr error
	select {
	case werr = <-exit:
	case <-time.After(2 * time.Second):
		werr = <-exit // Kill guarantees Wait returns
	}
	if werr != nil {
		slog.Info("console session ended", "command", command[0], "error", werr.Error())
		_ = conn.WriteMessage(websocket.TextMessage, []byte("\r\n\x1b[33m[console session ended: "+werr.Error()+"]\x1b[0m\r\n"))
	} else {
		slog.Info("console session ended", "command", command[0], "status", "ok")
	}
}
