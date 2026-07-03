package enroll

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRegister_Success(t *testing.T) {
	var gotReq Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/enroll" {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if err := json.NewDecoder(r.Body).Decode(&gotReq); err != nil {
			t.Errorf("decoding request: %v", err)
		}
		if gotReq.EnrollSecret != "correct-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(Response{
			BossmanPublicKey: "-----BEGIN PUBLIC KEY-----\nfakekeydata\n-----END PUBLIC KEY-----\n",
			AgentID:          "agent-42",
		})
	}))
	defer srv.Close()

	result, err := Register(context.Background(), srv.URL, Request{
		Name:         "vpp0221",
		EnrollSecret: "correct-secret",
		Token:        "agent-own-token",
		Address:      "vpp0221.example.com:8010",
	})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if result.AgentID != "agent-42" {
		t.Errorf("AgentID = %q, want agent-42", result.AgentID)
	}
	if !strings.Contains(string(result.PublicKeyPEM), "fakekeydata") {
		t.Errorf("PublicKeyPEM = %q, missing expected content", result.PublicKeyPEM)
	}
	if gotReq.Name != "vpp0221" || gotReq.Token != "agent-own-token" || gotReq.Address != "vpp0221.example.com:8010" {
		t.Errorf("unexpected request received by server: %+v", gotReq)
	}
}

func TestRegister_WrongSecretRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req Request
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.EnrollSecret != "correct-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte("invalid enrollment secret"))
			return
		}
		_ = json.NewEncoder(w).Encode(Response{BossmanPublicKey: "should-not-be-reached"})
	}))
	defer srv.Close()

	_, err := Register(context.Background(), srv.URL, Request{
		Name:         "vpp0221",
		EnrollSecret: "wrong-secret",
		Token:        "agent-own-token",
	})
	if err == nil {
		t.Fatal("expected error for wrong enrollment secret")
	}
}

func TestRegister_EmptyPublicKeyRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(Response{BossmanPublicKey: ""})
	}))
	defer srv.Close()

	_, err := Register(context.Background(), srv.URL, Request{Name: "x", EnrollSecret: "s", Token: "t"})
	if err == nil {
		t.Fatal("expected error for empty bossman_public_key in response")
	}
}

func TestRegister_ServerUnreachable(t *testing.T) {
	_, err := Register(context.Background(), "http://127.0.0.1:1", Request{Name: "x", EnrollSecret: "s", Token: "t"})
	if err == nil {
		t.Fatal("expected error when Bossman is unreachable")
	}
}

func TestRegister_ServerErrorPropagatesMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("database unavailable"))
	}))
	defer srv.Close()

	_, err := Register(context.Background(), srv.URL, Request{Name: "x", EnrollSecret: "s", Token: "t"})
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
	if !strings.Contains(err.Error(), "database unavailable") {
		t.Errorf("error should propagate server message, got: %v", err)
	}
}
