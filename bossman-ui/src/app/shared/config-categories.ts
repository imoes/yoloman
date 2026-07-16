/** gpedit-style semantic categories for config files (Block K5). Windows
 * groups settings by what they DO (System, Network, Security…), not by where
 * the file lives — so the host Configuration tree and the OU policy editor
 * group by these categories instead of raw directories. Matching is by full
 * path; first hit wins; unmatched paths land in "Other". */

export interface ConfigCategory {
  key: string;
  label: string;
  icon: string;
}

const CATEGORIES: (ConfigCategory & { match: RegExp })[] = [
  {
    key: 'security',
    label: 'Security & access',
    icon: 'security',
    match: /(\/ssh\/|sshd_config|\/hosts\.(allow|deny)$|sudoers|\/pam\.d\/|\/sssd|\/security\/|moduli$|krb5|\/selinux\/|fail2ban)/,
  },
  {
    key: 'time',
    label: 'Time synchronization',
    icon: 'schedule',
    match: /(chrony|ntp|timesyncd)/,
  },
  {
    key: 'logging',
    label: 'Logging & auditing',
    icon: 'article',
    match: /(rsyslog|syslog|journald|logrotate|audit)/,
  },
  {
    key: 'network',
    label: 'Network',
    icon: 'lan',
    match: /(networking|\/network\/|interfaces$|resolv\.conf|nsswitch|netplan|\/hosts$|dhcp|firewalld|nftables|iptables|\/hostname$)/,
  },
  {
    key: 'services',
    label: 'Services & scheduling',
    icon: 'schedule_send',
    match: /(\/cron|crontab|\/systemd\/|\/init\.d\/|\/default\/)/,
  },
  {
    key: 'storage',
    label: 'Storage & filesystems',
    icon: 'storage',
    match: /(\/lvm|fstab|mdadm|multipath|iscsi|nfs|autofs|smartd)/,
  },
  {
    key: 'system',
    label: 'System identity & login',
    icon: 'badge',
    match: /(motd|issue|os-release|machine-info|locale|environment$|profile$)/,
  },
  {
    key: 'agent',
    label: 'Agent (agentic-mcp)',
    icon: 'smart_toy',
    match: /agentic-mcp/,
  },
];

const OTHER: ConfigCategory = { key: 'other', label: 'Other', icon: 'folder' };

export function categorizeConfigPath(path: string): ConfigCategory {
  for (const c of CATEGORIES) if (c.match.test(path)) return c;
  return OTHER;
}

/** Group items carrying a `path` into ordered categories (declaration order,
 * "Other" last); categories with no files are omitted. */
export function groupByCategory<T extends { path: string }>(items: T[]): { cat: ConfigCategory; files: T[] }[] {
  const buckets = new Map<string, { cat: ConfigCategory; files: T[] }>();
  for (const item of items) {
    const cat = categorizeConfigPath(item.path);
    if (!buckets.has(cat.key)) buckets.set(cat.key, { cat, files: [] });
    buckets.get(cat.key)!.files.push(item);
  }
  const order = [...CATEGORIES.map((c) => c.key), OTHER.key];
  return [...buckets.values()]
    .map((b) => ({ ...b, files: [...b.files].sort((a, x) => a.path.localeCompare(x.path)) }))
    .sort((a, b) => order.indexOf(a.cat.key) - order.indexOf(b.cat.key));
}
