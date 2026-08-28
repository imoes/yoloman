# Linux modules — the Ansible-shaped action plane

> **GENERATED** by `scripts/generate-module-docs.py` from what the agent itself publishes
> (`GET /api/v1/tools` on `docker-test.test.ippen.media`), on 2026-08-28. Do not edit by hand: the next run
> overwrites it, and the point of generating it is that this page cannot disagree with the agents.

## What this is

Every module this platform's agent exposes **right now**, with the parameters the module itself
declares. A module is the unit a runbook step, a console action and an MCP tool call all use — the same
name, the same parameters, on every host of this platform.

**84 modules**: 61 that change the host, 23 that only read it.

Two rules hold for all of them, and they are why the tables below are worth reading rather than
skimming:

1. **Every write module is idempotent and previewable.** It reads the host first, compares, and reports
   `changed: false` when nothing had to happen. `dry_run: true` returns the plan instead of applying it.
2. **The target's own words are passed through, not mapped.** Where Windows says `InstallState:
   Removed` or `RestartNeeded: Maybe`, that is what the module reports — a boolean would have to invent
   one of two lies.

The other platform's page: [Windows modules](modules-windows.md).

## The module catalogue is a different thing

Bossman also holds an Ansible-compatible module **catalogue** — 2128 specs,
693 of them translated into executable form (`GET /api/v1/modules`).
That is a library of specifications; this page is what an agent will execute if you call it today. The
two are deliberately not added together: one impressive number would answer neither question.

## Modules that change the host

### `apt`

Ensure one or more Debian packages are present, absent, or upgraded to the latest available version, via dpkg/apt-get. Idempotent: queries dpkg's current status (and, for state=latest, apt-cache's candidate version — a read-only query, safe to run even under check_mode) before deciding whether to act. Debian/Ubuntu only in v1. Supports check_mode via dry_run=true (queries state but issues no apt-get mutation).

Cross-tool equivalents:
- Ansible: ansible.builtin.apt. Same name/state/update_cache parameter names (name accepts either a single package or a list); v1 is a focused subset — Ansible's apt also supports upgrade, autoremove, deb, and more, not yet implemented here.
- Chef: the `apt_package` resource — `action :install`/`:remove`/`:upgrade`.
- Puppet: the `package` type with `provider => apt` — `ensure => present`/`absent`/`latest`.
- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.
- Terraform: not applicable — Terraform does not manage OS packages on a running host; this would normally be done via a provisioner or left to configuration management entirely.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["nginx"] or ["nginx", "curl=8.5.0-2ubuntu10"] (an "=version" suffix pins a specific version for state=present). |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating apt-get command (check_mode). |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |
| `update_cache` | boolean | — | Whether to run `apt-get update` before evaluating package state. Default false. |

### `apt_key`

Ensure an APT signing key is present or absent, identified by `id` (used as the keyring filename). Provide the key as armored text via `data`, or fetch it from `url`. Implemented via `gpg --dearmor` writing to /etc/apt/trusted.gpg.d/<id>.gpg rather than the `apt-key` command itself, which upstream Debian/Ubuntu have deprecated and removed from newer releases — this is the same replacement approach Debian's own release notes recommend. Idempotent — only writes when the dearmored key bytes differ from the keyring file's current content. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.apt_key. Ansible's own module is itself marked deprecated for the same reason (apt-key removal); same id/data/url/state parameter names.
- Chef: the `apt_repository` resource's `key` property, or a `execute` resource wrapping `gpg --dearmor`.
- Puppet: the puppetlabs-apt module's `apt::key` type.
- Salt: the `pkgrepo.managed` state's `key_url`/`aptkey_id` handling.
- Terraform: not applicable — Terraform does not manage a running host's package manager trust store.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `id` | string | yes | Key identifier, used as the keyring filename (<id>.gpg), e.g. "docker". |
| `data` | string | — | Armored (ASCII) key text. Mutually exclusive with url. Required for state=present unless url is given. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `state` | one of `present`, `absent` | — | Whether the key should be present or absent. Default "present". |
| `url` | string | — | URL to fetch the armored key from. Mutually exclusive with data. |

### `apt_repository`

Ensure a one-line APT source entry (e.g. "deb https://example.com/repo stable main") is present or absent in /etc/apt/sources.list.d/<filename>.list. Idempotent — only writes when the exact line isn't already there (state=present) or is there (state=absent). Optionally runs `apt-get update` afterward when update_cache=true and something changed. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.apt_repository. Similar repo/state/update_cache semantics — a focused subset: `filename` is required here rather than auto-derived, and state=absent only searches the given file rather than every configured source file.
- Chef: the `apt_repository` resource (part of the apt cookbook).
- Puppet: the puppetlabs-apt module's `apt::source` type.
- Salt: the `pkgrepo.managed`/`pkgrepo.absent` states.
- Terraform: not applicable — Terraform does not manage a running host's package manager configuration.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `filename` | string | yes | Target file name (without .list) under /etc/apt/sources.list.d/, e.g. "myrepo". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `repo` | string | — | The full one-line source entry, e.g. "deb https://example.com/repo stable main". Required for state=present. |
| `state` | one of `present`, `absent` | — | Whether the entry should be present or absent. Default "present". |
| `update_cache` | boolean | — | When true and something changed, run apt-get update afterward. Default false. |

### `assemble`

Concatenate every file in a source directory — sorted by filename, optionally filtered to names matching a regexp — into a single destination file. The classic use case is a conf.d-style fragment directory (e.g. /etc/myapp/conf.d/*.conf) assembled into the application's single real config file. Idempotent — only writes dest when the assembled content actually differs from what's already there. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.assemble. Same src/dest/regexp/delimiter/owner/group/mode semantics (a focused subset — Ansible also supports remote_src=false to assemble from the control node, not applicable here since there is no separate control-node filesystem in this agent's single-host model; ignore_hidden/validate not yet implemented).
- Chef: no single built-in resource; typically hand-rolled by reading a directory glob and writing a `file` resource's content in a custom recipe/library.
- Puppet: no core equivalent; the `concat` module (puppetlabs-concat) provides the same fragment-directory-to-single-file pattern.
- Salt: no single built-in state; typically composed with Jinja `{% include %}`/glob logic inside a `file.managed` template, or a custom module.
- Terraform: not applicable — no file-fragment-assembly primitive.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination file to write the assembled content to, e.g. "/etc/myapp/myapp.conf". |
| `src` | string | yes | Source directory of fragment files, e.g. "/etc/myapp/conf.d". |
| `delimiter` | string | — | Optional string inserted between fragments. Default: none. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `group` | string | — | Optional desired group (group name or numeric gid) for dest. |
| `mode` | string | — | Optional desired permission mode for dest as an octal string, e.g. "0644". |
| `owner` | string | — | Optional desired owner (username or numeric uid) for dest. |
| `regexp` | string | — | Optional RE2 regular expression; only filenames matching it are included. Default: all files. |

### `blockinfile`

Insert, update, or remove a multi-line block of text surrounded by marker comments in a file, without touching the rest of the file's content — the block is identified by its markers, so re-running with different content replaces the old block in place rather than appending a duplicate. If the markers aren't found yet, the block (with markers) is appended at the end of the file. Idempotent — a repeat call with the same content reports changed=false. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.blockinfile. Same path/block/state/marker/create semantics (a focused subset — Ansible also supports insertafter/insertbefore/backup, not yet implemented here; a missing block is always appended at end of file).
- Chef: no single built-in resource; typically hand-rolled with Ruby string manipulation in a custom resource.
- Puppet: no core equivalent; third-party modules (e.g. augeasproviders) or puppetlabs-stdlib's `file_line` used repeatedly approximate it.
- Salt: the `file.blockreplace` state — nearly identical marker-comment-block model.
- Terraform: not applicable — no line/block-level file-editing primitive.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | File to edit, e.g. "/etc/ssh/sshd_config". |
| `block` | string | — | The desired block content, without markers. Required for state=present. |
| `create` | boolean | — | For state=present: if the file does not exist, create it instead of failing. Default false. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `marker` | string | — | Marker line template; the literal "{mark}" is replaced with BEGIN/END. Default "# {mark} ANSIBLE MANAGED BLOCK". |
| `state` | one of `present`, `absent` | — | Whether the block should be present or absent. Default "present". |

### `command`

Run an arbitrary command with no shell involved — no pipes, redirects, globbing, or variable substitution, exactly like ansible.builtin.command (use the agent's separate pipeline tool, not this one, when you actually need `cmd1 | cmd2`). Provide either `cmd` (a plain command line, split on whitespace — no quoting support) or the explicit `argv` array (preferred whenever an argument contains spaces or special characters). Returns rc/stdout/stderr; **a non-zero rc is not raised as a tool error** — check data.rc yourself to determine success. This module cannot verify idempotency for an arbitrary command, so it always reports changed=true once it actually runs; under check_mode (dry_run=true) it does not run at all and reports changed=true as a prediction only, matching Ansible's default of skipping command/shell tasks during --check.

Cross-tool equivalents:
- Ansible: ansible.builtin.command (and, for genuinely shell-requiring cases, ansible.builtin.shell — not implemented here; use the pipeline tool instead).
- Chef: the `execute` resource.
- Puppet: the `exec` type.
- Salt: the `cmd.run` execution module / `cmd.run` state.
- Terraform: a `null_resource` with a `local-exec`/`remote-exec` provisioner.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `argv` | array of string | — | Explicit argument vector, e.g. ["mkdir", "-p", "/opt/my app"] — required whenever an argument contains spaces. Mutually exclusive with cmd. |
| `chdir` | string | — | Optional working directory to run the command in. |
| `cmd` | string | — | Plain command line, split on whitespace (no quoting), e.g. "systemctl daemon-reload". Mutually exclusive with argv. |
| `dry_run` | boolean | — | When true, do not execute the command at all; report changed=true as a prediction only (check_mode). |

### `community.general.filesystem`

Makes a filesystem

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dev` | string | yes | Target path to block device (Linux) or character device (FreeBSD) or regular file (both). When setting Linux-specific filesystem types on FreeBSD, this module only works when applying to regular files, aka disk images. Currently V(lvm) (Linux-only) and V(ufs) (FreeBSD-only) do not support a regular file as their target O(dev). Support for character devices on FreeBSD has been added in community.general 3.4.0. |
| `force` | boolean | — | If V(true), allows to create new filesystem on devices that already has filesystem. |
| `fstype` | one of `btrfs`, `ext2`, `ext3`, `ext4`, `ext4dev`, `f2fs`, `lvm`, `ocfs2`, `reiserfs`, `xfs`, `vfat`, `swap`, `ufs` | — | Filesystem type to be created. This option is required with O(state=present) (or if O(state) is omitted). ufs support has been added in community.general 3.4.0. |
| `opts` | string | — | List of options to be passed to C(mkfs) command. |
| `resizefs` | boolean | — | If V(true), if the block device and filesystem size differ, grow the filesystem into the space. Supported for C(btrfs), C(ext2), C(ext3), C(ext4), C(ext4dev), C(f2fs), C(lvm), C(xfs), C(ufs) and C(vfat) filesystems. Attempts to resize other filesystem types will fail. XFS Will only grow if mounted. Currently, the module is based on commands from C(util-linux) package to perform operations, so resizing of XFS is not supported on FreeBSD systems. vFAT will likely fail if C(fatresize < 1.04). Mutually exclusive with O(uuid). |
| `state` | one of `present`, `absent` | — | If O(state=present), the filesystem is created if it doesn't already exist, that is the default behaviour if O(state) is omitted. If O(state=absent), filesystem signatures on O(dev) are wiped if it contains a filesystem (as known by C(blkid)). When O(state=absent), all other options but O(dev) are ignored, and the module does not fail if the device O(dev) doesn't actually exist. |
| `uuid` | string | — | Set filesystem's UUID to the given value. The UUID options specified in O(opts) take precedence over this value. See xfs_admin(8) (C(xfs)), tune2fs(8) (C(ext2), C(ext3), C(ext4), C(ext4dev)) for possible values. For O(fstype=lvm) the value is ignored, it resets the PV UUID if set. Supported for O(fstype) being one of C(ext2), C(ext3), C(ext4), C(ext4dev), C(lvm), or C(xfs). This is B(not idempotent). Specifying this option will always result in a change. Mutually exclusive with O(resizefs). |

### `community.general.lvg`

Configure LVM volume groups

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `vg` | string | yes | The name of the volume group. |
| `force` | boolean | — | If V(true), allows to remove volume group with logical volumes. |
| `pesize` | string | — | The size of the physical extent. O(pesize) must be a power of 2 of at least 1 sector (where the sector size is the largest sector size of the PVs currently used in the VG), or at least 128KiB. O(pesize) can be optionally suffixed by a UNIT (k/K/m/M/g/G), default unit is megabyte. |
| `pv_options` | string | — | Additional options to pass to C(pvcreate) when creating the volume group. |
| `pvresize` | boolean | — | If V(true), resize the physical volume to the maximum available size. |
| `pvs` | array of string | — | List of comma-separated devices to use as physical devices in this volume group. Required when creating or resizing volume group. The module will take care of running pvcreate if needed. |
| `reset_pv_uuid` | boolean | — | Whether the volume group's physical volumes' UUIDs are regenerated. This is B(not idempotent). Specifying this parameter always results in a change. |
| `reset_vg_uuid` | boolean | — | Whether the volume group's UUID is regenerated. This is B(not idempotent). Specifying this parameter always results in a change. |
| `state` | one of `absent`, `present`, `active`, `inactive` | — | Control if the volume group exists and it's state. The states V(active) and V(inactive) implies V(present) state. Added in 7.1.0 If V(active) or V(inactive), the module manages the VG's logical volumes current state. The module also handles the VG's autoactivation state if supported unless when creating a volume group and the autoactivation option specified in O(vg_options). |
| `vg_options` | string | — | Additional options to pass to C(vgcreate) when creating the volume group. |

### `community.general.lvol`

Configure LVM logical volumes

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `vg` | string | yes | The volume group this logical volume is part of. |
| `active` | boolean | — | Whether the volume is active and visible to the host. |
| `force` | boolean | — | Shrink or remove operations of volumes requires this switch. Ensures that that filesystems get never corrupted/destroyed by mistake. |
| `lv` | string | — | The name of the logical volume. |
| `opts` | string | — | Free-form options to be passed to the lvcreate command. |
| `pvs` | array of string | — | List of physical volumes (for example V(/dev/sda, /dev/sdb)). |
| `resizefs` | boolean | — | Resize the underlying filesystem together with the logical volume. Supported for C(ext2), C(ext3), C(ext4), C(reiserfs) and C(XFS) filesystems. Attempts to resize other filesystem types will fail. |
| `shrink` | boolean | — | Shrink if current size is higher than size requested. |
| `size` | string | — | The size of the logical volume, according to lvcreate(8) --size, by default in megabytes or optionally with one of [bBsSkKmMgGtTpPeE] units; or according to lvcreate(8) --extents as a percentage of [VG\|PVS\|FREE\|ORIGIN]; Float values must begin with a digit. When resizing, apart from specifying an absolute size you may, according to lvextend(8)\|lvreduce(8) C(--size), specify the amount to extend the logical volume with the prefix V(+) or the amount to reduce the logical volume by with prefix V(-). Resizing using V(+) or V(-) was not supported prior to community.general 3.0.0. Please note that when using V(+), V(-), or percentage of FREE, the module is B(not idempotent). |
| `snapshot` | string | — | The name of a snapshot volume to be configured. When creating a snapshot volume, the O(lv) parameter specifies the origin volume. |
| `state` | one of `absent`, `present` | — | Control if the logical volume exists. If V(present) and the volume does not already exist then the O(size) option is required. |
| `thinpool` | string | — | The thin pool volume name. When you want to create a thin provisioned volume, specify a thin pool volume name. |

