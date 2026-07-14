/** Matches bossman/api/agents.py's AgentOut. */
export interface Agent {
  id: string;
  name: string;
  address: string | null;
  mode: string;
  enrollment_state: string;
  last_seen_at: string | null;
  metadata: Record<string, unknown>;
  groups: string[];
  parent_agent_id: string | null;
  /** Block L3d: the OU this host is placed in (null = unassigned). */
  ou_id?: string | null;
  /** A resolvable name even when `address` is null (a satellite polled via a
   * proxy) — falls back to the inventory hostname. Used by the run/inventory
   * views so a DNS name shows instead of a blank. */
  dns_name?: string | null;
  /** The host's HW/SW inventory document (Go agent internal/inventory,
   * Block H2) — {} until the first poll after enrollment. */
  facts: InventoryFacts;
  facts_updated_at: string | null;
}

/** Mirrors internal/inventory.Inventory's JSON shape (all optional —
 * missing sources are omitted by the agent). */
export interface InventoryFacts {
  collected_at?: string;
  system?: {
    manufacturer?: string;
    product_name?: string;
    serial_number?: string;
    uuid?: string;
    family?: string;
    version?: string;
    chassis_type?: string;
    virtualization?: string;
  };
  board?: { vendor?: string; name?: string; serial?: string; version?: string };
  bios?: { vendor?: string; version?: string; date?: string; release?: string };
  cpu?: {
    model?: string;
    vendor?: string;
    sockets?: number;
    cores?: number;
    threads?: number;
    mhz?: string;
    cache?: string;
    architecture?: string;
  };
  memory_mb?: number;
  os?: {
    distribution?: string;
    version?: string;
    id?: string;
    pretty_name?: string;
    codename?: string;
    kernel?: string;
    hostname?: string;
  };
  disks?: { name: string; size_bytes?: number; model?: string; serial?: string; rotational?: boolean }[];
  nics?: {
    name: string;
    mac?: string;
    state?: string;
    mtu?: number;
    speed_mbps?: number;
    /** Per-NIC addresses (Block C1a) — populated once the agent's inventory
     * collector reports them; older agents omit these. */
    ipv4?: string[];
    ipv6?: string[];
  }[];
}

export interface MetricPoint {
  time: string;
  value: number;
  labels: Record<string, string>;
}

export interface MetricSeriesResponse {
  metric: string;
  points: MetricPoint[];
}

/** GET /agents/{id}/ebpf — the 'what' behind the latency heatmaps. */
export interface EbpfTopTalker { comm: string; dst_addr: string; dst_port: number; count: number; }
export interface EbpfDiskIO { comm: string; dev: number; latency_ns: number; rwbs: string; timestamp: string; error: number; }
export interface EbpfDetail { top_talkers: EbpfTopTalker[]; slowest_disk_io: EbpfDiskIO[]; }

export interface MetricCatalogResponse {
  metrics: string[];
}

/** One metric's newest sample — the "last value / last check" row of the
 * host-detail Metrics tab's latest-data list (matches agents.py's
 * LatestMetricOut). One entry per metric name. */
export interface LatestMetric {
  metric: string;
  time: string;
  value: number;
  labels: Record<string, string>;
}

export interface LatestMetricsResponse {
  metrics: LatestMetric[];
}

/** One eBPF-observed outbound endpoint a process talks to (Block J1). */
export interface ProcessConn {
  dst_addr: string;
  dst_port: number;
  state: string;
}

/** One process row from GET /api/v1/agents/{id}/processes — the /proc view
 * plus optional eBPF enrichment (container id, connections). CPU% is scaled
 * so 100% == one core (top style). Matches the agent's ProcessView. */
export interface Process {
  pid: number;
  ppid: number;
  user: string;
  uid: number;
  comm: string;
  command: string;
  state: string;
  cpu_percent: number;
  rss_kib: number;
  num_threads: number;
  container_id?: string;
  connections?: ProcessConn[];
}

export interface ProcessesResponse {
  processes: Process[];
  count: number;
  sample_window_ms: number;
}

/** GET /agents/{id}/processes/history?comm= — CPU%/RSS trend for one process,
 * keyed by command name (comm) so it survives restarts (pid changes, comm
 * doesn't). The combined-graph source behind an expanded process row. */
