/** gpedit-style semantic categories for config files (Block K5). Windows
 * groups settings by what they DO (System, Network, Security…), not by where
 * the file lives — so the host Configuration tree and the OU policy editor
 * group by these categories instead of raw directories. Matching is by full
 * path; first hit wins; unmatched paths land in "Other".
 *
 * The codec registry knows ~2500 config files (every package Debian ships a
 * parser for), so the categories below are deliberately broad — they classify
 * the common infrastructure classes (databases, web, mail, virtualization,
 * clustering, …) an operator actually manages. What remains in "Other" is the
 * genuine long tail of one-off third-party application configs. */

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
    // Auth, PKI, hardening, LDAP/IdM directories, AV.
    match: /(\/ssh\/|sshd_config|\/hosts\.(allow|deny)$|sudoers|\/pam\.d\/|\/sssd|\/security\/|moduli$|krb5|\/selinux\/|fail2ban|apparmor|\/openldap|slapd|\/389|freeipa|\/pki\/|\/ssl\/|certmonger|opendnssec|\/gnupg|clamav|\/keycloak|\/vault|\/oath|\/opensc|\/pkcs11)/,
  },
  {
    key: 'time',
    label: 'Time synchronization',
    icon: 'schedule',
    match: /(chrony|\/ntp|timesyncd|\/adjtime|\/ptp)/,
  },
  {
    key: 'logging',
    label: 'Logging & monitoring',
    icon: 'article',
    // Syslog/journal + metrics/monitoring agents and stacks.
    match: /(rsyslog|syslog|journald|logrotate|logcheck|\/audit|metricbeat|filebeat|\/collectd|telegraf|fluent|logstash|\/nagios|\/icinga|\/munin|\/monit|\/zabbix|\/prometheus|\/grafana|\/netdata)/,
  },
  {
    key: 'network',
    label: 'Network',
    icon: 'lan',
    // Interfaces, name resolution, DNS servers, VPN/tunnels, routing, firewalling.
    match: /(networking|\/network\/|interfaces$|resolv\.conf|nsswitch|netplan|\/hosts$|dhcp|firewalld|nftables|iptables|\/hostname$|\/bind|\/named|unbound|dnsmasq|powerdns|\/knot|wireguard|openvpn|strongswan|\/ppp|\/wpa|hostapd|\/frr|quagga|\/bird|squid|\/ndppd|radvd|\/vlan|\/netctl|\/connman|networkmanager|\/ifplugd|\/tinc|\/zerotier|\/tailscale|\/babeld|\/olsrd|\/mosquitto|\/stunnel|\/socat|\/haproxy)/,
  },
  {
    key: 'web',
    label: 'Web & application servers',
    icon: 'public',
    match: /(apache2|\/httpd|nginx|lighttpd|\/caddy|varnish|traefik|\/php|php-fpm|tomcat|\/uwsgi|gunicorn|request-tracker|\/mediawiki|\/wordpress|\/drupal|\/jetty|\/jenkins|\/gitlab|\/gitea)/,
  },
  {
    key: 'mail',
    label: 'Mail',
    icon: 'mail',
    match: /(postfix|\/exim|dovecot|courier|opendkim|opendmarc|spamassassin|\/mail\/|sendmail|\/mutt|getmail|fetchmail|\/amavis|rspamd|\/postgrey|\/cyrus|\/opensmtpd|\/mailman|\/sympa|\/dkimproxy|\/policyd)/,
  },
  {
    key: 'database',
    label: 'Databases',
    icon: 'database',
    match: /(postgresql|\/mysql|mariadb|\/mongo|\/redis|\/ceph|influx|elastic|cassandra|\/couch|memcached|\/etcd|\/rethinkdb|\/riak|\/pgbouncer|\/barman|\/galera|\/percona|\/clickhouse|\/neo4j|\/arangodb|\/solr|\/sphinx|\/firebird|\/orientdb)/,
  },
  {
    key: 'virt',
    label: 'Virtualization & containers',
    icon: 'dns',
    match: /(\/docker|libvirt|\/lxc|\/lxd|containerd|\/podman|\/qemu|\/kvm|\/vagrant|\/kubelet|\/kubernetes|\/cri-o|\/runc|\/virtualbox|\/xen|\/vmware|\/openvswitch|\/ovn|\/cloud-init|\/cloud\/)/,
  },
  {
    key: 'cloud',
    label: 'Cloud & orchestration',
    icon: 'cloud',
    // OpenStack components + IaC/config-management/service-discovery tooling.
    match: /(neutron|designate|octavia|\/swift|\/nova|keystone|\/glance|\/cinder|\/ironic|\/heat|horizon|openstack|\/manila|\/aodh|\/ceilometer|\/gnocchi|\/magnum|\/trove|\/barbican|\/consul|\/nomad|\/terraform|\/ansible|\/puppet|\/salt|\/chef|\/cumin)/,
  },
  {
    key: 'cluster',
    label: 'Clustering & HA',
    icon: 'hub',
    match: /(corosync|pacemaker|fence_agents|\/drbd|\/slurm|keepalived|heartbeat|\/pcs|\/booth|\/csync2|\/ha\/|\/gluster|\/torque|\/munge|\/globus|\/arc\/)/,
  },
  {
    key: 'telephony',
    label: 'Telephony & mobile',
    icon: 'call',
    match: /(osmocom|nextepc|\/asterisk|freeswitch|kamailio|opensips|\/yate|\/coturn|\/baresip|\/pjsip|open5gs|\/srsran)/,
  },
  {
    key: 'services',
    label: 'Services & scheduling',
    icon: 'schedule_send',
    match: /(\/cron|crontab|\/systemd\/|\/init\.d\/|\/default\/|\/supervisor|\/runit|\/sv\/|\/xinetd|\/inetd|\/rc\.d|\/openrc|\/upstart|\/s6)/,
  },
  {
    key: 'storage',
    label: 'Storage & filesystems',
    icon: 'storage',
    // Block/volume, filesystems, network shares, FTP, backup, encryption.
    match: /(\/lvm|fstab|mdadm|multipath|iscsi|\/nfs|autofs|smartd|\/samba|smb\.conf|\/cifs|\/ftp|pure-ftpd|proftpd|vsftpd|\/rsync|\/borg|\/duplicity|\/zfs|\/btrfs|\/bacula|\/amanda|\/restic|\/snapper|\/cryptsetup|\/crypttab|\/quota)/,
  },
  {
    key: 'packages',
    label: 'Package management',
    icon: 'inventory_2',
    match: /(\/apt|\/dnf|\/yum|zypper|\/dpkg|\/rpm|pacman|\/portage|\/apk|needrestart|unattended-upgrade|debconf|\/flatpak|\/snap)/,
  },
  {
    key: 'boot',
    label: 'Boot & kernel',
    icon: 'memory',
    match: /(\/grub|initramfs-tools|\/dracut|plymouth|\/mkinitcpio|\/kernel|sysctl|modprobe|\/modules-load|\/dkms|\/fwupd|\/refind|\/systemd-boot|\/u-boot|\/uboot)/,
  },
  {
    key: 'desktop',
    label: 'Desktop, display & printing',
    icon: 'desktop_windows',
    match: /(\/xdg|\/X11|\/lomiri|\/gdm|\/lightdm|\/sddm|dbus-1|\/wayland|\/fonts|\/gnome|\/kde|\/plasma|\/cups|\/pulse|pipewire|\/alsa|\/polkit|accountsservice|\/gtk|\/qt5|\/xorg|\/i3|\/sway|\/openbox|\/lxde|\/xfce|\/mate|\/enlightenment|\/redshift|\/foomatic|\/sane|\/colord)/,
  },
  {
    key: 'system',
    label: 'System identity & login',
    icon: 'badge',
    // Identity, locale, shells, login policy, user skeletons.
    match: /(motd|issue|os-release|machine-info|\/locale|environment$|profile$|\/skel|\/sysstat|\/anacron|\/ldconfig|\/updatedb|\/mime|bash\.|\/inputrc|\/vim|\/nano|\/screenrc|\/tmux|\/zsh|\/adduser|\/deluser|\/login\.defs|\/mailcap)/,
  },
  {
    key: 'agent',
    label: 'Agent (agentic-mcp)',
    icon: 'smart_toy',
    match: /agentic-mcp/,
  },
];