### `community.general.nmcli`

Manage Networking

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `conn_name` | string | yes | The name used to call the connection. Pattern is <type>[-<ifname>][-<num>]. |
| `state` | one of `absent`, `present` | yes | Whether the device should exist or not, taking action if the state is different from what is stated. |
| `addr_gen_mode6` | one of `default`, `default-or-eui64`, `eui64`, `stable-privacy` | — | Configure method for creating the address for use with IPv6 Stateless Address Autoconfiguration. V(default) and V(default-or-eui64) have been added in community.general 6.5.0. |
| `ageingtime` | integer | — | This is only used with bridge - [ageing-time <0-1000000>] the Ethernet MAC address aging time, in seconds. |
| `arp_interval` | integer | — | This is only used with bond - ARP interval. |
| `arp_ip_target` | string | — | This is only used with bond - ARP IP target. |
| `autoconnect` | boolean | — | Whether the connection should start on boot. Whether the connection profile can be automatically activated |
| `dhcp_client_id` | string | — | DHCP Client Identifier sent to the DHCP server. |
| `dns4` | array of string | — | A list of up to 3 DNS servers. The entries must be IPv4 addresses, for example V(192.0.2.53). |
| `dns4_ignore_auto` | boolean | — | Ignore automatically configured IPv4 name servers. |
| `dns4_options` | array of string | — | A list of DNS options. |
| `dns4_search` | array of string | — | A list of DNS search domains. |
| `dns6` | array of string | — | A list of up to 3 DNS servers. The entries must be IPv6 addresses, for example V(2001:4860:4860::8888). |
| `dns6_ignore_auto` | boolean | — | Ignore automatically configured IPv6 name servers. |
| `dns6_options` | array of string | — | A list of DNS options. |
| `dns6_search` | array of string | — | A list of DNS search domains. |
| `downdelay` | integer | — | This is only used with bond - downdelay. |
| `egress` | string | — | This is only used with VLAN - VLAN egress priority mapping. |
| `flags` | string | — | This is only used with VLAN - flags. |
| `forwarddelay` | integer | — | This is only used with bridge - [forward-delay <2-30>] STP forwarding delay, in seconds. |
| `gsm` | object | — | The configuration of the GSM connection. Note the list of suboption attributes may vary depending on which version of NetworkManager/nmcli is installed on the host. An up-to-date list of supported attributes can be found here: U(https://networkmanager.dev/docs/api/latest/settings-gsm.html). For instance to use apn, pin, username and password: V({apn: provider.apn, pin: 1234, username: apn.username, password: apn.password}). |
| `gw4` | string | — | The IPv4 gateway for this interface. Use the format V(192.0.2.1). This parameter is mutually_exclusive with never_default4 parameter. |
| `gw4_ignore_auto` | boolean | — | Ignore automatically configured IPv4 routes. |
| `gw6` | string | — | The IPv6 gateway for this interface. Use the format V(2001:db8::1). |
| `gw6_ignore_auto` | boolean | — | Ignore automatically configured IPv6 routes. |
| `hairpin` | boolean | — | This is only used with 'bridge-slave' - 'hairpin mode' for the slave, which allows frames to be sent back out through the slave the frame was received on. The default change to V(false) in community.general 7.0.0. It used to be V(true) before. |
| `hellotime` | integer | — | This is only used with bridge - [hello-time <1-10>] STP hello time, in seconds. |
| `ifname` | string | — | The interface to bind the connection to. The connection will only be applicable to this interface name. A special value of V('*') can be used for interface-independent connections. The ifname argument is mandatory for all connection types except bond, team, bridge, vlan and vpn. This parameter defaults to O(conn_name) when left unset for all connection types except vpn that removes it. |
| `ignore_unsupported_suboptions` | boolean | — | Ignore suboptions which are invalid or unsupported by the version of NetworkManager/nmcli installed on the host. Only O(wifi) and O(wifi_sec) options are currently affected. |
| `ingress` | string | — | This is only used with VLAN - VLAN ingress priority mapping. |
| `ip4` | array of string | — | List of IPv4 addresses to this interface. Use the format V(192.0.2.24/24) or V(192.0.2.24). If defined and O(method4) is not specified, automatically set C(ipv4.method) to V(manual). |
| `ip6` | array of string | — | List of IPv6 addresses to this interface. Use the format V(abbe::cafe/128) or V(abbe::cafe). If defined and O(method6) is not specified, automatically set C(ipv6.method) to V(manual). |
| `ip_privacy6` | one of `disabled`, `prefer-public-addr`, `prefer-temp-addr`, `unknown` | — | If enabled, it makes the kernel generate a temporary IPv6 address in addition to the public one. |
| `ip_tunnel_dev` | string | — | This is used with GRE/IPIP/SIT - parent device this GRE/IPIP/SIT tunnel, can use ifname. |
| `ip_tunnel_input_key` | string | — | The key used for tunnel input packets. Only used when O(type=gre). |
| `ip_tunnel_local` | string | — | This is used with GRE/IPIP/SIT - GRE/IPIP/SIT local IP address. |
| `ip_tunnel_output_key` | string | — | The key used for tunnel output packets. Only used when O(type=gre). |
| `ip_tunnel_remote` | string | — | This is used with GRE/IPIP/SIT - GRE/IPIP/SIT destination IP address. |
| `mac` | string | — | MAC address of the connection. Note this requires a recent kernel feature, originally introduced in 3.15 upstream kernel. |
| `macvlan` | object | — | The configuration of the MAC VLAN connection. Note the list of suboption attributes may vary depending on which version of NetworkManager/nmcli is installed on the host. An up-to-date list of supported attributes can be found here: U(https://networkmanager.dev/docs/api/latest/settings-macvlan.html). |
| `master` | string | — | Master <master (ifname, or connection UUID or conn_name) of bridge, team, bond master connection profile. Mandatory if O(slave_type) is defined. |
| `maxage` | integer | — | This is only used with bridge - [max-age <6-42>] STP maximum message age, in seconds. |
| `may_fail4` | boolean | — | If you need O(ip4) configured before C(network-online.target) is reached, set this option to V(false). This option applies when O(method4) is not V(disabled). |
| `method4` | one of `auto`, `link-local`, `manual`, `shared`, `disabled` | — | Configuration method to be used for IPv4. If O(ip4) is set, C(ipv4.method) is automatically set to V(manual) and this parameter is not needed. |
| `method6` | one of `ignore`, `auto`, `dhcp`, `link-local`, `manual`, `shared`, `disabled` | — | Configuration method to be used for IPv6 If O(ip6) is set, C(ipv6.method) is automatically set to V(manual) and this parameter is not needed. V(disabled) was added in community.general 3.3.0. |
| `miimon` | integer | — | This is only used with bond - miimon. This parameter defaults to V(100) when unset. |
| `mode` | one of `802.3ad`, `active-backup`, `balance-alb`, `balance-rr`, `balance-tlb`, `balance-xor`, `broadcast` | — | This is the type of device or network connection that you wish to create for a bond or bridge. |
| `mtu` | integer | — | The connection MTU, e.g. 9000. This can't be applied when creating the interface and is done once the interface has been created. Can be used when modifying Team, VLAN, Ethernet (Future plans to implement wifi, gsm, pppoe, infiniband) This parameter defaults to V(1500) when unset. |
| `never_default4` | boolean | — | Set as default route. This parameter is mutually_exclusive with gw4 parameter. |
| `path_cost` | integer | — | This is only used with 'bridge-slave' - [<1-65535>] - STP port cost for destinations via this slave. |
| `primary` | string | — | This is only used with bond and is the primary interface name (for "active-backup" mode), this is the usually the 'ifname'. |
| `priority` | integer | — | This is only used with 'bridge' - sets STP priority. |
| `route_metric4` | integer | — | Set metric level of ipv4 routes configured on interface. |
| `route_metric6` | integer | — | Set metric level of IPv6 routes configured on interface. |
| `routes4` | array of string | — | The list of IPv4 routes. Use the format V(192.0.3.0/24 192.0.2.1). To specify more complex routes, use the O(routes4_extended) option. |
| `routes4_extended` | array of string | — | The list of IPv4 routes. |
| `routes6` | array of string | — | The list of IPv6 routes. Use the format V(fd12:3456:789a:1::/64 2001:dead:beef::1). To specify more complex routes, use the O(routes6_extended) option. |
| `routes6_extended` | array of string | — | The list of IPv6 routes but with parameters. |
| `routing_rules4` | array of string | — | Is the same as in an C(ip rule add) command, except always requires specifying a priority. |
| `runner` | one of `broadcast`, `roundrobin`, `activebackup`, `loadbalance`, `lacp` | — | This is the type of device or network connection that you wish to create for a team. |
| `runner_fast_rate` | boolean | — | Option specifies the rate at which our link partner is asked to transmit LACPDU packets. If this is V(true) then packets will be sent once per second. Otherwise they will be sent every 30 seconds. Only allowed for O(runner=lacp). |
| `runner_hwaddr_policy` | one of `same_all`, `by_active`, `only_active` | — | This defines the policy of how hardware addresses of team device and port devices should be set during the team lifetime. |
| `slave_type` | one of `bond`, `bridge`, `team` | — | Type of the device of this slave's master connection (for example V(bond)). |
| `slavepriority` | integer | — | This is only used with 'bridge-slave' - [<0-63>] - STP priority of this slave. |
| `ssid` | string | — | Name of the Wireless router or the access point. |
| `stp` | boolean | — | This is only used with bridge and controls whether Spanning Tree Protocol (STP) is enabled for this bridge. |
| `transport_mode` | one of `datagram`, `connected` | — | This option sets the connection type of Infiniband IPoIB devices. |
| `type` | one of `bond`, `bond-slave`, `bridge`, `bridge-slave`, `dummy`, `ethernet`, `generic`, `gre`, `infiniband`, `ipip`, `macvlan`, `sit`, `team`, `team-slave`, `vlan`, `vxlan`, `wifi`, `gsm`, `wireguard`, `vpn`, `loopback` | — | This is the type of device or network connection that you wish to create or modify. Type V(dummy) is added in community.general 3.5.0. Type V(gsm) is added in community.general 3.7.0. Type V(infiniband) is added in community.general 2.0.0. Type V(loopback) is added in community.general 8.1.0. Type V(macvlan) is added in community.general 6.6.0. Type V(wireguard) is added in community.general 4.3.0. Type V(vpn) is added in community.general 5.1.0. Using V(bond-slave), V(bridge-slave), or V(team-slave) implies V(ethernet) connection type with corresponding O(slave_type) option. If you want to control non-ethernet connection attached to V(bond), V(bridge), or V(team) consider using O(slave_type) option. |
| `updelay` | integer | — | This is only used with bond - updelay. |
| `vlandev` | string | — | This is only used with VLAN - parent device this VLAN is on, can use ifname. |
| `vlanid` | integer | — | This is only used with VLAN - VLAN ID in range <0-4095>. |
| `vpn` | object | — | Configuration of a VPN connection (PPTP and L2TP). In order to use L2TP you need to be sure that C(network-manager-l2tp) - and C(network-manager-l2tp-gnome) if host has UI - are installed on the host. |
| `vxlan_id` | integer | — | This is only used with VXLAN - VXLAN ID. |
| `vxlan_local` | string | — | This is only used with VXLAN - VXLAN local IP address. |
| `vxlan_remote` | string | — | This is only used with VXLAN - VXLAN destination IP address. |
| `wifi` | object | — | The configuration of the WiFi connection. Note the list of suboption attributes may vary depending on which version of NetworkManager/nmcli is installed on the host. An up-to-date list of supported attributes can be found here: U(https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html). For instance to create a hidden AP mode WiFi connection: V({hidden: true, mode: ap}). |
| `wifi_sec` | object | — | The security configuration of the WiFi connection. Note the list of suboption attributes may vary depending on which version of NetworkManager/nmcli is installed on the host. An up-to-date list of supported attributes can be found here: U(https://networkmanager.dev/docs/api/latest/settings-802-11-wireless-security.html). For instance to use common WPA-PSK auth with a password: V({key-mgmt: wpa-psk, psk: my_password}). |
| `wireguard` | object | — | The configuration of the Wireguard connection. Note the list of suboption attributes may vary depending on which version of NetworkManager/nmcli is installed on the host. An up-to-date list of supported attributes can be found here: U(https://networkmanager.dev/docs/api/latest/settings-wireguard.html). For instance to configure a listen port: V({listen-port: 12345}). |
| `xmit_hash_policy` | string | — | This is only used with bond - xmit_hash_policy type. |
| `zone` | string | — | The trust level of the connection. When updating this property on a currently activated connection, the change takes effect immediately. |

### `community.general.parted`

Configure block device partitions

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `device` | string | yes | The block device (disk) where to operate. Regular files can also be partitioned, but it is recommended to create a loopback device using C(losetup) to easily access its partitions. |
| `align` | one of `cylinder`, `minimal`, `none`, `optimal`, `undefined` | — | Set alignment for newly created partitions. Use V(undefined) for parted default alignment. |
| `flags` | array of string | — | A list of the flags that has to be set on the partition. |
| `fs_type` | string | — | If specified and the partition does not exist, will set filesystem type to given partition. Parameter optional, but see notes below about negative O(part_start) values. |
| `label` | one of `aix`, `amiga`, `bsd`, `dvh`, `gpt`, `loop`, `mac`, `msdos`, `pc98`, `sun` | — | Disk label type or partition table to use. If O(device) already contains a different label, it will be changed to O(label) and any previous partitions will be lost. A O(name) must be specified for a V(gpt) partition table. |
| `name` | string | — | Sets the name for the partition number (GPT, Mac, MIPS and PC98 only). |
| `number` | integer | — | The partition number being affected. Required when performing any action on the disk, except fetching information. |
| `part_end` | string | — | Where the partition will end as offset from the beginning of the disk, that is, the "distance" from the start of the disk. Negative numbers specify distance from the end of the disk. The distance can be specified with all the units supported by parted (except compat) and it is case sensitive, for example V(10GiB), V(15%). |
| `part_start` | string | — | Where the partition will start as offset from the beginning of the disk, that is, the "distance" from the start of the disk. Negative numbers specify distance from the end of the disk. The distance can be specified with all the units supported by parted (except compat) and it is case sensitive, for example V(10GiB), V(15%). Using negative values may require setting of O(fs_type) (see notes). |
| `part_type` | one of `extended`, `logical`, `primary` | — | May be specified only with O(label=msdos) or O(label=dvh). Neither O(part_type) nor O(name) may be used with O(label=sun). |
| `resize` | boolean | — | Call C(resizepart) on existing partitions to match the size specified by O(part_end). |
| `state` | one of `absent`, `present`, `info` | — | Whether to create or delete a partition. If set to V(info) the module will only return the device information. |
| `unit` | one of `s`, `B`, `KB`, `KiB`, `MB`, `MiB`, `GB`, `GiB`, `TB`, `TiB`, `%`, `cyl`, `chs`, `compact` | — | Selects the current default unit that Parted will use to display locations and capacities on the disk and to interpret those given by the user if they are not suffixed by an unit. When fetching information about a disk, it is recommended to always specify a unit. |

### `community.general.vdo`

Module to control VDO

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The name of the VDO volume. |
| `ackthreads` | string | — | Specifies the number of threads to use for acknowledging completion of requested VDO I/O operations. Valid values are integer values from 1 to 100 (lower numbers are preferable due to overhead).  The default is 1.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `activated` | boolean | — | The "activate" status for a VDO volume.  If this is set to V(false), the VDO volume cannot be started, and it will not start on system startup.  However, on initial creation, a VDO volume with "activated" set to "off" will be running, until stopped.  This is the default behavior of the "vdo create" command; it provides the user an opportunity to write a base amount of metadata (filesystem, LVM headers, etc.) to the VDO volume prior to stopping the volume, and leaving it deactivated until ready to use. |
| `biothreads` | string | — | Specifies the number of threads to use for submitting I/O operations to the storage device.  Valid values are integer values from 1 to 100 (lower numbers are preferable due to overhead).  The default is 4. Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `blockmapcachesize` | string | — | The amount of memory allocated for caching block map pages, in megabytes (or may be issued with an LVM-style suffix of K, M, G, or T).  The default (and minimum) value is 128M.  The value specifies the size of the cache; there is a 15% memory usage overhead. Each 1.25G of block map covers 1T of logical blocks, therefore a small amount of block map cache memory can cache a significantly large amount of block map data.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `compression` | one of `disabled`, `enabled` | — | Configures whether compression is enabled.  The default for a created volume is 'enabled'.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `cputhreads` | string | — | Specifies the number of threads to use for CPU-intensive work such as hashing or compression.  Valid values are integer values from 1 to 100 (lower numbers are preferable due to overhead).  The default is 2. Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `deduplication` | one of `disabled`, `enabled` | — | Configures whether deduplication is enabled.  The default for a created volume is 'enabled'.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `device` | string | — | The full path of the device to use for VDO storage. This is required if "state" is "present". |
| `emulate512` | boolean | — | Enables 512-byte emulation mode, allowing drivers or filesystems to access the VDO volume at 512-byte granularity, instead of the default 4096-byte granularity. Default is 'disabled'; only recommended when a driver or filesystem requires 512-byte sector level access to a device.  This option is only available when creating a new volume, and cannot be changed for an existing volume. |
| `force` | boolean | — | When creating a volume, ignores any existing file system or VDO signature already present in the storage device. When stopping or removing a VDO volume, first unmounts the file system stored on the device if mounted. B(Warning:) Since this parameter removes all safety checks it is important to make sure that all parameters provided are accurate and intentional. |
| `growphysical` | boolean | — | Specifies whether to attempt to execute a growphysical operation, if there is enough unused space on the device.  A growphysical operation will be executed if there is at least 64 GB of free space, relative to the previous physical size of the affected VDO volume. |
| `indexmem` | string | — | Specifies the amount of index memory in gigabytes.  The default is 0.25.  The special decimal values 0.25, 0.5, and 0.75 can be used, as can any positive integer. This option is only available when creating a new volume, and cannot be changed for an existing volume. |
| `indexmode` | one of `dense`, `sparse` | — | Specifies the index mode of the Albireo index.  The default is 'dense', which has a deduplication window of 1 GB of index memory per 1 TB of incoming data, requiring 10 GB of index data on persistent storage. The 'sparse' mode has a deduplication window of 1 GB of index memory per 10 TB of incoming data, but requires 100 GB of index data on persistent storage.  This option is only available when creating a new volume, and cannot be changed for an existing volume. |
| `logicalsize` | string | — | The logical size of the VDO volume (in megabytes, or LVM suffix format).  If not specified for a new volume, this defaults to the same size as the underlying storage device, which is specified in the 'device' parameter. Existing volumes will maintain their size if the logicalsize parameter is not specified, or is smaller than or identical to the current size.  If the specified size is larger than the current size, a growlogical operation will be performed. |
| `logicalthreads` | string | — | Specifies the number of threads across which to subdivide parts of the VDO processing based on logical block addresses.  Valid values are integer values from 1 to 100 (lower numbers are preferable due to overhead). The default is 1.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `physicalthreads` | string | — | Specifies the number of threads across which to subdivide parts of the VDO processing based on physical block addresses.  Valid values are integer values from 1 to 16 (lower numbers are preferable due to overhead). The physical space used by the VDO volume must be larger than (slabsize * physicalthreads).  The default is 1.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |
| `readcache` | one of `disabled`, `enabled` | — | Enables or disables the read cache.  The default is 'disabled'.  Choosing 'enabled' enables a read cache which may improve performance for workloads of high deduplication, read workloads with a high level of compression, or on hard disk storage.  Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. The read cache feature is available in VDO 6.1 and older. |
| `readcachesize` | string | — | Specifies the extra VDO device read cache size in megabytes.  This is in addition to a system-defined minimum.  Using a value with a suffix of K, M, G, or T is optional.  The default value is 0.  1.125 MB of memory per bio thread will be used per 1 MB of read cache specified (for example, a VDO volume configured with 4 bio threads will have a read cache memory usage overhead of 4.5 MB per 1 MB of read cache specified). Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. The read cache feature is available in VDO 6.1 and older. |
| `running` | boolean | — | Whether this VDO volume is running. A VDO volume must be activated in order to be started. |
| `slabsize` | string | — | The size of the increment by which the physical size of a VDO volume is grown, in megabytes (or may be issued with an LVM-style suffix of K, M, G, or T).  Must be a power of two between 128M and 32G.  The default is 2G, which supports volumes having a physical size up to 16T. The maximum, 32G, supports a physical size of up to 256T. This option is only available when creating a new volume, and cannot be changed for an existing volume. |
| `state` | one of `absent`, `present` | — | Whether this VDO volume should be "present" or "absent". If a "present" VDO volume does not exist, it will be created.  If a "present" VDO volume already exists, it will be modified, by updating the configuration, which will take effect when the VDO volume is restarted. Not all parameters of an existing VDO volume can be modified; the "statusparamkeys" list contains the parameters that can be modified after creation. If an "absent" VDO volume does not exist, it will not be removed. |
| `writepolicy` | one of `async`, `auto`, `sync` | — | Specifies the write policy of the VDO volume.  The 'sync' mode acknowledges writes only after data is on stable storage.  The 'async' mode acknowledges writes when data has been cached for writing to stable storage.  The default (and highly recommended) 'auto' mode checks the storage device to determine whether it supports flushes.  Devices that support flushes will result in a VDO volume in 'async' mode, while devices that do not support flushes will run in sync mode. Existing volumes will maintain their previously configured setting unless a different value is specified in the playbook. |

### `community.general.zfs`

Manage zfs

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | File system, snapshot or volume name, for example V(rpool/myfs). |
| `state` | one of `absent`, `present` | yes | Whether to create (V(present)), or remove (V(absent)) a file system, snapshot or volume. All parents/children will be created/destroyed as needed to reach the desired state. |
| `extra_zfs_properties` | object | — | A dictionary of zfs properties to be set. See the zfs(8) man page for more information. |
| `origin` | string | — | Snapshot from which to create a clone. |

### `config`

Read or write a structured config file as JSON (Class-A codec). `path` + `format` (keyvalue | json | yaml). With no `values`: parses the file and returns its structured data (read-only). With `values`: merges them into the file (manage=merge, default) or makes the file contain exactly them (manage=exact), preserving comments/order for keyvalue and deep-merging json/yaml; writes only on change (idempotent, dry_run-aware). keyvalue tuning: `separator` (default " ", e.g. "=") and `comment` (default "#"). This is how a config file round-trips into the server-as-a-document model.

Cross-tool equivalents:
- Ansible: ansible.builtin.ini_file / lineinfile / template, or community.general codecs.
- Augeas: the same file↔tree idea (this ships the codecs in-process, no C dependency).
- Salt/Puppet: file.serialize / augeas providers.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `format` | one of `keyvalue`, `ini`, `json`, `yaml`, `xml`, `fstab`, `zonefile`, `exports`, `dhcpd` | yes | Config codec. |
| `path` | string | yes | Config file path, e.g. /etc/ssh/sshd_config. |
| `comment` | string | — | keyvalue comment marker (default "#"). |
| `manage` | one of `merge`, `exact` | — | merge = set the given keys, keep the rest (default); exact = file holds exactly `values`. |
| `separator` | string | — | keyvalue key/value separator (default " "; use "=" for key=value files). |
| `values` | object | — | Desired values. Omit to read (parse) only. |

### `copy`

Ensure a destination file's content, owner, group, and mode match a desired value. Provide exactly one content source: `content` (a literal string, e.g. a rendered config file or a message-of-the-day banner) or `src` (a path to an existing file on this same host to copy from). Idempotent — compares the destination's current bytes against the desired content and only writes when they differ; reports changed=false on a repeat call with the same content. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.copy. Same dest/content/src/owner/group/mode semantics (a subset — Ansible's copy also supports remote_src, backup, validate, which are not yet implemented here).
- Chef: the `file` resource with a `content` property (for literal content) or the `cookbook_file`/`remote_file` resources (for copying a source file).
- Puppet: the `file` type with `content => ...` (literal) or `source => ...` (copy from a module file).
- Salt: the `file.managed` state, using its `contents` parameter (literal) or `source` parameter (copy from a file).
- Terraform: the `local_file` resource (for files local to the machine running Terraform) or a provisioner's `file` block for copying to a remote managed host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination path to write, e.g. "/etc/motd" or "/etc/nginx/conf.d/app.conf". |
| `content` | string | — | Literal content to write to dest. Mutually exclusive with src. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `group` | string | — | Optional desired group (group name or numeric gid). |
| `mode` | string | — | Optional desired permission mode as an octal string, e.g. "0644". |
| `owner` | string | — | Optional desired owner (username or numeric uid). |
| `src` | string | — | Path to an existing local file whose content should be copied to dest. Mutually exclusive with content. |

### `cron`

Ensure a crontab entry is present or absent for a given user, identified by a named marker comment rather than its content — so changing the schedule or command later replaces the same entry instead of adding a duplicate. Idempotent — a repeat call with the same parameters reports changed=false. Time fields default to "*" (every minute/hour/day/month/weekday) unless given; alternatively set `special_time` (e.g. "reboot", "daily") instead of the five numeric fields. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.cron. Same name/job/user/minute/hour/day/weekday/month/special_time/state semantics (a focused subset — Ansible also supports env vars and cron.d files, not implemented here; entries always go into the user's own crontab).
- Chef: the `cron`/`cron_d` resources.
- Puppet: the `cron` type.
- Salt: the `cron.present`/`cron.absent` states.
- Terraform: not applicable — Terraform does not manage host-level scheduled tasks.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Unique identifier for this entry, used as its marker comment — required to find/replace/remove it later. |
| `day` | string | — | Cron day-of-month field. Default "*". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `hour` | string | — | Cron hour field. Default "*". |
| `job` | string | — | The command to run, e.g. "/usr/local/bin/backup.sh". Required for state=present. |
| `minute` | string | — | Cron minute field. Default "*". |
| `month` | string | — | Cron month field. Default "*". |
| `special_time` | one of `reboot`, `yearly`, `annually`, `monthly`, `weekly`, `daily`, `hourly` | — | Optional named schedule instead of the five numeric fields. |
| `state` | one of `present`, `absent` | — | Whether the entry should be present or absent. Default "present". |
| `user` | string | — | Which user's crontab to edit. Default "root". |
| `weekday` | string | — | Cron day-of-week field. Default "*". |

### `deb822_repository`

Ensure a modern RFC822-style ("deb822") APT source stanza is present or absent in /etc/apt/sources.list.d/<name>.sources — the format used by apt 2.4+ (Debian 12+, Ubuntu 24.04+) in place of the older one-line "deb ..." syntax that apt_repository manages. Idempotent — only writes when the rendered stanza differs from the file's current content. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.deb822_repository. Covers the common types/uris/suites/components/signed_by fields (a focused subset — Ansible's real module also supports per-field options like Architectures/Languages/trust overrides, not implemented here).
- Chef: the `apt_repository` resource with deb822-style options on newer releases, or a hand-written `file` resource for the stanza.
- Puppet: no core equivalent yet at this format's release cadence; typically a `file` resource with templated content.
- Salt: the `pkgrepo.managed` state's `key_url`/`aptkey`-adjacent deb822 support, or a templated `file.managed`.
- Terraform: not applicable — Terraform does not manage a running host's package manager configuration.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Target file name (without .sources) under /etc/apt/sources.list.d/, e.g. "myrepo". |
| `components` | array of string | — | Components (e.g. main, contrib). Optional. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `signed_by` | string | — | Optional path to the repository's signing key. |
| `state` | one of `present`, `absent` | — | Whether the entry should be present or absent. Default "present". |
| `suites` | array of string | — | Suite names (e.g. distribution codenames). Required for state=present. |
| `types` | array of string | — | Entry types. Default ["deb"]. |
| `uris` | array of string | — | Repository URIs. Required for state=present. |

### `debconf`

Set a debconf database value for a Debian package (pre-seeding an answer a package's postinst script would otherwise prompt for interactively), via debconf-set-selections. Idempotent — reads the current value via `debconf-show <name>` first and only sets it when it differs. Setting a value does not by itself re-run a package's postinst; that remains a separate `dpkg-reconfigure` step if the package needs to react immediately. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.debconf. Same name/question/vtype/value/unseen parameter names.
- Chef: the `execute` resource shelling out to debconf-set-selections — no dedicated resource exists.
- Puppet: no dedicated core type; typically a `exec` resource wrapping debconf-set-selections, same as Chef.
- Salt: the `debconf.set` state.
- Terraform: not applicable — Terraform does not manage package installer prompts on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Package name the question belongs to, e.g. "postfix". |
| `question` | string | yes | Debconf question name, e.g. "postfix/main_mailer_type". |
| `value` | string | yes | Desired value for the question. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `unseen` | boolean | — | When true, also clear the question's "seen" flag so the package will prompt for it again if reconfigured. Default false. |
| `vtype` | one of `string`, `boolean`, `select`, `multiselect`, `note`, `password` | — | Debconf value type. Default "string". |

### `dnf`

Ensure one or more RPM packages are present, absent, or upgraded to the latest available version, via dnf. Idempotent: queries the rpm database's current status before deciding whether to act. Unit-tested only in this project (no RPM-based host in the real verification environment — contrast with apt, this agent's real-tested primary target). Supports check_mode via dry_run=true, with one caveat: for state=latest, dry_run against an already-installed package conservatively predicts changed=true, since determining whether a newer version is truly available would itself require a repository query.

Cross-tool equivalents:
- Ansible: ansible.builtin.dnf. Same name/state parameter names (name accepts either a single package or a list); a focused subset — Ansible's own module also supports enablerepo/disablerepo/update_cache and more, not yet implemented here.
- Chef: the `dnf_package`/`package` resources.
- Puppet: the `package` type with `provider => dnf`.
- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.
- Terraform: not applicable — Terraform does not manage OS packages on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["httpd"] or ["httpd", "curl"]. |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating command (check_mode). For state=latest, an already-installed package conservatively predicts changed=true under dry_run, since determining whether a newer version truly exists would itself require a repository query — see the module description. |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |

### `dnf5`

Ensure one or more RPM packages are present, absent, or upgraded to the latest available version, via dnf5. Idempotent: queries the rpm database's current status before deciding whether to act. Unit-tested only in this project (no RPM-based host in the real verification environment — contrast with apt, this agent's real-tested primary target). Supports check_mode via dry_run=true, with one caveat: for state=latest, dry_run against an already-installed package conservatively predicts changed=true, since determining whether a newer version is truly available would itself require a repository query.

Cross-tool equivalents:
- Ansible: ansible.builtin.dnf5. Same name/state parameter names (name accepts either a single package or a list); a focused subset — Ansible's own module also supports enablerepo/disablerepo/update_cache and more, not yet implemented here.
- Chef: the `dnf_package`/`package` resources.
- Puppet: the `package` type with `provider => dnf5`.
- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.
- Terraform: not applicable — Terraform does not manage OS packages on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["httpd"] or ["httpd", "curl"]. |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating command (check_mode). For state=latest, an already-installed package conservatively predicts changed=true under dry_run, since determining whether a newer version truly exists would itself require a repository query — see the module description. |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |

### `dpkg_selections`

Set a Debian/Ubuntu package's dpkg selection state — most commonly "hold", to prevent apt from ever upgrading/removing it even when a newer version is available. Idempotent — checks the package's current selection via `dpkg --get-selections` first and only calls `dpkg --set-selections` when it differs. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.dpkg_selections. Same name/selection parameters.
- Chef: the `dpkg_autostart`/`apt_preference` resources approximate parts of this; the closest direct equivalent is shelling out to `dpkg --set-selections` in a custom resource.
- Puppet: the `package` type's `hold` provider-specific ensure value on Debian systems (`ensure => held`).
- Salt: the `pkg.held`/`pkg.unheld` states.
- Terraform: not applicable — Terraform does not manage OS package hold state.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Package name, e.g. "curl". |
| `selection` | one of `install`, `hold`, `deinstall`, `purge` | yes | Desired dpkg selection state. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |

### `expect`

Run a command and answer interactive prompts it produces, via `responses` — a map from regular expression to the line sent to the command's stdin the first time that expression matches the accumulated output; each response fires at most once. Returns rc/output like command; **a non-zero rc is not raised as a tool error**. Execution is bounded by `timeout` seconds (default 30, hard-capped at 600 regardless of the requested value, the same cap wait_for enforces). **Limitation, stated plainly**: this pipes stdout/stderr rather than allocating a real pseudo-terminal, unlike Ansible's own pexpect-based implementation — programs that specifically need tty semantics (echo suppression for password prompts, terminal-size queries, raw mode) may not behave correctly here. Suited to straightforward line-buffered prompts, not full terminal emulation. Supports check_mode via dry_run=true (does not execute at all).

Cross-tool equivalents:
- Ansible: ansible.builtin.expect. Same cmd/responses/timeout parameter names (a focused subset — Ansible also supports a list of sequential answers per prompt and echo/creates/removes options, not implemented here).
- Chef/Puppet: no dedicated resource; typically scripted with `execute`/`exec` plus a tool like `expect(1)` itself.
- Salt: no dedicated state; typically wrapped via `cmd.run` plus `expect(1)`.
- Terraform: not applicable — see the command module's description for the general reasoning.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `cmd` | string | yes | Command line to run, split on whitespace (no quoting support), e.g. "passwd deploy". |
| `responses` | object | yes | Map from regular expression to the line sent to stdin the first time it matches, e.g. {"[Pp]assword:": "hunter2"}. |
| `chdir` | string | — | Optional working directory to run the command in. |
| `dry_run` | boolean | — | When true, do not execute the command at all; report changed=true as a prediction only (check_mode). |
| `timeout` | string | — | Maximum seconds to let the command run before it is killed. Default "30", hard-capped at 600. |

### `file`

Set the state of a path: ensure a directory exists, ensure a path is absent (file or directory, removed recursively), touch an empty file into existence, or assert attributes (owner/group/mode) on an existing file/directory. Idempotent — running it twice with the same parameters produces changed=false the second time. Supports check_mode: pass dry_run=true to preview whether anything would change without touching the filesystem.

Cross-tool equivalents:
- Ansible: ansible.builtin.file. Same path/state/owner/group/mode parameter names; supports state=file|directory|absent|touch|link (state=link requires 'src', the link target; Ansible additionally supports state=hard for hardlinks, not yet implemented here).
- Chef: the `directory` resource (state=directory), `file` resource with action :delete (state=absent) or action :create_if_missing / :touch (state=touch), and a `file` resource's owner/group/mode properties for attribute assertions.
- Puppet: the `file` type — `ensure => directory`, `ensure => absent`, `ensure => present` (touch-like), with `owner`/`group`/`mode` parameters.
- Salt: the `file.directory` state (state=directory), `file.absent` (state=absent), `file.touch` (state=touch), or `file.managed`'s user/group/mode for attribute-only changes.
- Terraform: not a natural fit — Terraform manages infrastructure resources, not arbitrary remote-file attributes; the closest analogue is a provisioner (`remote-exec`/`local-exec`) invoking mkdir/rm/touch/chown/chmod, which loses Terraform's own state tracking for that action.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | Path to manage, e.g. "/opt/app/data" or "/etc/myapp/config.d". |
| `dry_run` | boolean | — | When true, report what would change without modifying the filesystem (check_mode). |
| `group` | string | — | Optional desired group (group name or numeric gid). Leave unset to not manage group. |
| `mode` | string | — | Optional desired permission mode as an octal string, e.g. "0644" or "755". Leave unset to not manage mode. Ignored when state=link — symlink permission bits are not meaningfully manageable on Linux. |
| `owner` | string | — | Optional desired owner (username or numeric uid). Leave unset to not manage ownership. |
| `src` | string | — | The symlink target. Required when state=link, e.g. "/data1/var_lib_docker" for path "/var/lib/docker". |
| `state` | one of `file`, `directory`, `absent`, `touch`, `link` | — | Desired state. Default "file" (assert attributes on an existing file, error if missing). |

### `firewall`

Backend-agnostic host firewall manager with the simplicity of firewall-cmd. Auto-detects firewalld / ufw / iptables and translates a small set of high-level operations to that backend. Operations (op): detect (report backend + state), enable (turn firewall on; on the iptables backend this installs iptables-persistent and saves current rules), disable, allow / deny (a port like 8080/tcp or a named service like ssh, optionally from a source CIDR), snat (masquerade or SNAT outgoing traffic — needs to_source and out_interface), dnat (port-forward incoming traffic — needs protocol, dest_port, to_dest, in_interface), set_mode (server = no IP forwarding; router = enable net.ipv4.ip_forward via a persistent /etc/sysctl.d drop-in AND masquerade the LAN out the WAN interface), and list (current rules).

Cross-tool equivalents: Ansible ansible.builtin.iptables / posix.firewalld / community.general.ufw; Salt firewalld/iptables states. This module is the one-stop simplified front-end over all three.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `op` | one of `detect`, `enable`, `disable`, `allow`, `deny`, `snat`, `dnat`, `set_mode`, `list` | yes | Operation to perform. |
| `agent_port` | string | — | Management (Yoloman) TCP port to whitelist first on enable. Defaults to the daemon's own listen port. |
| `backend` | one of `firewalld`, `ufw`, `iptables` | — | Force a backend instead of auto-detecting. |
| `dest_port` | string | — | Incoming port to forward (dnat). |
| `dry_run` | boolean | — | When true, report what would change without applying it. |
| `in_interface` | string | — | Inbound/WAN interface (dnat / router masquerade). |
| `lan_subnet` | string | — | LAN subnet to masquerade in router mode, e.g. "10.0.0.0/24". |
| `mode` | one of `server`, `router` | — | Host mode for set_mode. |
| `out_interface` | string | — | Outbound/WAN interface (snat / router masquerade). |
| `port` | string | — | Port spec for allow/deny, e.g. "8080/tcp" or "53/udp". |
| `protocol` | string | — | Protocol for dnat, e.g. "tcp" or "udp". Default "tcp". |
| `service` | string | — | Named service for allow/deny, e.g. "ssh", "http", "https", "dns". |
| `source` | string | — | Optional source address/CIDR to scope an allow/deny or SNAT rule. |
| `to_dest` | string | — | DNAT target "ip" or "ip:port" (dnat). |
| `to_source` | string | — | SNAT target IP, or "masquerade" for dynamic source NAT (snat). |

### `get_url`

Download a file from an HTTP(S) URL to a destination path. Conservative idempotency, matching real Ansible: if `dest` already exists, it is left alone entirely unless `force=true` or a `checksum` is given that doesn't match the existing file's hash — there is no download at all just to "check", to avoid needless network traffic for a file that's presumably already correct. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.get_url. Same url/dest/checksum/force/owner/group/mode semantics (a focused subset — Ansible also supports headers/url_username/timeout and more, not yet implemented here).
- Chef: the `remote_file` resource.
- Puppet: the `archive` module (voxpupuli-archive) or an `exec` wrapping curl/wget.
- Salt: the `file.managed` state's `source` parameter with an `http://`/`https://` URL.
- Terraform: not applicable at apply time for a running host; closest analogue is a provisioner shelling out to curl/wget.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination path to write to, e.g. "/opt/app/release.tar.gz". |
| `url` | string | yes | Source URL to download from. |
| `checksum` | string | — | Optional expected checksum as "sha256:<hex>". If dest exists and matches, no download occurs. |
| `dry_run` | boolean | — | When true, report what would change without downloading (check_mode). |
| `force` | boolean | — | When true, always (re-)download and overwrite dest even if it already exists. Default false. |
| `group` | string | — | Optional desired group (group name or numeric gid). |
| `mode` | string | — | Optional desired permission mode as an octal string, e.g. "0644". |
| `owner` | string | — | Optional desired owner (username or numeric uid). |

### `git`

Ensure a git repository is cloned at dest and checked out to a desired version (branch, tag, or commit). Idempotent — if dest is already a working copy, only fetches/checks out when the resolved commit differs from the current HEAD; otherwise clones fresh. Supports check_mode via dry_run=true (a real check requires a network fetch to know the remote's current state, so dry_run against an existing clone conservatively predicts changed=true — the same trade-off documented for the RPM package modules' state=latest).

Cross-tool equivalents:
- Ansible: ansible.builtin.git. Same repo/dest/version/depth/force parameter names (a focused subset — Ansible also supports refspec/key_file/accept_hostkey and more, not implemented here).
- Chef: the `git` resource.
- Puppet: the puppetlabs-vcsrepo module's `vcsrepo` type with `provider => git`.
- Salt: the `git.latest` state.
- Terraform: not applicable — Terraform does not manage arbitrary file-tree state on a running host; the closest analogue is a provisioner shelling out to git.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination directory, e.g. "/opt/app". |
| `repo` | string | yes | Repository URL to clone from. |
| `depth` | string | — | Optional shallow-clone depth, as a string, e.g. "1". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `force` | boolean | — | When true, discard any local modifications before checking out. Default false. |
| `version` | string | — | Branch, tag, or commit to check out. Default "HEAD". |

### `group`

Ensure a system group exists (optionally with a specific gid) or is absent. Idempotent — checks the group's current state via getent first and only calls groupadd/groupmod/groupdel when something actually needs to change. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.group. Same name/gid/state/system parameter names (a focused subset — Ansible also supports non_unique/local, not yet implemented here).
- Chef: the `group` resource.
- Puppet: the `group` type.
- Salt: the `group.present`/`group.absent` states.
- Terraform: not applicable — Terraform does not manage OS-level accounts on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Group name, e.g. "deploy". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `gid` | string | — | Optional specific numeric gid to assign/enforce. |
| `state` | one of `present`, `absent` | — | Whether the group should be present or absent. Default "present". |
| `system` | boolean | — | For state=present when creating a new group: create it as a system group. Default false. |

### `hostname`

Ensure the system's hostname matches a desired value, using hostnamectl (systemd-based Linux, like the rest of this agent). Idempotent — compares the current kernel hostname first and only calls hostnamectl when it differs. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.hostname. Same name parameter; Ansible supports multiple per-distro strategies (systemd/redhat/debian/...), this module only implements the systemd (hostnamectl) strategy.
- Chef: no single built-in resource; typically a `execute` resource wrapping hostnamectl, or the community 'hostname' cookbook.
- Puppet: no core equivalent; augeasproviders or an `exec` wrapping hostnamectl.
- Salt: the `network.system` state's `hostname` parameter, or the `system.set_computer_desc`-style execution modules.
- Terraform: not applicable — Terraform does not manage a running host's kernel state.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Desired hostname, e.g. "web01.example.com". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |

### `iptables`

Ensure a netfilter rule is present or absent in a given table/chain, via `iptables`. Idempotent through `iptables -C` (the check flag purpose-built for idempotent scripting) — only calls -A/-I/-D when the exact rule's presence doesn't already match state. Supports check_mode via dry_run=true (the check itself is read-only and always runs, even under dry_run, to report accurately what would change). A focused subset of real Ansible's ~40 iptables parameters: protocol/source/destination/ports/interfaces/jump/comment cover the common case — conntrack state matching, NAT-specific options, and numeric rule positioning are not implemented here.

Cross-tool equivalents:
- Ansible: ansible.builtin.iptables. Same table/chain/protocol/source/destination/source_port/destination_port/in_interface/out_interface/jump/comment/action/state parameter names.
- Chef: the `iptables_rule` resource.
- Puppet: the puppetlabs-firewall module's `firewall` type.
- Salt: the `iptables.append`/`iptables.insert`/`iptables.delete` execution modules.
- Terraform: not applicable — Terraform does not manage a running host's kernel firewall state.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `chain` | string | yes | Chain name, e.g. "INPUT", "FORWARD", or a custom chain. |
| `action` | one of `append`, `insert` | — | Where to place a new rule. Default "append". |
| `comment` | string | — | Optional comment attached to the rule via the comment match module. |
| `destination` | string | — | Destination address/CIDR to match. |
| `destination_port` | string | — | Destination port to match (requires protocol tcp or udp). |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `in_interface` | string | — | Input interface to match. |
| `jump` | string | — | Target, e.g. "ACCEPT", "DROP", "REJECT". Required for state=present. |
| `out_interface` | string | — | Output interface to match. |
| `protocol` | string | — | Protocol to match, e.g. "tcp", "udp", "icmp". |
| `source` | string | — | Source address/CIDR to match. |
| `source_port` | string | — | Source port to match (requires protocol tcp or udp). |
| `state` | one of `present`, `absent` | — | Whether the rule should be present or absent. Default "present". |
| `table` | string | — | Netfilter table. Default "filter". |

### `known_hosts`

Ensure an SSH known_hosts entry is present or absent, identified by hostname (the entry's first field) rather than its full line — so re-running with a different host key replaces the same entry instead of adding a duplicate stale one. Idempotent — a repeat call with the same key reports changed=false. Supports check_mode via dry_run=true. Host key hashing (ssh-keygen -H style) is not implemented — entries are always written in plain hostname form, matching this module's real Ansible default (hash_host=false).

Cross-tool equivalents:
- Ansible: ansible.builtin.known_hosts. Same name/key/path/state parameter names (a focused subset — Ansible also supports hash_host, not implemented here).
- Chef: no single built-in resource; typically composed from `Chef::Util::FileEdit` in a custom resource, or the community 'ssh_known_hosts' cookbook.
- Puppet: the puppetlabs-stdlib module conventions, or the sshkeys core type on some platforms.
- Salt: the `ssh.set_known_host`/`ssh.rm_known_host` execution modules.
- Terraform: not applicable — Terraform does not manage a running host's SSH trust store.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Hostname the entry is for, e.g. "github.com". |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `key` | string | — | The full known_hosts line, e.g. "github.com ssh-ed25519 AAAA...". Required for state=present. |
| `path` | string | — | Target known_hosts file. Default "/etc/ssh/ssh_known_hosts". |
| `state` | one of `present`, `absent` | — | Whether the entry should be present or absent. Default "present". |

### `lineinfile`

Ensure a single line is present or absent in a text file, without rewriting the rest of the file — the classic 'make sure this one config line is set' operation (e.g. a sysctl setting, a single key=value pair, an /etc/hosts entry). If `regexp` is given, the first line matching it is replaced (state=present) or every matching line is removed (state=absent); without `regexp`, an exact line match is used. Idempotent — a repeat call with the same parameters reports changed=false. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.lineinfile. Same path/regexp/line/state/create parameter names and matching semantics (a focused subset — Ansible also supports insertafter/insertbefore/backrefs, not yet implemented here).
- Chef: no single built-in resource; typically composed from `Chef::Util::FileEdit` in a custom resource/library, or the community `line` cookbook's `replace_or_add` resource.
- Puppet: the `file_line` type from the puppetlabs-stdlib module.
- Salt: the `file.line` or `file.replace` state.
- Terraform: not applicable — Terraform has no line-level file-editing primitive; the closest analogue is templating the whole file with `local_file`/`templatefile()`.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | File to edit, e.g. "/etc/sysctl.conf". |
| `create` | boolean | — | For state=present: if the file does not exist, create it instead of failing. Default false. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `line` | string | — | The line's exact desired content (for state=present) or the exact line to remove when no regexp is given (for state=absent). |
| `regexp` | string | — | Optional RE2 regular expression. For state=present, matches the line to replace with `line` (appends `line` if no match). For state=absent, every matching line is removed. |
| `state` | one of `present`, `absent` | — | Whether the line should be present or absent. Default "present". |

### `package`

Ensure one or more packages are present, absent, or upgraded to the latest available version, using whichever package manager frontend this host actually has (apt-get, dnf, dnf5, or yum, checked in that order) — for tasks/playbooks that need to run unmodified across both Debian- and RedHat-family hosts. Prefer the specific module (apt/dnf/yum/dnf5) when you already know the target distro family; use this one when you don't, or when translating a playbook that itself used the generic module. Same idempotency/check_mode behavior as whichever underlying module it dispatches to.

Cross-tool equivalents:
- Ansible: ansible.builtin.package. Same dispatch-by-detected-package-manager idea; same name/state parameter names.
- Chef: the generic `package` resource, which similarly dispatches by platform.
- Puppet: the `package` type without an explicit `provider` (auto-detected).
- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states (Salt's `pkg` state module auto-dispatches by the minion's grains).
- Terraform: not applicable — Terraform does not manage OS packages on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["nginx"]. |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating command (check_mode). |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |

### `pip`

Ensure one or more Python packages are present, absent, or upgraded to the latest available version, via pip. Idempotent: queries `pip show <pkg>` (a read-only query, safe under check_mode) before deciding whether to act. A package spec may pin an exact version with "pkg==1.2.3" (checked for state=present); state=latest always attempts `pip install --upgrade` and reports changed based on the version actually observed before vs. after. An optional `virtualenv` path is created via `python3 -m venv` if it doesn't yet exist, and that venv's own pip is used instead of a system-wide one. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.pip. Same name/state/version/virtualenv parameter names (a focused subset — Ansible also supports requirements files, extra_args, and more, not implemented here).
- Chef: the `pip_package` resource (poise-python / python cookbook).
- Puppet: the puppet-python module's `package` type with `provider => pip`.
- Salt: the `pip.installed`/`pip.removed` states.
- Terraform: not applicable — Terraform does not manage language-level package managers on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["requests"] or ["requests==2.31.0"] (an "==version" suffix pins an exact version for state=present). |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating pip command (check_mode). |
| `executable` | string | — | Pip binary to use when virtualenv is not set. Default "pip3". |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |
| `virtualenv` | string | — | Optional path to a virtualenv; created via `python3 -m venv` if it doesn't exist yet, and used instead of the system pip. |

### `posix.firewalld`

Manage arbitrary ports/services with firewalld

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `state` | one of `absent`, `disabled`, `enabled`, `present` | yes | Enable or disable a setting. For ports: Should this port accept (enabled) or reject (disabled) connections. The states C(present) and C(absent) can only be used in zone level operations (i.e. when no other parameters but zone and state are set). |
| `icmp_block` | string | — | The ICMP block you would like to add/remove to/from a zone in firewalld. |
| `icmp_block_inversion` | string | — | Enable/Disable inversion of ICMP blocks for a zone in firewalld. |
| `immediate` | boolean | — | Should this configuration be applied immediately, if set as permanent. |
| `interface` | string | — | The interface you would like to add/remove to/from a zone in firewalld. |
| `masquerade` | string | — | The masquerade setting you would like to enable/disable to/from zones within firewalld. |
| `offline` | boolean | — | Whether to run this module even when firewalld is offline. |
| `permanent` | boolean | — | Should this configuration be in the running firewalld configuration or persist across reboots. As of Ansible 2.3, permanent operations can operate on firewalld configs when it is not running (requires firewalld >= 0.3.9). Note that if this is C(false), immediate is assumed C(true). |
| `port` | string | — | Name of a port or port range to add/remove to/from firewalld. Must be in the form PORT/PROTOCOL or PORT-PORT/PROTOCOL for port ranges. |
| `port_forward` | array of string | — | Port and protocol to forward using firewalld. |
| `protocol` | string | — | Name of a protocol to add/remove to/from firewalld. |
| `rich_rule` | string | — | Rich rule to add/remove to/from firewalld. See L(Syntax for firewalld rich language rules,https://firewalld.org/documentation/man-pages/firewalld.richlanguage.html). |
| `service` | string | — | Name of a service to add/remove to/from firewalld. The service must be listed in output of firewall-cmd --get-services. |
| `source` | string | — | The source/network you would like to add/remove to/from firewalld. |
| `target` | one of `default`, `ACCEPT`, `DROP`, `%%REJECT%%` | — | firewalld Zone target If state is set to C(absent), this will reset the target to default |
| `timeout` | integer | — | The amount of time in seconds the rule should be in effect for when non-permanent. |
| `zone` | string | — | The firewalld zone to add/remove to/from. Note that the default zone can be configured per system but C(public) is default from upstream. Available choices can be extended based on per-system configs, listed here are "out of the box" defaults. Possible values include C(block), C(dmz), C(drop), C(external), C(home), C(internal), C(public), C(trusted), C(work). |

### `posix.mount`

Control active and configured mount points

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | Path to the mount point (e.g. C(/mnt/files)). Before Ansible 2.3 this option was only usable as I(dest), I(destfile) and I(name). |
| `state` | one of `absent`, `absent_from_fstab`, `mounted`, `present`, `unmounted`, `remounted`, `ephemeral` | yes | If C(mounted), the device will be actively mounted and appropriately configured in I(fstab). If the mount point is not present, the mount point will be created. If C(unmounted), the device will be unmounted without changing I(fstab). C(present) only specifies that the device is to be configured in I(fstab) and does not trigger or require a mount. C(ephemeral) only specifies that the device is to be mounted, without changing I(fstab). If it is already mounted, a remount will be triggered. This will always return changed=True. If the mount point I(path) has already a device mounted on, and its source is different than I(src), the module will fail to avoid unexpected unmount or mount point override. If the mount point is not present, the mount point will be created. The I(fstab) is completely ignored. This option is added in version 1.5.0. C(absent) specifies that the device mount's entry will be removed from I(fstab) and will also unmount the device and remove the mount point. C(remounted) specifies that the device will be remounted for when you want to force a refresh on the mount itself (added in 2.9). This will always return changed=true. If I(opts) is set, the options will be applied to the remount, but will not change I(fstab).  Additionally, if I(opts) is set, and the remount command fails, the module will error to prevent unexpected mount changes.  Try using C(mounted) instead to work around this issue.  C(remounted) expects the mount point to be present in the I(fstab). To remount a mount point not registered in I(fstab), use C(ephemeral) instead, especially with BSD nodes. C(absent_from_fstab) specifies that the device mount's entry will be removed from I(fstab). This option does not unmount it or delete the mountpoint. |
| `backup` | boolean | — | Create a backup file including the timestamp information so you can get the original file back if you somehow clobbered it incorrectly. |
| `boot` | boolean | — | Determines if the filesystem should be mounted on boot. Only applies to Solaris and Linux systems. For Solaris systems, C(true) will set C(yes) as the value of mount at boot in I(/etc/vfstab). For Linux, FreeBSD, NetBSD and OpenBSD systems, C(false) will add C(noauto) to mount options in I(/etc/fstab). To avoid mount option conflicts, if C(noauto) specified in C(opts), mount module will ignore C(boot). This parameter is ignored when I(state) is set to C(ephemeral). |
| `dump` | string | — | Dump (see fstab(5)). Note that if set to C(null) and I(state) set to C(present), it will cease to work and duplicate entries will be made with subsequent runs. Has no effect on Solaris systems or when used with C(ephemeral). |
| `fstab` | string | — | File to use instead of C(/etc/fstab). You should not use this option unless you really know what you are doing. This might be useful if you need to configure mountpoints in a chroot environment. OpenBSD does not allow specifying alternate fstab files with mount so do not use this on OpenBSD with any state that operates on the live filesystem. This parameter defaults to /etc/fstab or /etc/vfstab on Solaris. This parameter is ignored when I(state) is set to C(ephemeral). |
| `fstype` | string | — | Filesystem type. Required when I(state) is C(present), C(mounted) or C(ephemeral). |
| `opts` | string | — | Mount options (see fstab(5), or vfstab(4) on Solaris). |
| `passno` | string | — | Passno (see fstab(5)). Note that if set to C(null) and I(state) set to C(present), it will cease to work and duplicate entries will be made with subsequent runs. Deprecated on Solaris systems. Has no effect when used with C(ephemeral). |
| `src` | string | — | Device (or NFS volume, or something else) to be mounted on I(path). Required when I(state) set to C(present), C(mounted) or C(ephemeral). |

### `qm`

Run any Proxmox VE `qm` subcommand on this node via the local CLI — the full qm surface in one tool. Set command to the subcommand and args to the rest of the command line, e.g. command="snapshot" args=["100","pre-upgrade","--description","before upgrade"], or command="migrate" args=["100","pve2","--online"], or command="start" args=["100"]. Common subcommands: start, stop, shutdown, reboot, reset, suspend, resume (power); snapshot, delsnapshot, rollback, listsnapshot (snapshots); migrate; clone; resize; set; config; status; list. Read subcommands (status/list/config/listsnapshot/pending/showcmd/cloudinit) run even in check_mode and report changed=false; every other subcommand is mutating — write-gated, skipped under dry_run=true, reported changed=true. Returns {rc, stdout, stderr}. Idempotency is the caller's responsibility (this is a raw CLI passthrough). List VMs/detect the hypervisor with the read-only virt_facts module; this is LOCAL node control, distinct from the API-based community.general.proxmox_kvm.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `command` | string | yes | The qm subcommand, e.g. "start", "snapshot", "migrate", "clone", "resize", "set", "config", "status", "list". |
| `args` | array of string | — | Positional arguments and flags after the subcommand, e.g. ["100","pve2","--online"]. |
| `dry_run` | boolean | — | When true, mutating subcommands are reported but not executed (check_mode). Read subcommands still run. |

### `raw`

Alias of the command module under Ansible's bootstrap-execution module name. Real Ansible's raw module runs a command over SSH on a target with no Python installed yet, bypassing the normal module subsystem — a bootstrapping mechanism for otherwise-unmanageable hosts. This agent has no such problem: it is a single compiled Go binary with no separate module-transfer step, so raw and command behave identically here. See the command module's description for full parameter and cross-tool details.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `argv` | array of string | — | Explicit argument vector, e.g. ["mkdir", "-p", "/opt/my app"] — required whenever an argument contains spaces. Mutually exclusive with cmd. |
| `chdir` | string | — | Optional working directory to run the command in. |
| `cmd` | string | — | Plain command line, split on whitespace (no quoting), e.g. "systemctl daemon-reload". Mutually exclusive with argv. |
| `dry_run` | boolean | — | When true, do not execute the command at all; report changed=true as a prediction only (check_mode). |

### `reboot`

Reboot this host via `shutdown -r now`. **Architectural limitation, stated plainly**: real Ansible's reboot module runs from a separate control node over SSH and can therefore poll the target until it reappears before reporting success; this agent runs *on* the host being rebooted, so the process handling this very call is terminated the moment the reboot happens — there is no possibility of waiting for the host to come back up from inside itself. This module only issues the reboot command and returns immediately; verifying the host actually came back up is the caller's responsibility (e.g. a separate later call, from a new connection, to wait_for or ping). Like restarted/reloaded on the systemd module, this is inherently an action rather than an idempotent state comparison, so it always reports changed=true once issued. Supports check_mode via dry_run=true (does not actually reboot).

Cross-tool equivalents:
- Ansible: ansible.builtin.reboot. Same msg parameter name; Ansible's post-reboot connectivity polling has no equivalent here, for the architectural reason above.
- Chef: the `reboot` resource.
- Puppet: the `reboot` type (puppetlabs-reboot module).
- Salt: the `system.reboot` execution module.
- Terraform: not applicable — Terraform does not manage live host power state.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dry_run` | boolean | — | When true, do not actually reboot; report changed=true as a prediction only (check_mode). |
| `msg` | string | — | Broadcast message shown to logged-in users before rebooting. Default "Reboot initiated by agentic-mcp". |

### `replace`

Replace every match of a regular expression anywhere in a file's content — unlike lineinfile (which matches whole lines), this can match and replace within or across lines, and supports Go RE2 backreferences like $1 in the replacement text. Idempotent — a repeat call with the same pattern reports changed=false once no more matches exist or all matches already read as the replacement. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.replace. Same path/regexp/replace semantics (a focused subset — Ansible also supports before/after/backup, not yet implemented here; and Ansible's replace uses Python re syntax with \1 backreferences, this uses Go RE2 syntax with $1).
- Chef: no single built-in resource; typically Ruby's own String#gsub inside a custom resource/library reading and rewriting the file.
- Puppet: the puppetlabs-stdlib module's `file_line` with `match`/replace-style usage, or the third-party augeasproviders modules for structured config formats.
- Salt: the `file.replace` state — nearly identical regex-across-file-content model.
- Terraform: not applicable — no regex file-editing primitive.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | File to edit, e.g. "/etc/hosts". |
| `regexp` | string | yes | RE2 regular expression to match anywhere in the file's content. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `replace` | string | — | Replacement text; may reference capture groups as $1, $2, etc. Default "" (delete matches). |

### `rpm_key`

Ensure an RPM package-signing key is present or absent, via `rpm --import`/`rpm -e`. `key` is a path or URL to the key file — rpm --import accepts both directly. `fingerprint` (the key's full hex fingerprint) is required so the module can check whether it's already imported (via its last-8-hex-chars key ID, the identifier rpm itself stores imported keys under as a `gpg-pubkey-<keyid>-<date>` pseudo-package) without re-importing it. Idempotent — only calls rpm when the key's presence doesn't already match state. Supports check_mode via dry_run=true. Unit-tested only in this project — no RPM-based host in the real verification environment (contrast with apt_key, which is real-tested on Debian).

Cross-tool equivalents:
- Ansible: ansible.builtin.rpm_key. Same key/fingerprint/state semantics.
- Chef: the `yum_repository` resource's `gpgkey` property (imported implicitly on first repo use), or a `execute` resource wrapping `rpm --import`.
- Puppet: the puppetlabs-stdlib module conventions or a raw `exec` wrapping `rpm --import` — no core equivalent.
- Salt: the `pkgrepo.managed` state's `gpgkey` handling on RPM-based minions.
- Terraform: not applicable — Terraform does not manage a running host's package manager trust store.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `fingerprint` | string | yes | The key's full hex fingerprint, used to check presence via its last-8-hex-char key ID. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `key` | string | — | Path or URL to the key file. Required for state=present. |
| `state` | one of `present`, `absent` | — | Whether the key should be present or absent. Default "present". |

### `run_pipeline`

_No description._

_Takes no parameters._

### `script`

Run a script file already present on this host (with optional arguments), capturing rc/stdout/stderr. In real Ansible, script copies a file FROM the control node TO the managed host before running it; this agent has no such separate control-node filesystem, so this reduces to running an already-present executable — the same operation the command module performs (use command directly for an equivalent call; script exists for drop-in familiarity with real Ansible task syntax that names it explicitly). Like command, **a non-zero exit code is not raised as a tool error** — check data.rc yourself.

Cross-tool equivalents:
- Ansible: ansible.builtin.script. Same intent (run a script with arguments); no control-node-to-managed-host copy step here, since there is no separate control-node filesystem.
- Chef/Puppet/Salt/Terraform: see command's description — the underlying operation (execute an already-present script) is identical.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `cmd` | string | yes | Script path plus arguments, split on whitespace, e.g. "/opt/app/setup.sh --force". |
| `chdir` | string | — | Optional working directory to run the script in. |
| `dry_run` | boolean | — | When true, do not execute the script at all; report changed=true as a prediction only (check_mode). |

### `service`

Alias of the systemd module under Ansible's more commonly used generic module name. ansible.builtin.service dispatches to systemd, sysvinit, upstart, or other init systems depending on the target's facts; this agent only targets systemd-based Linux, so `service` and `systemd` behave identically here. See the systemd module's description for full parameter and cross-tool details.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Unit name, e.g. "nginx" or "nginx.service" (the .service suffix is added automatically if omitted). |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating systemctl command (check_mode). |
| `enabled` | boolean | — | Whether the unit should start at boot. Omit to leave the current enabled state untouched. |
| `state` | one of `started`, `stopped`, `restarted`, `reloaded` | — | Desired running state. Omit to only manage "enabled" without touching running state. |

### `shell`

Run a command line through a real shell interpreter (pipes, redirects, globbing, `$()` substitution, env var expansion all work, exactly like a real shell prompt) — the ONE deliberate exception to this agent's normal "no shell, argv only" execution model (see command/raw). **Because of that, this tool has no injection protection**: whatever `cmd` contains is interpreted by the shell verbatim. Never pass untrusted or externally-influenced text into `cmd` — prefer `command`/`raw` (argv, no shell involved) or the agent's separate whitelisted pipeline tool whenever shell syntax isn't actually needed. Returns rc/stdout/stderr; **a non-zero rc is not raised as a tool error** — check data.rc yourself. Cannot verify idempotency for an arbitrary shell command, so it always reports changed=true once it actually runs; under check_mode (dry_run=true) it does not run at all and reports changed=true as a prediction only, matching Ansible's default of skipping command/shell tasks during --check.

Cross-tool equivalents:
- Ansible: ansible.builtin.shell. Same cmd/executable/chdir parameter names.
- Chef: the `bash`/`execute` resources with `user`-supplied shell syntax.
- Puppet: the `exec` type with `provider => shell`.
- Salt: the `cmd.run` execution module / state (shell=True equivalent).
- Terraform: a `null_resource` with a `local-exec`/`remote-exec` provisioner.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `cmd` | string | yes | Full shell command line, interpreted verbatim by executable, e.g. "ps aux \| grep nginx \| wc -l". |
| `chdir` | string | — | Optional working directory to run the command in. |
| `dry_run` | boolean | — | When true, do not execute the command at all; report changed=true as a prediction only (check_mode). |
| `executable` | string | — | Shell to run cmd through. Default "/bin/sh". |

### `subversion`

Ensure a Subversion working copy is checked out at dest and updated to a desired revision. Idempotent — if dest is already a working copy, only runs `svn update` (and reports changed based on whether the revision actually moved); otherwise checks out fresh. Supports check_mode via dry_run=true (a real check requires contacting the server to know its current revision, so dry_run against an existing checkout conservatively predicts changed=true, the same trade-off documented for git/state=latest package modules).

Cross-tool equivalents:
- Ansible: ansible.builtin.subversion. Same repo/dest/revision parameter names (a focused subset — Ansible also supports username/password/export, not implemented here).
- Chef: the `subversion` resource.
- Puppet: the puppetlabs-vcsrepo module's `vcsrepo` type with `provider => svn`.
- Salt: the `svn.latest` state.
- Terraform: not applicable — see the git module's description for the general reasoning.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination directory, e.g. "/opt/app". |
| `repo` | string | yes | Subversion repository URL to check out from. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `force` | boolean | — | When true, discard any local modifications before updating (svn revert). Default false. |
| `revision` | string | — | Revision to check out, e.g. "HEAD" or "1234". Default "HEAD". |

### `systemd`

Manage a systemd unit's running state (start/stop/restart/reload) and its enabled-at-boot state. Idempotent: queries `systemctl is-active`/`is-enabled` first and only issues a mutating systemctl command when the current state differs from the desired one — except state=restarted/reloaded, which Ansible (and this module) always treat as changed, since a restart is inherently an action rather than a state comparison. Supports check_mode via dry_run=true (queries current state but issues no systemctl mutation).

Cross-tool equivalents:
- Ansible: ansible.builtin.systemd / ansible.builtin.systemd_service (systemd-specific), or the generic ansible.builtin.service module (dispatches to systemd on modern Linux). Same name/state/enabled parameter names and state vocabulary.
- Chef: the `service` resource — `action :start`/`:stop`/`:restart`/`:reload` for running state, `action :enable`/`:disable` for boot state.
- Puppet: the `service` type — `ensure => running`/`stopped`, `enable => true/false`.
- Salt: the `service.running`/`service.dead` states, with `enable: true/false`.
- Terraform: not applicable — Terraform does not manage live service state on a running host; this is normally done via a provisioner or left to configuration management entirely.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Unit name, e.g. "nginx" or "nginx.service" (the .service suffix is added automatically if omitted). |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating systemctl command (check_mode). |
| `enabled` | boolean | — | Whether the unit should start at boot. Omit to leave the current enabled state untouched. |
| `state` | one of `started`, `stopped`, `restarted`, `reloaded` | — | Desired running state. Omit to only manage "enabled" without touching running state. |

### `systemd_service`

Alias of the systemd module under Ansible's newer, systemd-specific generic module name (as opposed to `service`, which dispatches across multiple possible init systems). This agent only targets systemd hosts, so `service`, `systemd`, and `systemd_service` all behave identically here. See the systemd module's description for full parameter and cross-tool details.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Unit name, e.g. "nginx" or "nginx.service" (the .service suffix is added automatically if omitted). |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating systemctl command (check_mode). |
| `enabled` | boolean | — | Whether the unit should start at boot. Omit to leave the current enabled state untouched. |
| `state` | one of `started`, `stopped`, `restarted`, `reloaded` | — | Desired running state. Omit to only manage "enabled" without touching running state. |

### `sysvinit`

Manage a legacy SysV init script's running state (start/stop/restart/reload) and its enabled-at-boot state, via /etc/init.d/<name> and update-rc.d. Idempotent: queries the init script's own "status" action (LSB convention: exit 0 means running) and the presence of an S## runlevel symlink before deciding whether to act — except state=restarted/reloaded, always treated as changed, matching systemd's module behavior for the same reason. Supports check_mode via dry_run=true. This agent's primary target is systemd (see the systemd/service modules); sysvinit exists for hosts or individual services that still predate it.

Cross-tool equivalents:
- Ansible: ansible.builtin.sysvinit. Same name/state/enabled parameter names.
- Chef: the `service` resource with `provider Chef::Provider::Service::Init`.
- Puppet: the `service` type with `provider => init`.
- Salt: the `service.running`/`service.dead` states with the init provider selected.
- Terraform: not applicable — see the systemd module's description for the general reasoning (Terraform does not manage live service state on a running host).

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Init script name under /etc/init.d, e.g. "nginx". |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating command (check_mode). |
| `enabled` | boolean | — | Whether the service should start at boot. Omit to leave the current enabled state untouched. |
| `state` | one of `started`, `stopped`, `restarted`, `reloaded` | — | Desired running state. Omit to only manage "enabled" without touching running state. |

### `tempfile`

Create a temporary file or directory with a unique name and return its path — for staging a scratch location before a later step (e.g. download or render something there, then move/copy it into place). Not idempotent by nature (like `mktemp`, every real call creates a brand-new uniquely named path and reports changed=true); under check_mode (dry_run=true) nothing is created and a predicted path is returned instead.

Cross-tool equivalents:
- Ansible: ansible.builtin.tempfile. Same state/path/prefix/suffix semantics.
- Chef: the `directory`/`file` resources combined with Ruby's `Dir.mktmpdir`/`Tempfile` in a custom resource — no single built-in resource.
- Puppet: no core equivalent; typically an `exec` wrapping `mktemp`.
- Salt: the `temp.dir`/`temp.file` execution module functions.
- Terraform: not applicable — Terraform manages declared infrastructure, not ephemeral scratch paths created during a run.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dry_run` | boolean | — | When true, do not create anything; return a predicted path (check_mode). |
| `path` | string | — | Directory under which to create the temp path. Default: the system temp directory. |
| `prefix` | string | — | Filename prefix. Default "tmp". |
| `state` | one of `file`, `directory` | — | Whether to create a "file" or a "directory". Default "file". |
| `suffix` | string | — | Filename suffix. Default "" (none). |

### `template`

Render {{ variable }} placeholders in template text against a `vars` map and write the result to `dest` — the same {{ }} placeholder convention this agent's own tools.d task definitions use, kept consistent rather than introducing a second templating syntax. This is a deliberately reduced subset of Jinja2: plain variable substitution only — no filters, conditionals, loops, or macros. Provide `content` (the template text inline) or `src` (a path to an existing template file already on this host — there is no separate control-node filesystem in this agent's single-host model, unlike a real Ansible control node). Idempotent — compares the rendered output against dest's current bytes and only writes when they differ. Supports check_mode via dry_run=true. Every placeholder referenced in the template must have a corresponding entry in `vars`, or the call fails with an error naming the missing variable — silently rendering a blank would be worse than refusing.

Cross-tool equivalents:
- Ansible: ansible.builtin.template. Ansible's template engine is full Jinja2 (filters, conditionals, loops, macros); this module supports only {{ variable }} substitution — treat it as covering the common case, not a full replacement for complex Jinja2 templates.
- Chef: ERB templates via the `template` resource (`erb` — a different, more powerful, Ruby-based syntax).
- Puppet: ERB or EPP templates via the `template()`/`epp()` functions inside a `file` resource's `content`.
- Salt: Jinja2 templates via the `file.managed` state's `template: jinja` option — much closer to Ansible's own templating than this module's reduced subset.
- Terraform: the `templatefile()` function or a `local_file`/`template_file` resource, using Terraform's own `${}` interpolation syntax.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination path to write the rendered content, e.g. "/etc/nginx/conf.d/app.conf". |
| `content` | string | — | Literal template text, containing {{ variable }} placeholders. Mutually exclusive with src. |
| `dry_run` | boolean | — | When true, report what would change without writing (check_mode). |
| `group` | string | — | Optional desired group (group name or numeric gid). |
| `mode` | string | — | Optional desired permission mode as an octal string, e.g. "0644". |
| `owner` | string | — | Optional desired owner (username or numeric uid). |
| `src` | string | — | Path to an existing template file on this host, containing {{ variable }} placeholders. Mutually exclusive with content. |
| `vars` | object | — | Values to substitute for each {{ name }} placeholder found in the template. |

### `template_render`

Render a full Jinja2 template (loops, if/else, filters, tests like `is defined` — gonja) against a `values` context and write it to `dest`. The Class-B config mechanism: own a complex config file (nginx/apache/bind) as template + values. Idempotent — writes only when the rendered output differs from dest; dry_run-aware. Params: `template` (the Jinja2 source), `dest`, `values` (the render context). Distinct from `template`, which only does {{ name }} substitution.

Cross-tool equivalents:
- Ansible: ansible.builtin.template (Jinja2). Salt/Puppet: file.managed + jinja / .erb.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination path to write the rendered file, e.g. /etc/nginx/nginx.conf. |
| `template` | string | — | The Jinja2 template source (inline). Prefer template_path in a runbook — inline {{ }} collides with the runbook's own substitution. |
| `template_path` | string | — | Path to a Jinja2 template file on the host (the runbook-safe way — its {{ }} is not touched by runbook substitution). |
| `values` | object | — | The template render context (variables). |

### `timezone`

Ensure the system timezone matches a desired IANA zone name (e.g. "Europe/Berlin", "UTC"), using timedatectl (systemd-based Linux, like the rest of this agent). Idempotent — reads /etc/localtime's symlink target to determine the current zone before deciding whether timedatectl needs to run. Supports check_mode via dry_run=true.

Cross-tool equivalents:
- Ansible: ansible.builtin.timezone. Same name parameter; Ansible supports multiple per-distro strategies, this module only implements the systemd (timedatectl) strategy.
- Chef: no single built-in resource; typically a `execute` resource wrapping timedatectl, or the community 'timezone_ii'/'timezone' cookbooks.
- Puppet: the puppetlabs 'timezone' or saz-timezone third-party modules — no core equivalent.
- Salt: the `timezone.system` state.
- Terraform: not applicable — Terraform does not manage a running host's kernel/system clock configuration.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Desired IANA timezone name, e.g. "Europe/Berlin" or "UTC". |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |

### `unarchive`

Extract a zip or tar archive (optionally .tar.gz/.tgz or .tar.bz2) already present on this host to a destination directory. Archive type is detected from the `src` file's extension. Idempotency relies on `creates`: if given and that path already exists, extraction is skipped entirely; without it, every call extracts (there is no cheap way to know in advance whether an archive's contents already match dest without extracting it — the same practical limitation real Ansible has without a working `creates` check). Supports check_mode via dry_run=true. There is no separate control-node filesystem in this agent's model, so `src` is always a path on this same host (equivalent to Ansible's remote_src=true).

Cross-tool equivalents:
- Ansible: ansible.builtin.unarchive. Same src/dest/creates semantics (a focused subset — Ansible also supports owner/group/mode/exclude/include, not implemented here).
- Chef: the `archive_file` resource.
- Puppet: the voxpupuli-archive module's `archive` type.
- Salt: the `archive.extracted` state.
- Terraform: the `archive_file` data source works in the opposite direction (creating an archive, not extracting one) — not applicable here.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Destination directory to extract into, e.g. "/opt/app". |
| `src` | string | yes | Archive file already on this host, e.g. "/tmp/release.tar.gz". |
| `creates` | string | — | Optional path; if it already exists, extraction is skipped (the idempotency mechanism). |
| `dry_run` | boolean | — | When true, report what would happen without extracting (check_mode). |

### `uri`

Make an arbitrary HTTP(S) request and return its status code, headers, and (if requested) body. Fails if the response status isn't in `status_code` (default: just 200). Always requires write:true regardless of method — method is a runtime parameter (GET vs. POST/PUT/DELETE/...) and this tool can reach and mutate arbitrary remote systems, so it is treated as a write-class capability uniformly rather than trusting the caller's stated method.

Cross-tool equivalents:
- Ansible: ansible.builtin.uri. Same url/method/body/headers/status_code/return_content semantics (a focused subset — Ansible's own module also supports auth/TLS options and response file saving, not yet implemented here).
- Chef: the `Chef::HTTP` class or the `remote_file`/`http_request` resources.
- Puppet: no core equivalent; typically a custom fact/function or an `exec` wrapping curl.
- Salt: the `http.query` execution module.
- Terraform: the `http` data source (read-only GET only) or a `null_resource` provisioner wrapping curl for anything mutating.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `url` | string | yes | Request URL. |
| `body` | string | — | Optional request body. |
| `headers` | object | — | Optional request headers. |
| `method` | string | — | HTTP method. Default "GET". |
| `return_content` | boolean | — | When true, include the response body in the result. Default false. |
| `status_code` | array of integer | — | Acceptable response status codes. Default [200]. |

### `user`

Ensure a system user account exists (with a given uid/primary group/secondary groups/shell/home/comment) or is absent. Idempotent — checks the account's current state via getent/id first and only calls useradd/usermod/userdel when something actually needs to change. Supports check_mode via dry_run=true. Password/credential management is deliberately not supported here — set that through a dedicated secrets-aware path, not a tool call that ends up in an audit log.

Cross-tool equivalents:
- Ansible: ansible.builtin.user. Same name/uid/group/groups/append/shell/home/create_home/comment/system/remove/state parameter names (a focused subset — Ansible also supports password/expires/ssh_key_*/non_unique, not implemented here).
- Chef: the `user` resource.
- Puppet: the `user` type.
- Salt: the `user.present`/`user.absent` states.
- Terraform: not applicable — Terraform does not manage OS-level accounts on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Username, e.g. "deploy". |
| `append` | boolean | — | When true, add to existing secondary groups rather than replacing them. Default false. |
| `comment` | string | — | Optional GECOS/comment field (typically the user's real name). |
| `create_home` | boolean | — | For state=present when creating a new user: also create the home directory. Default true. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `group` | string | — | Optional primary group name or gid. |
| `groups` | array of string | — | Optional list of secondary group names. |
| `home` | string | — | Optional home directory path. |
| `remove` | boolean | — | For state=absent: also remove the home directory and mail spool. Default false. |
| `shell` | string | — | Optional login shell, e.g. "/bin/bash". |
| `state` | one of `present`, `absent` | — | Whether the account should be present or absent. Default "present". |
| `system` | boolean | — | For state=present when creating a new user: create it as a system account. Default false. |
| `uid` | string | — | Optional specific numeric uid to assign/enforce. |

### `virsh`

Run any libvirt `virsh` subcommand via the local CLI — the full virsh surface in one tool. Set command to the subcommand and args to the rest of the command line, e.g. command="start" args=["web01"], command="snapshot-create-as" args=["web01","snap1"], command="migrate" args=["--live","web01","qemu+ssh://node2/system"], or command="setmem" args=["web01","2G","--config"]. Power: start, shutdown, destroy, reboot, suspend, resume. Snapshots: snapshot-create-as, snapshot-delete, snapshot-revert, snapshot-list. Also migrate, define/undefine, attach-disk/detach-disk, setvcpus/setmem, dumpxml, dominfo, domstate, list. Read subcommands run even in check_mode (changed=false); every other subcommand is mutating — write-gated, skipped under dry_run=true, changed=true. Returns {rc, stdout, stderr}. Idempotency is the caller's responsibility. List domains/detect the hypervisor with virt_facts.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `command` | string | yes | The virsh subcommand, e.g. "start", "snapshot-create-as", "migrate", "setmem", "dominfo", "list". |
| `args` | array of string | — | Positional arguments and flags after the subcommand, e.g. ["--live","web01","qemu+ssh://node2/system"]. |
| `dry_run` | boolean | — | When true, mutating subcommands are reported but not executed (check_mode). Read subcommands still run. |

### `yoloman.network_checkpoint`

Cockpit-style auto-rollback for network changes (create/confirm/rollback), provider-independent

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `id` | string | — | Caller-supplied checkpoint id ([A-Za-z0-9._-]); ties create/confirm/rollback together. |
| `name` | string | — | The interface whose managed config file is backed up (required for state=create). |
| `provider` | one of `networkmanager`, `netplan`, `networkd`, `ifupdown` | — | Force a provider; default auto-detect. |
| `state` | one of `create`, `confirm`, `rollback` | — | create arms a timed auto-revert of the interface config; confirm cancels it; rollback restores immediately. |
| `timeout` | integer | — | Seconds before the auto-revert fires unless confirmed (state=create). Default 90. |

### `yoloman.network_interface`

Read (state=gathered) and configure (present/absent) host network interfaces, independent of the network provider

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `address` | string | — | IPv4 address in CIDR form (e.g. 10.0.0.5/24), required for method=static/manual. |
| `dns` | array of string | — | Optional list of DNS servers for method=static/manual. |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `gateway` | string | — | Optional default gateway for method=static/manual. |
| `mac` | string | — | Optional cloned/assigned MAC address (applied for any method). |
| `method` | one of `dhcp`, `static`, `manual` | — | IPv4 method for state=present. Default dhcp. |
| `mtu` | integer | — | Optional interface MTU (applied for any method). |
| `name` | string | — | The interface / connection name (required for present/absent). |
| `provider` | one of `networkmanager`, `netplan`, `networkd`, `ifupdown` | — | Force a specific network provider. Default is auto-detection (NetworkManager, then netplan, systemd-networkd, ifupdown). |
| `state` | one of `gathered`, `present`, `absent` | — | gathered reads current interfaces/addresses/routes/DNS (and the detected provider); present configures an interface via the host's provider; absent removes that config. |

### `yoloman.package_updates`

List and apply OS package updates (apt / dnf / yum), independent of the package manager

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `manager` | one of `apt`, `dnf`, `yum` | — | Force a package manager. Default is auto-detection (apt, then dnf, then yum). |
| `refresh` | boolean | — | For apt state=list, run `apt-get update` first to refresh the index. Default true. |
| `security_only` | boolean | — | For state=apply, install only security updates (apt uses unattended-upgrade when present; dnf uses --security). |
| `state` | one of `list`, `apply` | — | list reports pending updates (with a security count and reboot-required flag); apply installs them. |

### `yum`

Ensure one or more RPM packages are present, absent, or upgraded to the latest available version, via yum. Idempotent: queries the rpm database's current status before deciding whether to act. Unit-tested only in this project (no RPM-based host in the real verification environment — contrast with apt, this agent's real-tested primary target). Supports check_mode via dry_run=true, with one caveat: for state=latest, dry_run against an already-installed package conservatively predicts changed=true, since determining whether a newer version is truly available would itself require a repository query.

Cross-tool equivalents:
- Ansible: ansible.builtin.yum. Same name/state parameter names (name accepts either a single package or a list); a focused subset — Ansible's own module also supports enablerepo/disablerepo/update_cache and more, not yet implemented here.
- Chef: the `yum_package`/`package` resources.
- Puppet: the `package` type with `provider => yum`.
- Salt: the `pkg.installed`/`pkg.removed`/`pkg.latest` states.
- Terraform: not applicable — Terraform does not manage OS packages on a running host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | array of string | yes | One or more package names, e.g. ["httpd"] or ["httpd", "curl"]. |
| `dry_run` | boolean | — | When true, report what would change without issuing any mutating command (check_mode). For state=latest, an already-installed package conservatively predicts changed=true under dry_run, since determining whether a newer version truly exists would itself require a repository query — see the module description. |
| `state` | one of `present`, `absent`, `latest` | — | Desired package state. Default "present". |

### `yum_repository`

Ensure a yum/dnf repository definition (an INI-style [id] section) is present or absent in /etc/yum.repos.d/<file>.repo. Idempotent — only writes when the rendered stanza differs from the file's current content. Supports check_mode via dry_run=true. Unit-tested only in this project — no RPM-based host in the real verification environment (contrast with apt_repository, which is real-tested on Debian).

Cross-tool equivalents:
- Ansible: ansible.builtin.yum_repository. Covers the common name/description/baseurl/enabled/gpgcheck/gpgkey/file/state fields (a focused subset — Ansible's own module supports many more optional .repo keys, not implemented here).
- Chef: the `yum_repository` resource.
- Puppet: the `yumrepo` type.
- Salt: the `pkgrepo.managed`/`pkgrepo.absent` states.
- Terraform: not applicable — Terraform does not manage a running host's package manager configuration.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | Repository id — the INI section header, e.g. "myrepo". |
| `baseurl` | string | — | Repository base URL. Required for state=present. |
| `description` | string | — | Human-readable repo name (the .repo file's name= field). |
| `dry_run` | boolean | — | When true, report what would change without applying it (check_mode). |
| `enabled` | boolean | — | Whether the repository is enabled. Default true. |
| `file` | string | — | Target file name (without .repo) under /etc/yum.repos.d/. Defaults to name. |
| `gpgcheck` | boolean | — | Whether to verify package signatures. Default true. |
| `gpgkey` | string | — | Optional URL to the repository's GPG key. |
| `state` | one of `present`, `absent` | — | Whether the repository should be present or absent. Default "present". |

## Read-only modules

### `checkmk.lnx_if`

Interface %s

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `crit` | string | — | crit (from the check's parameters). |
| `warn` | string | — | warn (from the check's parameters). |

### `checkmk.systemd_units_services`

Systemd Service %s

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `active_since_lower` | string | — | active_since_lower (from the check's parameters). |
| `active_since_upper` | string | — | active_since_upper (from the check's parameters). |
| `cpu_time` | string | — | cpu_time (from the check's parameters). |
| `descriptions` | array of string | — | descriptions (from the check's parameters). |
| `else` | string | — | else (from the check's parameters). |
| `memory` | string | — | memory (from the check's parameters). |
| `names` | array of string | — | names (from the check's parameters). |
| `states` | array of string | — | states (from the check's parameters). |
| `states_default` | string | — | states_default (from the check's parameters). |
| `unit_type` | string | — | unit_type (from the check's parameters). |

### `checkmk.systemd_units_services_summary`

Systemd Service Summary

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `disabled_critical` | boolean | — | disabled_critical (from the check's parameters). |
| `ignored` | array of string | — | ignored (from the check's parameters). |

### `community.general.zfs_facts`

Gather facts about ZFS datasets

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | ZFS dataset name. |
| `depth` | integer | — | Specifies recursion depth. |
| `parsable` | boolean | — | Specifies if property values should be displayed in machine friendly format. |
| `properties` | string | — | Specifies which dataset properties should be queried in comma-separated format. For more information about dataset properties, check zfs(1M) man page. |
| `recurse` | boolean | — | Specifies if properties for any children should be recursively displayed. |
| `type` | one of `all`, `filesystem`, `volume`, `snapshot`, `bookmark` | — | Specifies which datasets types to display. Multiple values have to be provided in comma-separated form. |

### `community.general.zpool_facts`

Gather facts about ZFS pools

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | — | ZFS pool name. |
| `parsable` | boolean | — | Specifies if property values should be displayed in machine friendly format. |
| `properties` | string | — | Specifies which dataset properties should be queried in comma-separated format. For more information about dataset properties, check zpool(1M) man page. |

### `config_discover`

Discover the config files this host's enabled services actually use, by parsing each service's systemd unit (systemctl cat) — the ExecStart config arguments (-c/--config/--defaults-file/-f/…), EnvironmentFile=, and paths under known config roots — instead of guessing per package. Returns per-service unit paths + referenced config paths (existing files only), plus a flat, format-guessed list ready to feed the `config` module or the server-as-a-document state. Read-only. Optional `only`: limit to these service names.

Cross-tool equivalents:
- Ansible: service_facts + a `systemctl cat` loop + unit parsing (the kb-inventory method).
- Ties into: config (read/write the discovered files), state (manage them as a document).

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `only` | array of string | — | Limit discovery to these service names (default: all enabled services). |

### `debug`

Emit a message during a run (ansible.builtin.debug). `msg` is the text to show; {{ vars }} are substituted by the controller before the call, so pass the rendered message. Always read-only, never changes host state. Returns {"msg": <text>}.

Cross-tool equivalents:
- Ansible: ansible.builtin.debug (msg form).
- Salt: `test.echo` / a `debug` log statement.
- Chef: `log 'message'`.
- Puppet: `notify { 'message': }`.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `msg` |  | — | The message to print (any type; rendered to text). |
| `var` | string | — | A variable name to dump — normally rewritten to msg by the translator. |
| `verbosity` | integer | — | Only show at or above this -v level (accepted; always shown here). |

### `fetch`

Read a file's entire contents from this host, returned base64-encoded. In real Ansible, fetch copies a file FROM the managed host TO the separate machine running Ansible; this agent has no such separate control-node filesystem, so fetch and slurp (see that tool) are the same operation here — use whichever name matches the task syntax you're translating from.

Cross-tool equivalents:
- Ansible: ansible.builtin.fetch. Same intent (retrieve a file's content), different parameter name (`src` here vs. `dest` being irrelevant since there's no separate destination filesystem to copy into).
- Chef/Puppet/Salt/Terraform: see slurp's description — the underlying operation (read a live file's content) is identical.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `src` | string | yes | File to read, e.g. "/etc/nginx/nginx.conf". |

### `find`

Search one or more directories for entries matching a glob pattern and/or type, optionally recursing into subdirectories. Returns a list of {path, isdir, size} for every match. Use this to discover what already exists on disk before deciding what file/copy/template operations are needed (e.g. "find all *.conf files under /etc/nginx/conf.d"), or to answer an inventory question about the filesystem.

Cross-tool equivalents:
- Ansible: ansible.builtin.find. Same paths/pattern/recurse/file_type parameter names and meaning (a subset of Ansible's fuller option set).
- Chef: `Dir.glob(pattern)` in recipe/library Ruby code.
- Puppet: the `fileset()` built-in function, or a custom fact enumerating files.
- Salt: the `file.find` execution module.
- Terraform: the `fileset()` built-in configuration function (evaluated against the machine running `terraform plan`, not a remote managed host).

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `paths` | array of string | yes | One or more directories to search, e.g. ["/etc/nginx/conf.d"]. |
| `file_type` | one of `any`, `file`, `directory` | — | Restrict matches by entry type. Default "any". |
| `pattern` | string | — | Optional glob pattern matched against each entry's base name, e.g. "*.conf". Empty means match everything. |
| `recurse` | boolean | — | Whether to descend into subdirectories. Default false (only direct children of each path). |

### `getent`

Query an NSS (Name Service Switch) database — passwd, group, hosts, shadow, services, and so on — via the `getent` command, optionally for one specific key (e.g. a single username). Returns each matched line's raw colon-separated fields plus its name/key. Use this to check whether a user/group already exists (and with what uid/gid/home/shell) before deciding to call a write-gated `user`/`group` module.

Cross-tool equivalents:
- Ansible: ansible.builtin.getent. Same database/key parameters and colon-split field semantics; result mirrors ansible_facts['getent_<database>'].
- Chef: Ruby's `Etc.getpwnam`/`Etc.getgrnam` (for passwd/group) in a recipe/library; other databases would be queried by shelling out to getent directly.
- Puppet: no dedicated type; Puppet's own `user`/`group` resources read this state internally, but ad hoc queries are done via a custom fact or `generate()`.
- Salt: the `user.info`/`group.info` execution modules for passwd/group; other databases via `cmd.run('getent ...')`.
- Terraform: not applicable — Terraform does not query remote NSS state directly; this would be done via a `null_resource` provisioner shelling out to getent.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `database` | string | yes | NSS database to query, e.g. "passwd", "group", "hosts", "shadow", "services". |
| `key` | string | — | Optional specific entry to look up, e.g. a username "deploy". Omit to list every entry in that database (matches the getent CLI's own behavior). |

### `journal`

Read the systemd journal (journald) via `journalctl -o json`, optionally filtered by unit, priority, a time window, or a message pattern. Returns the most recent N entries (newest last), each as {timestamp, unit, priority, message, pid, hostname}. Read-only — it never writes and always reports changed=false. Use this to answer 'what has this service been logging' / 'why did it fail' without shell access, as the Logs section of the host-management page and as an MCP tool.

Parameters: lines (default 200, capped at 5000), unit (a systemd unit like "nginx"), priority (0-7 or a name like "err"; shows that level and worse), since (any journalctl time spec, e.g. "2024-01-01 10:00", "-1h", "yesterday"), boot (true = current boot only), grep (a message regex).

Cross-tool equivalents:
- Ansible: no first-class module; typically `ansible.builtin.command: journalctl ...` then parse, or the community `syslog`/log-reading roles. This module makes it structured.
- Chef/Puppet/Salt: normally a `shell_out`/`cmd.run` around journalctl; none ship a dedicated journald-reading resource.
- Terraform: not applicable — Terraform does not read live host logs.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `boot` | boolean | — | When true, restrict to the current boot only (journalctl --boot). |
| `grep` | string | — | Only entries whose MESSAGE matches this (journalctl --grep, a regex). |
| `lines` | integer | — | How many of the most recent entries to return (default 200, capped at 5000). |
| `priority` | string | — | Restrict to this syslog priority and worse: 0-7 (emerg..debug) or a name like "err", "warning", "info". |
| `since` | string | — | Only entries at/after this time. Any journalctl time spec: "2024-01-01 10:00", "-1h", "yesterday". |
| `unit` | string | — | Restrict to one systemd unit, e.g. "nginx" or "nginx.service". |

### `logfiles`

List and tail plain-text log files under /var/log and any operator-configured custom log paths. Read-only and path-jailed: a file can only be listed/read if it resolves to within an allowed root (/var/log plus extra_paths), so it can never read arbitrary files like /etc/shadow.

state=list (default) enumerates the log files (path, size, modified) under the roots, skipping the binary journal dir and utmp/wtmp-style databases. state=read tails a single file — the last `lines` lines (default 200, capped at 5000), optionally filtered by `grep`: a plain substring, an extended regular expression when regex=true (like grep -E), and inverted when invert=true (keep non-matching lines, like grep -v).

Companion to the `journal` module (journald); together they give the operator a full log view and feed the AI's error-source analysis alongside the eBPF metrics.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `extra_paths` | array of string | — | Additional custom log files or directories to include (operator-configured). |
| `grep` | string | — | For state=read: keep only lines matching this pattern (plain substring by default; an extended regular expression when regex=true). Like grep's PATTERN. |
| `invert` | boolean | — | For state=read: return the lines that do NOT match `grep` (like grep -v). |
| `lines` | integer | — | For state=read: how many trailing lines (default 200, capped at 5000). |
| `path` | string | — | For state=read: the log file to tail (must resolve within an allowed root). |
| `regex` | boolean | — | For state=read: interpret `grep` as an extended regular expression (like grep -E) instead of a plain substring. |
| `state` | string | — | "list" (default) enumerates log files; "read" tails one file. |

### `package_facts`

Enumerate every package installed on the host (name, version, architecture). Uses dpkg on Debian/Ubuntu and falls back to rpm on RHEL/Fedora-family systems. Takes no parameters — it always returns the full list; filter client-side for a specific package. Use this to check whether a desired package is already at the right version before deciding to call the write-gated `apt`/`package` module.

Cross-tool equivalents:
- Ansible: ansible.builtin.package_facts (with use=apt). Same underlying dpkg query; result shape mirrors ansible_facts['packages'].
- Chef: the Ohai `packages` plugin (node['packages']).
- Puppet: Facter's package facts, or `puppet resource package`.
- Salt: the `pkg.list_pkgs` execution module.
- Terraform: not applicable — Terraform does not introspect installed packages on a running host; package presence is normally asserted, not queried, via a provisioner.

_Takes no parameters._

### `ping`

Trivial connectivity/health check — call it to confirm this agent is reachable and responding. Takes no parameters, always succeeds, returns {"ping": "pong"}.

Cross-tool equivalents:
- Ansible: ansible.builtin.ping. Ansible's real ping also confirms a usable Python interpreter on the managed host; this agent has no separate interpreter to verify — a successful tool call response is itself the proof.
- Chef: `knife ssh <host> 'echo pong'`, or simply a successful `chef-client` run.
- Puppet: `puppet agent --test` completing, or a successful catalog compile.
- Salt: the `test.ping` execution module.
- Terraform: not applicable — Terraform has no live-connectivity health-check primitive of its own.

_Takes no parameters._

### `service_facts`

Enumerate every systemd service unit known to the host (via `systemctl list-units --type=service --all`) along with its load/active/sub state (e.g. loaded/active/running, loaded/failed/failed, not-found/inactive/dead). Takes no parameters — it always returns the full list; filter client-side for a specific service. Use this to check whether a desired service is already running before deciding to call the write-gated `service`/`systemd` module, or to answer 'what services are on this box' questions.

Cross-tool equivalents:
- Ansible: ansible.builtin.service_facts. Same underlying `systemctl list-units` approach; result shape mirrors ansible_facts['services'].
- Chef: no direct fact-gathering equivalent; typically queried ad hoc via a `shell_out('systemctl ...')` in a recipe/library, since Ohai does not enumerate services by default.
- Puppet: `puppet resource service` lists resources of type service with their ensure/enable state.
- Salt: the `service.get_all` and `service.status` execution modules.
- Terraform: not applicable — Terraform does not perform live runtime service introspection; this kind of check would be done via a `null_resource` `local-exec`/`remote-exec` provisioner shelling out to systemctl.

_Takes no parameters._

### `set_fact`

Set variables for the rest of the run (ansible.builtin.set_fact). Pass the facts as free-form key: value parameters (values may reference {{ other_vars }}, substituted by the controller first). Read-only with respect to the host — it changes only the run's variable namespace via the returned yoloman_facts. `cacheable` is accepted and ignored.

Cross-tool equivalents:
- Ansible: ansible.builtin.set_fact.
- Salt: a `grains.set` (persisted) or a jinja `{% set %}` (transient).
- Chef: `node.default['x'] = ...` / `node.run_state`.
- Puppet: a variable assignment `$x = ...`.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `cacheable` | boolean | — | Persist across runs (accepted, no-op here). |

### `setup`

Gather baseline facts about this host: hostname, kernel release, CPU architecture, Linux distribution/version, total memory (MB), and logical CPU count. Takes no parameters. Call this first when reconciling any desired-state description against a real machine — it is the starting point for the 'read current state' step before planning changes.

Cross-tool equivalents (use this mapping to translate other formats into agentic-mcp calls):
- Ansible: ansible.builtin.setup / the automatic 'gather_facts' step at play start. Native keys use the yoloman_ prefix (yoloman_hostname, yoloman_kernel, yoloman_architecture, yoloman_distribution, yoloman_distribution_version, yoloman_memtotal_mb, yoloman_processor_vcpus); the ansible_ keys are also returned as compat aliases for imported Ansible content.
- Chef: the automatic Ohai run that populates node attributes (node['hostname'], node['kernel'], node['platform'], node['platform_version'], node['memory']['total'], node['cpu']['total']).
- Puppet: Facter facts available as top-scope variables ($facts['networking']['hostname'], $facts['kernelrelease'], $facts['os']['name'], $facts['os']['release']['full'], $facts['memory']['system']['total'], $facts['processors']['count']).
- Salt: grains (grains['host'], grains['kernelrelease'], grains['os'], grains['osrelease'], grains['mem_total'], grains['num_cpus']).
- Terraform: has no direct remote-facts equivalent (Terraform is declarative and provider-driven); the closest analogues are a provider's computed data source attributes or an `external`/`http` data source that shells out to gather machine facts before apply.

_Takes no parameters._

### `slurp`

Read a file's entire contents from the managed host, returned base64-encoded (so binary files are safe to transport as JSON). Use this to inspect the current content of a config file before deciding whether/how to change it (e.g. compare against a desired template render), or to retrieve a small file's content for display. Not intended for very large files — there is no streaming, the whole file is loaded into memory and encoded at once.

Cross-tool equivalents:
- Ansible: ansible.builtin.slurp. Identical semantics: {content: base64, encoding: "base64"}.
- Chef: `::File.read(path)` in a recipe, or a `data_bag_item` for pre-managed content.
- Puppet: the `file()` function (reads a local module file at compile time, not a remote agent-side file — this tool is closer to an ad-hoc `puppet apply` fact or a custom function reading the live agent filesystem).
- Salt: `cp.get_file_str` or the `file.read` execution module.
- Terraform: `data "local_file"` (its `content`/`content_base64` attribute), for files local to the machine running Terraform.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | File to read, e.g. "/etc/nginx/nginx.conf". |

### `stat`

Inspect a single filesystem path without reading its content: whether it exists, its size in bytes, permission mode (octal string, e.g. "0644"), owning uid/gid, whether it is a regular file, directory, or symlink, and its modification time (Unix seconds). Returns {"exists": false, "path": ...} if nothing is at that path — this is not an error, callers should check the "exists" field. Use this before a file/copy/template operation to check whether a change is actually needed (idempotency check), or to verify a prior write took effect.

Cross-tool equivalents:
- Ansible: ansible.builtin.stat. Same field semantics (exists, size, mode, isdir, isreg, issymlink, uid, gid, mtime).
- Chef: the implicit current-resource lookup a `file`/`directory`/`template` resource performs internally (File.stat), or explicit Ruby `::File.exist?`/`::File.stat` in a recipe/library.
- Puppet: no dedicated introspection type; closest is querying the `file` resource's current state via `puppet resource file <path>`, or a custom fact.
- Salt: the `file.stats` execution module.
- Terraform: a `data "local_file"` data source (for the machine running Terraform) or a `null_resource` with a `remote-exec`/`local-exec` provisioner running `stat` for a managed host.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | Filesystem path to inspect, e.g. "/etc/nginx/nginx.conf" or "/opt/app". |

### `storage_facts`

Gather a read-only storage overview of the host: block devices (lsblk), LVM physical volumes / volume groups / logical volumes (pvs/vgs/lvs), and VDO volumes (vdostats). Returns {block_devices, lvm, vdo}, each with an `available` flag that is false (plus an `error`) when the underlying tool is absent or fails — so it never crashes on a host without LVM/VDO. Read-only: always changed=false. Pairs with the write-gated community.general lvg/lvol/vdo modules for management, and with zfs_facts/zpool_facts for ZFS (not covered here). Use it as the Storage section of the host-management page and as an MCP tool.

Cross-tool equivalents: no single Ansible module covers all three; this aggregates what `ansible.builtin.setup`'s device facts, community.general.lvg/lvol, and vdostats expose.

_Takes no parameters._

### `virt_facts`

Detect the host's local virtualization stack(s) and list their guests: Proxmox VE (via the `qm list` / `pct list` CLIs — QEMU VMs and LXC containers) and libvirt/KVM (via `virsh list --all` — domains). Returns {proxmox:{available,vms,containers}, libvirt:{available,domains}, hypervisors:[...]}, where each stack's `available` is false (with an `error`) when its CLI is absent — so it never fails on a non-hypervisor host. Read-only (changed=false). Pair with the write-gated `qm` / `virsh` modules to control a guest. Use it to answer 'is this a Proxmox node or a KVM host, and what is running on it'.

Note: this is LOCAL node management via the on-host CLIs, distinct from the community.general.proxmox_* modules which drive a Proxmox cluster remotely over its API.

_Takes no parameters._

### `wait_for`

Block until a condition is met: either a TCP port accepts connections (state=started, the default, when `port` is given) or stops accepting them (state=stopped), or a file exists (state=present, when `path` is given instead of `port`) or doesn't (state=absent). Polls every `sleep` seconds (default 1) until `timeout` seconds elapse (default 300, capped at 600 here to bound how long a single tool call can block). Read-only — it never changes system state, only observes it, so it does not require write:true.

Cross-tool equivalents:
- Ansible: ansible.builtin.wait_for. Same host/port/path/state/timeout/delay/sleep semantics (a focused subset — Ansible also supports regex content matching inside the file and searching for a string in the port's banner, not implemented here).
- Chef: no single built-in resource; typically a custom resource polling in a loop, or the community 'wait_for_port'-style helpers.
- Puppet: no core equivalent; typically handled by an external orchestration tool rather than the Puppet run itself.
- Salt: no single built-in state; typically a custom module or an `cmd.run` loop.
- Terraform: the `time_sleep` resource (fixed delay only, no actual condition-polling) or a provisioner script loop.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `delay` | string | — | Seconds to wait before the first check. Default "0". |
| `host` | string | — | Host to connect to when checking a port. Default "127.0.0.1". |
| `path` | string | — | File path to wait for. Mutually exclusive with port. |
| `port` | string | — | TCP port to wait for. Mutually exclusive with path. |
| `sleep` | string | — | Seconds between checks. Default "1". |
| `state` | one of `started`, `stopped`, `present`, `absent` | — | Condition to wait for. Default "started". |
| `timeout` | string | — | Maximum seconds to wait before failing. Default "300", capped at 600. |

### `yoloman.agent_selfcheck`

Agent self-check

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `crit_ms` | string | — | Crit when it takes at least this many milliseconds. |
| `port` | string | — | The agent's own listening port on this host. 8051 is the Go agent's default; the Windows agent is often on 8451. |
| `warn_ms` | string | — | Warn when the local connection to the agent's port takes at least this many milliseconds. |

