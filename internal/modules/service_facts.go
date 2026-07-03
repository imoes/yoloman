package modules

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strings"
)

// ServiceFacts lists systemd services and their load/active/sub state,
// mirroring ansible.builtin.service_facts. There is no /proc source for
// this, so it shells out to systemctl like Ansible's own implementation
// does; Runner is injectable for testing.
type ServiceFacts struct {
	Runner CommandRunner
}

// NewServiceFacts returns a ServiceFacts module backed by the real systemctl.
func NewServiceFacts() *ServiceFacts {
	return &ServiceFacts{Runner: defaultCommandRunner}
}

func (m *ServiceFacts) Name() string { return "service_facts" }

func (m *ServiceFacts) Description() string {
	return "" +
		"Enumerate every systemd service unit known to the host (via `systemctl list-units " +
		"--type=service --all`) along with its load/active/sub state (e.g. loaded/active/" +
		"running, loaded/failed/failed, not-found/inactive/dead). Takes no parameters — it " +
		"always returns the full list; filter client-side for a specific service. Use this to " +
		"check whether a desired service is already running before deciding to call the write-" +
		"gated `service`/`systemd` module, or to answer 'what services are on this box' " +
		"questions.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.service_facts. Same underlying `systemctl list-units` " +
		"approach; result shape mirrors ansible_facts['services'].\n" +
		"- Chef: no direct fact-gathering equivalent; typically queried ad hoc via a " +
		"`shell_out('systemctl ...')` in a recipe/library, since Ohai does not enumerate " +
		"services by default.\n" +
		"- Puppet: `puppet resource service` lists resources of type service with their " +
		"ensure/enable state.\n" +
		"- Salt: the `service.get_all` and `service.status` execution modules.\n" +
		"- Terraform: not applicable — Terraform does not perform live runtime service " +
		"introspection; this kind of check would be done via a `null_resource` " +
		"`local-exec`/`remote-exec` provisioner shelling out to systemctl."
}

func (m *ServiceFacts) InputSchema() map[string]any {
	return objectSchema(map[string]any{})
}

func (m *ServiceFacts) Writes() bool { return false }

func (m *ServiceFacts) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	out, err := m.Runner(ctx, "systemctl", "list-units", "--type=service", "--all", "--no-legend", "--no-pager", "--plain")
	if err != nil {
		return Result{}, fmt.Errorf("service_facts: running systemctl: %w", err)
	}
	return Result{Changed: false, Data: parseSystemctlListUnits(out)}, nil
}

// parseSystemctlListUnits parses the plain, legend-less output of
// `systemctl list-units --type=service --all --no-legend --no-pager --plain`:
// one line per unit as "<unit> <load> <active> <sub> <description...>".
func parseSystemctlListUnits(out []byte) []map[string]any {
	var services []map[string]any
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		services = append(services, map[string]any{
			"unit":   fields[0],
			"name":   strings.TrimSuffix(fields[0], ".service"),
			"load":   fields[1],
			"active": fields[2],
			"sub":    fields[3],
		})
	}
	if services == nil {
		services = []map[string]any{}
	}
	return services
}