const OTHER: ConfigCategory = { key: 'other', label: 'Other applications', icon: 'folder' };

/** Category words the CATALOG uses that this file spells differently or does not list.
 *
 * `package_catalog.json` is written by the catalog builder and the promotion pass, and its vocabulary grew
 * separately: measured, it emits `virtualization` where this file says `virt`, and `monitoring`, `directory`
 * and `backup`, which it has no entry for at all. Those rendered as a generic folder in the wizard.
 *
 * An ALIAS rather than a rename, in both directions of caution: renaming this file's key would break the
 * path->category matching that every editor uses, and rewriting 400 catalog entries to match would put the
 * same word in two places again. The catalog's words are the ones that arrive at the UI, so this is where
 * they are met. */
const KEY_ALIASES: Record<string, string> = {
  virtualization: 'virt',
  monitoring: 'logging',          // this file's entry is labelled "Logging & monitoring"
  containers: 'virt',
};

/** Categories the catalog emits that have no path RULE — so they cannot be matched from a path, only handed
 * over by name. They carry a label and an icon and nothing else. */
const BY_NAME_ONLY: ConfigCategory[] = [
  { key: 'directory', label: 'Directory & identity', icon: 'badge' },
  { key: 'backup', label: 'Backup & recovery', icon: 'backup' },
];

/** A category by its key, or null. The wizard needs the LABEL and ICON for a key it was handed, and it kept
 * its own second table (CAT_META) for that — so a category this file knows about rendered as a generic folder
 * there. One vocabulary, one lookup. */
export function categoryByKey(key: string): ConfigCategory | null {
  const wanted = KEY_ALIASES[key] ?? key;
  return CATEGORIES.find((c) => c.key === wanted)
    ?? BY_NAME_ONLY.find((c) => c.key === wanted)
    ?? (wanted === OTHER.key ? OTHER : null);
}

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
