package piggyback

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ProxmoxCollector reports every Proxmox VE guest (QEMU VM + LXC container) as
// its own piggyback host — the CheckMK agent_proxmox_ve idea. It authenticates
// with an API ticket and reads /cluster/resources (the live per-guest stats
// list), so a single call yields CPU / memory / disk / status for every guest
// in the cluster.
type ProxmoxCollector struct {
	Host     string // host or host:port (default port 8006)
	User     string // e.g. monitoring@pam
	Password string
	Insecure bool // skip TLS verify (self-signed PVE certs)
	client   *http.Client
}

// NewProxmoxCollector builds a collector for one Proxmox endpoint.
func NewProxmoxCollector(host, user, password string, insecure bool) *ProxmoxCollector {
	return &ProxmoxCollector{
		Host: host, User: user, Password: password, Insecure: insecure,
		client: &http.Client{
			Timeout:   20 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure}}, // #nosec G402 — self-signed PVE certs
		},
	}
}

// Kind implements Collector.
func (p *ProxmoxCollector) Kind() string { return "vm" }

// Source implements Collector (F-9): the Proxmox API host, credentials never
// exposed.
func (p *ProxmoxCollector) Source() SourceInfo {
	return SourceInfo{Type: "proxmox", Target: p.Host}
}

func (p *ProxmoxCollector) base() string {
	host := p.Host
	if !strings.Contains(host, ":") {
		host += ":8006"
	}
	return "https://" + host + "/api2/json"
}

type proxmoxResource struct {
	Type    string  `json:"type"`   // qemu | lxc | node | storage
	Name    string  `json:"name"`   // guest name
	Node    string  `json:"node"`   // hosting node
	VMID    int     `json:"vmid"`   //
	Status  string  `json:"status"` // running | stopped
	CPU     float64 `json:"cpu"`    // fraction 0..1 of allocated cores
	MaxCPU  float64 `json:"maxcpu"` // allocated cores
	Mem     float64 `json:"mem"`    // bytes
	MaxMem  float64 `json:"maxmem"` // bytes
	Disk    float64 `json:"disk"`   // bytes
	MaxDisk float64 `json:"maxdisk"`
	Uptime  float64 `json:"uptime"`
}

// Collect authenticates, reads cluster/resources, and maps every VM/LXC to a
// piggyback host.
func (p *ProxmoxCollector) Collect(ctx context.Context) ([]Host, error) {
	ticket, csrf, err := p.login(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.base()+"/cluster/resources?type=vm", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", "PVEAuthCookie="+ticket)
	req.Header.Set("CSRFPreventionToken", csrf)
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("proxmox cluster/resources: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("proxmox cluster/resources: status %d", resp.StatusCode)
	}
	var body struct {
		Data []proxmoxResource `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return resourcesToHosts(body.Data), nil
}

// login gets an API ticket + CSRF token via /access/ticket.
func (p *ProxmoxCollector) login(ctx context.Context) (ticket, csrf string, err error) {
	form := url.Values{"username": {p.User}, "password": {p.Password}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.base()+"/access/ticket", strings.NewReader(form.Encode()))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := p.client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("proxmox login: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("proxmox login: status %d", resp.StatusCode)
	}
	var body struct {
		Data struct {
			Ticket string `json:"ticket"`
			CSRF   string `json:"CSRFPreventionToken"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", "", err
	}
	if body.Data.Ticket == "" {
		return "", "", fmt.Errorf("proxmox login: no ticket in response")
	}
	return body.Data.Ticket, body.Data.CSRF, nil
}

// resourcesToHosts maps the cluster/resources VM/LXC entries to piggyback hosts.
func resourcesToHosts(resources []proxmoxResource) []Host {
	var out []Host
	for _, r := range resources {
		if r.Type != "qemu" && r.Type != "lxc" {
			continue
		}
		name := r.Name
		if name == "" {
			name = fmt.Sprintf("%s-%d", r.Type, r.VMID)
		}
		metrics := []Metric{
			{Name: "vm_running", Value: boolValue(r.Status == "running")},
			{Name: "vm_cpu_pct", Value: r.CPU * 100.0},
			{Name: "vm_mem_used_bytes", Value: r.Mem},
			{Name: "vm_disk_used_bytes", Value: r.Disk},
		}
		if r.MaxMem > 0 {
			metrics = append(metrics, Metric{Name: "vm_mem_pct", Value: r.Mem / r.MaxMem * 100.0})
		}
		if r.MaxDisk > 0 {
			metrics = append(metrics, Metric{Name: "vm_disk_pct", Value: r.Disk / r.MaxDisk * 100.0})
		}
		if r.Uptime > 0 {
			metrics = append(metrics, Metric{Name: "vm_uptime_seconds", Value: r.Uptime})
		}
		out = append(out, Host{Name: name, Metrics: metrics})
	}
	return out
}
