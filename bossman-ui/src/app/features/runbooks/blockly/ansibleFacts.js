// The variables the Variables panel offers — and ONLY ones that actually resolve on a yolo-man host.
//
// This list is the UI's copy of what `internal/modules/setup.go` returns. It was inherited from awx-ng,
// which listed ~80 entries in the modern `ansible_facts['distribution']` form. Our agent did not emit that
// form at all, so a variable dragged out of the panel silently failed to resolve against the StrictUndefined
// engine. Two things were fixed: setup.go now also emits the nested `ansible_facts` dict, and this list was
// cut down to the facts the agent really gathers.
//
// KEEP IN SYNC with internal/modules/setup.go — if a fact is added there, add it here. A variable listed
// here that the agent does not provide is worse than a missing one: listing it promises that it resolves.

// Bare fact names, exactly as gathered by the `setup` module. The agent exposes each under THREE spellings
// (see setup.go's mirror loop), so the panel offers all three:
//   ansible_facts['<name>']   the modern Ansible form — what imported upstream roles use
//   ansible_<name>            the flat Ansible < 2.5 form
//   yoloman_<name>            our native prefix
const GATHERED = [
  // System identity
  ['hostname', 'Short hostname of the target'],
  ['architecture', 'CPU architecture, e.g. x86_64'],
  ['kernel', 'Kernel release, e.g. 6.17.0-35-generic'],
  ['distribution', 'Linux distribution, e.g. Debian, Ubuntu'],
  ['distribution_version', 'Distribution version, e.g. 24.04'],
  ['os_family', 'OS family, e.g. Debian, RedHat'],
  // Capacity
  ['memtotal_mb', 'Total RAM in MB'],
  ['processor_vcpus', 'Logical CPU count'],
  // Hardware / DMI — what identifies a physical machine (bare-metal provisioning, warranty lookups)
  ['product_name', 'Product/model name from DMI, e.g. PowerEdge R640'],
  ['product_serial', 'Product serial number from DMI (service tag)'],
  ['product_uuid', 'System UUID from DMI'],
  ['system_vendor', 'System vendor from DMI, e.g. Dell Inc.'],
  ['board_vendor', 'Motherboard vendor from DMI'],
  ['board_name', 'Motherboard model from DMI'],
  ['board_serial', 'Motherboard serial from DMI'],
  ['bios_vendor', 'BIOS/UEFI vendor from DMI'],
  ['bios_version', 'BIOS/UEFI version from DMI'],
  ['chassis_vendor', 'Chassis vendor from DMI'],
];

// Runtime variables the ENGINE binds (services/nt_engine + runbook_exec), not the setup module. Only the
// ones we really provide: Ansible's `groups` / `hostvars` / `ansible_play_hosts` are controller concepts we
// have no equivalent for, so they are deliberately absent rather than listed and broken.
const RUNTIME = [
  ['item', 'The current element inside a step with `loop:`'],
  ['inventory_hostname', 'Name of the host the runbook is running against'],
];

// The full HW/SW inventory document, bound as the `inventory` var by services/runbook_exec.py and reached by
// dotted path. The paths below are the ones that file documents; the previous hardcoded UI list had invented
// `inventory.system.serial_number` and `inventory.memory_mb`, which do not exist.
const INVENTORY = [
  ['inventory.product.serial', 'Serial number from the inventory document'],
  ['inventory.cpu.model', 'CPU model from the inventory document'],
  ['inventory.memory.total_mb', 'Total RAM in MB from the inventory document'],
  ['inventory.disks', 'List of disks from the inventory document'],
  ['inventory.nics', 'List of network interfaces from the inventory document'],
];

/** {name, source, preview} — the shape the Variables panel renders. */
const entry = (name, source, preview) => ({ name, source, preview });

/** The modern Ansible form. Listed first because it is what imported roles use. */
export const ANSIBLE_FACT_VARIABLES = GATHERED.map(([bare, preview]) =>
  entry(`ansible_facts['${bare}']`, 'ansible fact', preview),
);

/** Our native prefix, same values. */
export const YOLOMAN_FACT_VARIABLES = GATHERED.map(([bare, preview]) =>
  entry(`yoloman_${bare}`, 'yoloman fact', preview),
);

/** The flat `ansible_<name>` form (Ansible < 2.5), kept as a compat alias by the agent. */
export const ANSIBLE_FLAT_FACT_VARIABLES = GATHERED.map(([bare, preview]) =>
  entry(`ansible_${bare}`, 'ansible fact (flat alias)', preview),
);

export const ANSIBLE_MAGIC_VARIABLES = RUNTIME.map(([name, preview]) =>
  entry(name, 'runtime variable', preview),
);

export const INVENTORY_VARIABLES = INVENTORY.map(([name, preview]) =>
  entry(name, 'inventory document', preview),
);

/** Every built-in variable, in the order the panel shows them. */
export const BUILTIN_VARIABLES = [
  ...ANSIBLE_MAGIC_VARIABLES,
  ...ANSIBLE_FACT_VARIABLES,
  ...YOLOMAN_FACT_VARIABLES,
  ...INVENTORY_VARIABLES,
  ...ANSIBLE_FLAT_FACT_VARIABLES,
];
