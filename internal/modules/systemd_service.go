package modules

// SystemdService is a thin alias for Systemd under Ansible's newer,
// systemd-specific generic module name (introduced alongside `service` to
// disambiguate from the multi-init-system dispatcher). This agent only
// targets systemd hosts, so it is a direct pass-through, same as Service.
type SystemdService struct{ *Systemd }

// NewSystemdService returns a SystemdService module (alias of Systemd)
// backed by the real systemctl.
func NewSystemdService() *SystemdService { return &SystemdService{Systemd: NewSystemd()} }

func (s *SystemdService) Name() string { return "systemd_service" }

func (s *SystemdService) Description() string {
	return "" +
		"Alias of the systemd module under Ansible's newer, systemd-specific generic module " +
		"name (as opposed to `service`, which dispatches across multiple possible init " +
		"systems). This agent only targets systemd hosts, so `service`, `systemd`, and " +
		"`systemd_service` all behave identically here. See the systemd module's description " +
		"for full parameter and cross-tool details."
}
