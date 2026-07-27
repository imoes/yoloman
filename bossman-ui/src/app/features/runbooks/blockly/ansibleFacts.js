// awx-ng: curated list of ansible_facts + "magic variables", cross-checked
// against the official docs (docs.ansible.com/.../playbooks_vars_facts.html)
// per user request. There's no way to discover these dynamically inside the
// builder (facts only exist at play runtime on the target host; magic
// variables are runtime-computed by Ansible itself), so — like blocks.js's
// CURATED_CHOICES for package.state — a hand-picked list covers the
// documented set. Shown in the Variables panel alongside role/vault
// variables so users can drag one straight into a when: condition (see
// conditionParser.js's "is defined"/comparison support) without having to
// remember exact names.

// ansible_facts — gathered by setup/gather_facts on every play by default.
const ANSIBLE_FACTS = [
  // System identity
  ['ansible_facts[\'distribution\']', 'OS name, e.g. Debian, Ubuntu, CentOS'],
  ['ansible_facts[\'distribution_version\']', 'Full OS version string, e.g. 22.04'],
  ['ansible_facts[\'distribution_major_version\']', 'Major OS version, e.g. 22 (string)'],
  ['ansible_facts[\'distribution_release\']', 'OS release codename, e.g. bookworm, jammy'],
  ['ansible_facts[\'os_family\']', 'OS family, e.g. Debian, RedHat'],
  ['ansible_facts[\'system\']', 'Kernel/OS type, e.g. Linux'],
  ['ansible_facts[\'kernel\']', 'Kernel version'],
  ['ansible_facts[\'architecture\']', 'CPU architecture, e.g. x86_64'],
  ['ansible_facts[\'machine\']', 'Machine hardware type, e.g. x86_64'],
  ['ansible_facts[\'hostname\']', 'Short hostname'],
  ['ansible_facts[\'nodename\']', 'Node name as reported by the kernel'],
  ['ansible_facts[\'fqdn\']', 'Fully qualified domain name'],
  ['ansible_facts[\'domain\']', 'DNS domain'],
  ['ansible_facts[\'lsb\']', 'Linux Standard Base info (dict: id/release/codename/description)'],

  // Hardware / CPU / memory
  ['ansible_facts[\'processor_cores\']', 'Physical CPU cores'],
  ['ansible_facts[\'processor_count\']', 'Number of physical CPUs'],
  ['ansible_facts[\'processor_vcpus\']', 'Number of virtual CPUs'],
  ['ansible_facts[\'processor_threads_per_core\']', 'Hardware threads per core'],
  ['ansible_facts[\'memtotal_mb\']', 'Total RAM in MB'],
  ['ansible_facts[\'memfree_mb\']', 'Free RAM in MB'],
  ['ansible_facts[\'swaptotal_mb\']', 'Total swap in MB'],
  ['ansible_facts[\'swapfree_mb\']', 'Free swap in MB'],
  ['ansible_facts[\'form_factor\']', 'Hardware form factor, e.g. Desktop, Server, VM'],
  ['ansible_facts[\'product_name\']', 'Hardware/VM product name'],
  ['ansible_facts[\'system_vendor\']', 'Hardware vendor, e.g. Dell Inc., QEMU'],
  ['ansible_facts[\'machine_id\']', 'Unique machine ID (/etc/machine-id)'],

  // Network
  ['ansible_facts[\'default_ipv4\'][\'address\']', 'Primary IPv4 address'],
  ['ansible_facts[\'default_ipv6\'][\'address\']', 'Primary IPv6 address'],
  ['ansible_facts[\'all_ipv4_addresses\']', 'List of all IPv4 addresses'],
  ['ansible_facts[\'all_ipv6_addresses\']', 'List of all IPv6 addresses'],
  ['ansible_facts[\'interfaces\']', 'List of network interface names'],
  ['ansible_facts[\'dns\'][\'nameservers\']', 'Configured DNS nameservers (list)'],

  // Storage
  ['ansible_facts[\'mounts\']', 'Filesystem mount points with usage details (list of dicts)'],
  ['ansible_facts[\'devices\']', 'Block devices incl. partitions/UUIDs (dict)'],

  // Date/time
  ['ansible_facts[\'date_time\'][\'date\']', 'Current date on the target (YYYY-MM-DD)'],
  ['ansible_facts[\'date_time\'][\'time\']', 'Current time on the target (HH:MM:SS)'],
  ['ansible_facts[\'date_time\'][\'iso8601\']', 'Current UTC timestamp, ISO 8601'],
  ['ansible_facts[\'date_time\'][\'epoch\']', 'Current Unix epoch seconds'],
  ['ansible_facts[\'date_time\'][\'weekday\']', 'Current weekday name, e.g. Monday'],
  ['ansible_facts[\'uptime_seconds\']', 'System uptime in seconds'],

  // User / environment
  ['ansible_facts[\'user_id\']', 'Remote login user name'],
  ['ansible_facts[\'user_uid\']', 'Remote login user UID'],
  ['ansible_facts[\'user_dir\']', 'Remote login user home directory'],
  ['ansible_facts[\'user_shell\']', 'Remote login user shell'],
  ['ansible_facts[\'env\'][\'PATH\']', 'Remote user\'s PATH environment variable'],
  ['ansible_facts[\'env\'][\'HOME\']', 'Remote user\'s HOME environment variable'],
  ['ansible_facts[\'env\'][\'LANG\']', 'Remote user\'s LANG environment variable'],

  // Security
  ['ansible_facts[\'selinux\'][\'status\']', 'SELinux status, e.g. enabled/disabled'],
  ['ansible_facts[\'selinux\'][\'mode\']', 'SELinux mode, e.g. enforcing/permissive'],
  ['ansible_facts[\'fips\']', 'Whether the host is running in FIPS mode (bool)'],

  // Software / package manager
  ['ansible_facts[\'python\'][\'version\'][\'major\']', 'Remote Python major version'],
  ['ansible_facts[\'python_version\']', 'Remote Python version string'],
  ['ansible_facts[\'service_mgr\']', 'Service manager, e.g. systemd'],
  ['ansible_facts[\'pkg_mgr\']', 'Package manager, e.g. apt, yum, dnf'],

  // Virtualization
  ['ansible_facts[\'virtualization_type\']', 'Virtualization platform, e.g. kvm, vmware, docker, lxc'],
  ['ansible_facts[\'virtualization_role\']', 'guest or host'],
  ['ansible_facts[\'is_chroot\']', 'Whether running inside a chroot (bool)'],

  // Custom facts (facts.d)
  ['ansible_local', 'Custom facts from /etc/ansible/facts.d/*.fact (dict, requires gather_facts)'],
];