export interface ProcessHistory {
  comm: string;
  cpu_percent: { time: string; value: number }[];
  rss_bytes: { time: string; value: number }[];
}

// ---- Block J4: Cockpit-like host management ----

/** One systemd service unit as reported by the agent's `service_facts`. */
export interface ServiceUnit {
  unit: string;
  name: string;
  load: string;
  active: string;
  sub: string;
  /** UnitFileState from `systemctl list-unit-files`: enabled/disabled/static/… */
  enabled?: string;
}

export interface ServicesResponse {
  agent_id: string;
  services: ServiceUnit[];
}

/** One journald entry as returned by the agent's `journal` module. */
export interface LogEntry {
  timestamp: string;
  unit: string;
  priority: string;
  message: string;
  pid: string;
  hostname: string;
}

export interface LogsResponse {
  agent_id: string;
  entries: LogEntry[];
  count: number;
}

export interface LogFilters {
  lines?: number;
  unit?: string;
  priority?: string;
  since?: string;
  grep?: string;
  boot?: boolean;
}

/** J4c: an account (user) from the host's passwd database. */
export interface AccountUser {
  name: string;
  uid: number;
  gid: number | null;
  gecos: string;
  home: string;
  shell: string;
  system: boolean;
}

export interface AccountGroup {
  name: string;
  gid: number | null;
  members: string[];
  system: boolean;
}

export interface AccountsResponse {
  agent_id: string;
  users: AccountUser[];
  groups: AccountGroup[];
}

export interface UserAction {
  name: string;
  state?: 'present' | 'absent';
  uid?: string;
  group?: string;
  groups?: string;
  shell?: string;
  home?: string;
  comment?: string;
  system?: boolean;
  create_home?: boolean;
  remove?: boolean;
  dry_run?: boolean;
}

export interface GroupAction {
  name: string;
  state?: 'present' | 'absent';
  gid?: string;
  system?: boolean;
  dry_run?: boolean;
}

/** J4d: storage overview. Each section has an `available` flag; when false it
 * carries an `error` instead of data (tool absent on this host). */
export interface StorageSection {
  available: boolean;
  error?: string;
  [key: string]: unknown;
}

export interface StorageResponse {
  agent_id: string;
  block_devices: StorageSection & { devices?: any[] };
  lvm: StorageSection & { vgs?: any[]; pvs?: any[]; lvs?: any[] };
  vdo: StorageSection & { raw?: string[] };
  zfs: StorageSection & { pools?: any[] };
}

/** J4e: network overview from yoloman.network_interface (gathered). */
export interface NetInterface {
  name: string;
  state: string;
  mtu?: number;
  mac?: string;
  addresses: { family: string; cidr: string }[];
}

export interface NetRoute {
  raw: string;
  dest: string;
  gateway?: string;
  dev?: string;
}

export interface NetworkResponse {
  agent_id: string;
  /** The detected network provider that manages this host's interfaces. */
  provider?: 'networkmanager' | 'netplan' | 'networkd' | 'ifupdown' | 'unknown';
  interfaces: NetInterface[];
  routes: NetRoute[];
  dns: { nameservers?: string[]; search?: string[] };
}

export interface NetworkConfig {
  name: string;
  state?: 'present' | 'absent';
  method?: 'dhcp' | 'static' | 'manual';
  address?: string;
  gateway?: string;
  dns?: string[];
  mtu?: number;
  mac?: string;
  /** Force a provider; omit to let the agent auto-detect. */
  provider?: string;
  dry_run?: boolean;
}

/** Cockpit "Software updates": a single pending package update. */
export interface PackageUpdate {
  name: string;
  current: string;
  candidate: string;
  security: boolean;
}

export interface UpdatesResponse {
  agent_id: string;
  manager: 'apt' | 'dnf' | 'yum' | 'unknown';
  updates: PackageUpdate[];
  count: number;
  /** -1 when the security count could not be determined. */
  security_count: number;
  reboot_required: boolean;
}

/** Virtualization overview from virt_facts. */
export interface VirtResponse {
  agent_id: string;
  hypervisors: string[];
  proxmox: StorageSection & { vms?: any[]; containers?: any[] };
  libvirt: StorageSection & { domains?: any[] };
}
