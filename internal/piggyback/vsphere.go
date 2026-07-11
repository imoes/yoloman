package piggyback

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// VSphereCollector reports every vCenter VM as its own piggyback host — the
// CheckMK agent_vsphere idea, but via the vCenter REST API (6.5+) instead of
// SOAP, which is far simpler: a session token then GET /vcenter/vm. It reports
// power state + CPU/memory allocation per VM. (Live utilization needs the perf
// API; this first cut carries what the inventory endpoint gives directly.)
type VSphereCollector struct {
	Host     string
	User     string
	Password string
	Insecure bool
	client   *http.Client
}

// NewVSphereCollector builds a collector for one vCenter endpoint.
func NewVSphereCollector(host, user, password string, insecure bool) *VSphereCollector {
	return &VSphereCollector{
		Host: host, User: user, Password: password, Insecure: insecure,
		client: &http.Client{
			Timeout:   20 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure}}, // #nosec G402
		},
	}
}

// Kind implements Collector.
func (v *VSphereCollector) Kind() string { return "vm" }

type vsphereVM struct {
	VM         string `json:"vm"`
	Name       string `json:"name"`
	PowerState string `json:"power_state"` // POWERED_ON | POWERED_OFF | SUSPENDED
	CPUCount   int    `json:"cpu_count"`
	MemMiB     int    `json:"memory_size_MiB"`
}

// Collect authenticates and lists the vCenter's VMs.
func (v *VSphereCollector) Collect(ctx context.Context) ([]Host, error) {
	token, err := v.login(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+v.Host+"/rest/vcenter/vm", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("vmware-api-session-id", token)
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("vsphere vm list: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("vsphere vm list: status %d", resp.StatusCode)
	}
	var body struct {
		Value []vsphereVM `json:"value"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return vmsToHosts(body.Value), nil
}

// login gets a session token via POST /rest/com/vmware/cis/session (basic auth).
func (v *VSphereCollector) login(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+v.Host+"/rest/com/vmware/cis/session", nil)
	if err != nil {
		return "", err
	}
	req.SetBasicAuth(v.User, v.Password)
	resp, err := v.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("vsphere login: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("vsphere login: status %d", resp.StatusCode)
	}
	var body struct {
		Value string `json:"value"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	if body.Value == "" {
		return "", fmt.Errorf("vsphere login: no session token")
	}
	return body.Value, nil
}

// vmsToHosts maps vCenter VM inventory entries to piggyback hosts.
func vmsToHosts(vms []vsphereVM) []Host {
	var out []Host
	for _, vm := range vms {
		name := vm.Name
		if name == "" {
			name = vm.VM
		}
		metrics := []Metric{
			{Name: "vm_running", Value: boolValue(vm.PowerState == "POWERED_ON")},
		}
		if vm.CPUCount > 0 {
			metrics = append(metrics, Metric{Name: "vm_cpu_count", Value: float64(vm.CPUCount)})
		}
		if vm.MemMiB > 0 {
			metrics = append(metrics, Metric{Name: "vm_mem_bytes", Value: float64(vm.MemMiB) * 1024 * 1024})
		}
		out = append(out, Host{Name: name, Metrics: metrics})
	}
	return out
}
