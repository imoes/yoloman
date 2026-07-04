package modules

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// HTTPDoFunc performs an arbitrary HTTP request and returns its status
// code, headers, and body. Injectable for testing (real implementation
// wraps http.DefaultClient.Do).
type HTTPDoFunc func(req *http.Request) (status int, headers http.Header, body []byte, err error)

func defaultHTTPDo(req *http.Request) (int, http.Header, []byte, error) {
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, nil, err
	}
	return resp.StatusCode, resp.Header, body, nil
}

// URI makes an arbitrary HTTP request and reports its status/headers/body,
// mirroring ansible.builtin.uri. Always write-gated regardless of method:
// method is a runtime parameter (GET vs. POST/PUT/DELETE/...), and this
// tool can make arbitrary outbound requests — including ones with real
// side effects on whatever it calls — so treating even a GET as
// "potentially mutating" is the conservative, least-surprise default for
// this agent's write gate.
type URI struct {
	HTTPDo HTTPDoFunc
}

// NewURI returns a URI module backed by a real HTTP client.
func NewURI() *URI { return &URI{HTTPDo: defaultHTTPDo} }

func (u *URI) Name() string { return "uri" }

func (u *URI) Description() string {
	return "" +
		"Make an arbitrary HTTP(S) request and return its status code, headers, and (if " +
		"requested) body. Fails if the response status isn't in `status_code` (default: just " +
		"200). Always requires write:true regardless of method — method is a runtime parameter " +
		"(GET vs. POST/PUT/DELETE/...) and this tool can reach and mutate arbitrary remote " +
		"systems, so it is treated as a write-class capability uniformly rather than trusting " +
		"the caller's stated method.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.uri. Same url/method/body/headers/status_code/" +
		"return_content semantics (a focused subset — Ansible's own module also supports " +
		"auth/TLS options and response file saving, not yet implemented here).\n" +
		"- Chef: the `Chef::HTTP` class or the `remote_file`/`http_request` resources.\n" +
		"- Puppet: no core equivalent; typically a custom fact/function or an `exec` wrapping " +
		"curl.\n" +
		"- Salt: the `http.query` execution module.\n" +
		"- Terraform: the `http` data source (read-only GET only) or a `null_resource` " +
		"provisioner wrapping curl for anything mutating."
}

func (u *URI) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"url":    stringProp("Request URL."),
		"method": stringProp(`HTTP method. Default "GET".`),
		"body":   stringProp("Optional request body."),
		"headers": map[string]any{
			"type":                 "object",
			"additionalProperties": map[string]any{"type": "string"},
			"description":          "Optional request headers.",
		},
		"status_code": map[string]any{
			"type":        "array",
			"items":       map[string]any{"type": "integer"},
			"description": `Acceptable response status codes. Default [200].`,
		},
		"return_content": boolProp("When true, include the response body in the result. Default false.", false),
	}, "url")
}

func (u *URI) Writes() bool { return true }

func (u *URI) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	url, err := stringParam(params, "url", true, "")
	if err != nil {
		return Result{}, err
	}
	method, err := stringParam(params, "method", false, "GET")
	if err != nil {
		return Result{}, err
	}
	body, err := stringParam(params, "body", false, "")
	if err != nil {
		return Result{}, err
	}
	returnContent, err := boolParam(params, "return_content", false)
	if err != nil {
		return Result{}, err
	}
	statusCodes, err := intSliceParam(params, "status_code", []int{200})
	if err != nil {
		return Result{}, err
	}
	headers, err := stringMapParam(params, "headers")
	if err != nil {
		return Result{}, err
	}

	if dryRun {
		return Result{Changed: false, Msg: "would make HTTP request (dry run)", Data: map[string]any{
			"url": url, "method": strings.ToUpper(method),
		}}, nil
	}

	req, err := http.NewRequestWithContext(ctx, strings.ToUpper(method), url, bytes.NewReader([]byte(body)))
	if err != nil {
		return Result{}, fmt.Errorf("uri: building request: %w", err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	status, respHeaders, respBody, err := u.HTTPDo(req)
	if err != nil {
		return Result{}, fmt.Errorf("uri: requesting %q: %w", url, err)
	}

	ok := false
	for _, want := range statusCodes {
		if status == want {
			ok = true
			break
		}
	}
	if !ok {
		return Result{}, fmt.Errorf("uri: %s %s returned status %d, want one of %v", strings.ToUpper(method), url, status, statusCodes)
	}

	data := map[string]any{"status": status, "url": url}
	if respHeaders != nil {
		flatHeaders := make(map[string]string, len(respHeaders))
		for k := range respHeaders {
			flatHeaders[k] = respHeaders.Get(k)
		}
		data["headers"] = flatHeaders
	}
	if returnContent {
		data["content"] = string(respBody)
	}
	return Result{Changed: false, Msg: "request completed", Data: data}, nil
}

// intSliceParam extracts a []int parameter, accepting JSON-decoded
// []any-of-float64 (the normal shape from an MCP/REST JSON body) as well as
// a native []int (as constructed directly in Go, e.g. in tests). Returns
// def if the parameter is absent.
func intSliceParam(params map[string]any, key string, def []int) ([]int, error) {
	v, ok := params[key]
	if !ok || v == nil {
		return def, nil
	}
	switch vv := v.(type) {
	case []int:
		return vv, nil
	case []any:
		out := make([]int, len(vv))
		for i, e := range vv {
			switch n := e.(type) {
			case float64:
				out[i] = int(n)
			case int:
				out[i] = n
			default:
				return nil, fmt.Errorf("%s[%d]: expected number, got %T", key, i, e)
			}
		}
		return out, nil
	default:
		return nil, fmt.Errorf("%s: expected array of numbers, got %T", key, v)
	}
}

// stringMapParam extracts a map[string]string parameter from a decoded
// map[string]any (the normal shape from an MCP/REST JSON body).
func stringMapParam(params map[string]any, key string) (map[string]string, error) {
	v, ok := params[key]
	if !ok || v == nil {
		return nil, nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s: expected an object, got %T", key, v)
	}
	out := make(map[string]string, len(m))
	for k, val := range m {
		s, ok := val.(string)
		if !ok {
			return nil, fmt.Errorf("%s[%s]: expected string, got %T", key, k, val)
		}
		out[k] = s
	}
	return out, nil
}
