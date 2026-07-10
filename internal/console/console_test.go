package console

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// dialConsole starts the console handler running `command` behind an httptest
// server and returns a connected WebSocket client.
func dialConsole(t *testing.T, command []string) (*websocket.Conn, func()) {
	t.Helper()
	srv := httptest.NewServer(Handler(command))
	url := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, resp, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		srv.Close()
		t.Fatalf("dial console: %v (status %d)", err, status)
	}
	return conn, func() { conn.Close(); srv.Close() }
}

func TestConsole_PTYEchoesInput(t *testing.T) {
	// A PTY running `cat`: its line discipline echoes typed input, so what we
	// send comes back — proof the WS↔PTY pumping works both ways.
	conn, cleanup := dialConsole(t, []string{"/bin/cat"})
	defer cleanup()

	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("ping-123\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var got strings.Builder
	for i := 0; i < 10; i++ {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		if mt == websocket.BinaryMessage {
			got.Write(data)
			if strings.Contains(got.String(), "ping-123") {
				return // success
			}
		}
	}
	t.Fatalf("did not see echoed input; got %q", got.String())
}

func TestConsole_ResizeControlMessageAccepted(t *testing.T) {
	conn, cleanup := dialConsole(t, []string{"/bin/cat"})
	defer cleanup()

	// A resize control frame must be handled (not written to the PTY as data)
	// and must not tear the connection down.
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"resize","cols":120,"rows":40}`)); err != nil {
		t.Fatalf("write resize: %v", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, []byte("after-resize\n")); err != nil {
		t.Fatalf("write after resize: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for i := 0; i < 10; i++ {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("connection broke after resize: %v", err)
		}
		if mt == websocket.BinaryMessage && strings.Contains(string(data), "after-resize") {
			return
		}
	}
	t.Fatal("did not see input echoed after a resize")
}

func TestConsole_ExitClosesSocket(t *testing.T) {
	// A command that exits immediately must close the WebSocket (the shell
	// ended), not hang.
	conn, cleanup := dialConsole(t, []string{"/bin/echo", "bye"})
	defer cleanup()

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	closed := false
	for i := 0; i < 20; i++ {
		if _, _, err := conn.ReadMessage(); err != nil {
			closed = true
			break
		}
	}
	if !closed {
		t.Fatal("socket stayed open after the console command exited")
	}
}

func TestConsole_UpgradeRequiresWebSocket(t *testing.T) {
	// A plain GET (no Upgrade headers) must not 500 — gorilla writes a 400.
	srv := httptest.NewServer(Handler([]string{"/bin/cat"}))
	defer srv.Close()
	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("plain GET status = %d, want 400", resp.StatusCode)
	}
}