// "Magic variables" — NOT gathered facts, but computed/provided by Ansible
// itself at runtime; used the same way (bare name, no {{ }}, in when:/vars).
const MAGIC_VARIABLES = [
  ['inventory_hostname', 'Current host\'s name exactly as defined in the inventory'],
  ['inventory_hostname_short', 'inventory_hostname up to the first dot'],
  ['group_names', 'List of inventory groups the current host belongs to'],
  ['groups', 'Dict of all inventory groups → list of member hostnames'],
  ['hostvars', 'Dict of every host\'s variables, e.g. hostvars["other_host"]["ansible_facts"]'],
  ['ansible_play_hosts', 'Hosts currently active in this play (excludes failed/unreachable)'],
  ['ansible_play_batch', 'Hosts in the current serial: batch'],
  ['ansible_check_mode', 'True when the playbook is run with --check'],
  ['ansible_version[\'full\']', 'Full Ansible version string running the playbook'],
  ['playbook_dir', 'Directory containing the current playbook'],
  ['role_path', 'Current role\'s directory (only valid inside a role)'],
  ['inventory_dir', 'Directory of the inventory file in use'],
  ['inventory_file', 'Full path to the inventory file in use'],
];

// Matches the {name, source, preview} shape VariablesPanel already renders
// for role/vault variables (see VariablesPanel.js's loadVariables()).
export const ANSIBLE_FACT_VARIABLES = ANSIBLE_FACTS.map(([name, preview]) => ({
  name,
  source: 'ansible fact',
  preview,
}));

export const ANSIBLE_MAGIC_VARIABLES = MAGIC_VARIABLES.map(([name, preview]) => ({
  name,
  source: 'magic variable',
  preview,
}));
