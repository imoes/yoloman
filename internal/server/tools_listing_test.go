package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// GET /api/v1/tools makes the write gate readable: a closed gate lists the
// write tools it withholds, each with the reason, so a caller can grey the
// action out up front instead of calling it into a 403.
func TestToolsListing_PublishesWriteGate(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(stubModule{name: "reader", writes: false})
	_ = reg.Register(stubModule{name: "writer", writes: true})

	for _, write := range []bool{false, true} {
		srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: write, ModReg: reg}))
		resp, err := http.Get(srv.URL + "/api/v1/tools")
		if err != nil {
			t.Fatal(err)
		}
		var body struct {
			Tools    []availableTool `json:"tools"`
			Write    bool            `json:"write"`
			Withheld []withheldTool  `json:"withheld"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		srv.Close()
		if body.Write != write {
			t.Errorf("write=%v: listing says write=%v", write, body.Write)
		}
		if write {
			if len(body.Withheld) != 0 || len(body.Tools) != 3 { // reader, writer, run_pipeline
				t.Errorf("open gate: tools=%v withheld=%v", body.Tools, body.Withheld)
			}
			continue
		}
		if len(body.Tools) != 1 || body.Tools[0].Name != "reader" {
			t.Errorf("closed gate offers only the reader: %v", body.Tools)
		}
		if len(body.Withheld) != 2 || body.Withheld[0].Name != "writer" || !strings.Contains(body.Withheld[0].Reason, "write=false") {
			t.Errorf("closed gate names the withheld writer and why: %+v", body.Withheld)
		}
	}
}

// The refused call carries the same sentence as the listing.
func TestToolCall_WriteGateRefusalNamesReason(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(stubModule{name: "writer", writes: true})
	srv := httptest.NewServer(NewRESTHandler(RESTConfig{Write: false, ModReg: reg}))
	defer srv.Close()
	resp, err := http.Post(srv.URL+"/api/v1/tools/writer", "application/json", bytes.NewReader([]byte(`{"params":{}}`)))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var e struct{ Error string }
	_ = json.Unmarshal(b, &e)
	if resp.StatusCode != http.StatusForbidden || e.Error != writeGateReason("writer") {
		t.Fatalf("status=%d body=%s", resp.StatusCode, b)
	}
}
