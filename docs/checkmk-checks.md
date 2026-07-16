# Checkmk check library

Auto-generated from `configs/checks.d/*.nt` by `scripts/generate_check_docs.py` — do not edit by hand. Each check is a read-only Starlark module translated from Checkmk; the prose below is the translation's own documentation.

**1433 checks** in **11 categories**.

## Categories

| Category | Checks |
| --- | ---: |
| [Operating System](#check-operating-system) | 3 |
| [Hardware & Sensors](#check-hardware-sensors) | 153 |
| [Storage](#check-storage) | 27 |
| [Network](#check-network) | 32 |
| [Applications](#check-applications) | 61 |
| [Database](#check-database) | 8 |
| [Virtualization & Cloud](#check-virtualization-cloud) | 2 |
| [Environment & Power](#check-environment-power) | 17 |
| [Security](#check-security) | 3 |
| [Other](#check-other) | 15 |
| [Uncategorized](#check-uncategorized) | 1112 |

## Operating System

<a id="check-operating-system"></a>

| Check | Summary |
| --- | --- |
| [aix_paging](#check-aix-paging) | Page Space %s |
| [apt](#check-apt) | APT Updates |
| [uptime](#check-uptime) | Uptime |

### aix_paging

<a id="check-aix-paging"></a>

*Page Space %s*

#### Overview
This check monitors AIX paging space utilization to ensure the system has sufficient virtual memory resources and to alert on potential memory pressure.

#### What it monitors
- Paging space (virtual memory) usage percentage
- Paging space attributes: active status, auto-start configuration, and type (e.g., logical volume or NFS)
- Total size and current usage of each paging space device

#### How it works
On discovery (`_discover` mode), it runs `lsps -a`, parses the output to identify all paging spaces, and constructs service items in the format `device/vg`. In regular mode, it locates the specified item from `lsps -a` output, extracts usage percentage, and compares it against user-configured warning/critical thresholds (default: 80%/90% high, 50%/30% low). States are determined based on whether usage exceeds high thresholds or falls below low thresholds.

#### Parameters
- `levels` (tuple of floats, default `(80.0, 90.0)`) — warning and critical thresholds for high usage.
- `levels_low` (tuple of floats, default `(50.0, 30.0)`) — warning and critical thresholds for low usage (inverted logic: low usage can also be problematic).
- `magic_norm_size` (int, default `4`) — internal normalization size for thresholds.
- `show_levels` (string, default `"onmagic"`) — controls when thresholds are displayed.
- `show_reserved` (bool, default `True`) — whether to show reserved space details.

#### States
- **OK**: Usage is within normal range (between low and high thresholds).
- **WARN**: Usage exceeds warning threshold (>80%) or drops below low warning threshold (≤50%).
- **CRIT**: Usage exceeds critical threshold (>90%) or drops below low critical threshold (≤30%).
- **UNKNOWN**: Specified paging space item not found.

#### Metrics
- `used_percent` — current paging space usage as a percentage (unit: %).

### apt

<a id="check-apt"></a>

*APT Updates*

#### Overview
Monitors available APT package updates on Debian/Ubuntu systems, distinguishing between normal, security, and removal updates to assess system patch status and security posture.

#### What it monitors
- Number of normal (non-security) package updates
- Number of security-related updates
- Number of packages to be automatically removed during an upgrade

#### How it works
In discovery mode, it reports one service with default thresholds. In check mode, it runs `apt list --upgradable` to list pending updates and categorizes them by security keywords. It then runs `apt-get dist-upgrade --dry-run` to count removals. On Ubuntu, it checks ESM support and activation via file checks and `ua status`. State is set based on configurable thresholds (`normal`, `removals`, `security`) and ESM status.

#### Parameters
None.

#### States
- **OK**: No updates pending or within threshold limits; ESM enabled if supported.
- **WARN**: Updates pending but below critical thresholds.
- **CRIT**: Updates exceed thresholds, or ESM is supported but not enabled (Ubuntu only), or `apt` commands fail.
- **UNKNOWN**: Not applicable for this check; no explicit UNKNOWN logic in source.

#### Metrics
- `normal_updates` — count of non-security updates
- `security_updates` — count of security updates
- `removals` — count of packages to be removed

### uptime

<a id="check-uptime"></a>

*Uptime*

#### Overview
This check monitors the system uptime—the duration since the host was last booted—providing insight into system stability and planned reboots.

#### What it monitors
- System uptime in seconds, derived from `/proc/uptime` on Linux or parsed from the `uptime` command output on other OSes.

#### How it works
On Linux (Red Hat or Debian families), it reads `/proc/uptime` and extracts the first field (uptime in seconds). On other systems, it executes `uptime` and parses human-readable time components (days, hours, minutes) from the output using string scanning. It converts all durations to total seconds for metrics and constructs a human-readable message. The check always reports state `OK`; no thresholds or parameters affect status.

#### Parameters
None.

#### States
OK: Always. The check does not implement warning or critical thresholds; it simply reports uptime.

#### Metrics
`uptime` — system uptime in seconds.

## Hardware & Sensors

<a id="check-hardware-sensors"></a>

| Check | Summary |
| --- | --- |
| [3ware_disks](#check-3ware-disks) | RAID 3ware disk %s |
| [3ware_info](#check-3ware-info) | RAID 3ware controller %s |
| [3ware_units](#check-3ware-units) | RAID 3ware unit %s |
| [acme_fan](#check-acme-fan) | Fan %s |
| [acme_powersupply](#check-acme-powersupply) | Power supply %s |
| [acme_temp](#check-acme-temp) | Temperature %s |
| [acme_voltage](#check-acme-voltage) | Voltage %s |
| [adva_fsp_current](#check-adva-fsp-current) | Power Supply %s |
| [adva_fsp_temp](#check-adva-fsp-temp) | Temperature %s |
| [akcp_daisy_temp](#check-akcp-daisy-temp) | Temperature %s |
| [akcp_exp_drycontact](#check-akcp-exp-drycontact) | Dry Contact %s |
| [akcp_exp_temp](#check-akcp-exp-temp) | Temperature %s |
| [akcp_sensor_drycontact](#check-akcp-sensor-drycontact) | Dry Contact %s |
| [akcp_sensor_humidity](#check-akcp-sensor-humidity) | Humidity %s |
| [alcatel_cpu](#check-alcatel-cpu) | CPU utilization |
| [alcatel_cpu_aos7](#check-alcatel-cpu-aos7) | CPU utilization |
| [alcatel_fans](#check-alcatel-fans) | Fan %s |
| [alcatel_fans_aos7](#check-alcatel-fans-aos7) | Fan %s |
| [alcatel_power](#check-alcatel-power) | Power Supply %s |
| [alcatel_power_aos7](#check-alcatel-power-aos7) | Power Supply %s |
| [alcatel_temp](#check-alcatel-temp) | Temperature %s |
| [alcatel_temp_aos7](#check-alcatel-temp-aos7) | Temperature Board %s |
| [alcatel_timetra_cpu](#check-alcatel-timetra-cpu) | CPU utilization |
| [allnet_ip_sensoric_humidity](#check-allnet-ip-sensoric-humidity) | Humidity %s |
| [allnet_ip_sensoric_pressure](#check-allnet-ip-sensoric-pressure) | Pressure %s |
| [allnet_ip_sensoric_temp](#check-allnet-ip-sensoric-temp) | Temperature %s |
| [apc_ats_output](#check-apc-ats-output) | Phase %s output |
| [apc_inputs](#check-apc-inputs) | Input %s |
| [apc_inrow_airflow](#check-apc-inrow-airflow) | Airflow |
| [apc_inrow_fanspeed](#check-apc-inrow-fanspeed) | Fanspeed |
| [apc_netbotz_other_sensors](#check-apc-netbotz-other-sensors) | Numeric sensors summary |
| [apc_netbotz_smoke](#check-apc-netbotz-smoke) | Smoke Detector %s |
| [apc_netshelterpdu_power](#check-apc-netshelterpdu-power) | PDU %s |
| [apc_powerswitch](#check-apc-powerswitch) | Power Outlet Port %s |
| [apc_rackpdu_power](#check-apc-rackpdu-power) | PDU %s |
| [apc_sts_inputs](#check-apc-sts-inputs) | Input %s |
| [apc_sts_source](#check-apc-sts-source) | Source |
| [apc_symmetra](#check-apc-symmetra) | APC Symmetra status |
| [apc_symmetra_elphase](#check-apc-symmetra-elphase) | Phase %s |
| [apc_symmetra_ext_temp](#check-apc-symmetra-ext-temp) | Temperature External %s |
| [apc_symmetra_output](#check-apc-symmetra-output) | Phase %s |
| [apc_symmetra_temp](#check-apc-symmetra-temp) | Temperature %s |
| [apc_symmetra_test](#check-apc-symmetra-test) | Self Test |
| [arbor_peakflow_sp_disk_usage](#check-arbor-peakflow-sp-disk-usage) | Disk Usage %s |
| [arbor_pravail_host_fault](#check-arbor-pravail-host-fault) | Host Fault |
| [arris_cmts_cpu](#check-arris-cmts-cpu) | CPU utilization Module %s |
| [arris_cmts_temp](#check-arris-cmts-temp) | Temperature Module %s |
| [artec_temp](#check-artec-temp) | Temperature %s |
| [aruba_chassis_temp](#check-aruba-chassis-temp) | Temperature %s |
| [aruba_cpu_util](#check-aruba-cpu-util) | CPU utilization %s |
| [aruba_fan_status](#check-aruba-fan-status) | Fan Status %s |
| [aruba_psu_status](#check-aruba-psu-status) | PSU Status %s |
| [aruba_psu_temp](#check-aruba-psu-temp) | PSU Temperature %s |
| [aruba_psu_wattage](#check-aruba-psu-wattage) | PSU Wattage %s |
| [aruba_sw_temp](#check-aruba-sw-temp) | Temperature %s |
| [atto_fibrebridge_chassis](#check-atto-fibrebridge-chassis) | Throughput Status |
| [atto_fibrebridge_chassis_temp](#check-atto-fibrebridge-chassis-temp) | Temperature %s |
| [atto_fibrebridge_sas](#check-atto-fibrebridge-sas) | SAS Port %s |
| [audiocodes_fru](#check-audiocodes-fru) | FRU %s |
| [audiocodes_leds](#check-audiocodes-leds) | LED Status |
| [audiocodes_operational_state](#check-audiocodes-operational-state) | Operational state module %s |
| [audiocodes_operational_state_redundant](#check-audiocodes-operational-state-redundant) | Operational state redundant module %s |
| [audiocodes_temperature](#check-audiocodes-temperature) | Temperature %s |
| [avaya_45xx_cpu](#check-avaya-45xx-cpu) | CPU utilization CPU %s |
| [avaya_45xx_fan](#check-avaya-45xx-fan) | Fan Chassis %s |
| [avaya_45xx_temp](#check-avaya-45xx-temp) | Temperature Chassis %s |
| [avaya_88xx](#check-avaya-88xx) | Temperature Fan %s |
| [avaya_88xx_fan](#check-avaya-88xx-fan) | Fan %s Status |
| [avaya_chassis_card](#check-avaya-chassis-card) | Card %s |
| [avaya_chassis_ps](#check-avaya-chassis-ps) | Power Supply %s |
| [avaya_chassis_temp](#check-avaya-chassis-temp) | Temperature %s |
| [bdtms_tape_info](#check-bdtms-tape-info) | Tape Library Info |
| [bdtms_tape_module](#check-bdtms-tape-module) | Tape Library Module %s |
| [bintec_cpu](#check-bintec-cpu) | CPU utilization |
| [bintec_sensors_fan](#check-bintec-sensors-fan) | %s |
| [bintec_sensors_temp](#check-bintec-sensors-temp) | Temperature %s |
| [bintec_sensors_voltage](#check-bintec-sensors-voltage) | Voltage %s |
| [blade_bays](#check-blade-bays) | BAY %s |
| [blade_blades](#check-blade-blades) | Blade %s |
| [blade_blowers](#check-blade-blowers) | Blower %s |
| [blade_bx_blades](#check-blade-bx-blades) | Blade %s |
| [blade_bx_load](#check-blade-bx-load) | CPU load |
| [blade_bx_powerfan](#check-blade-bx-powerfan) | Blade Cooling %s |
| [blade_bx_powermod](#check-blade-bx-powermod) | Power Module %s |
| [blade_bx_temp](#check-blade-bx-temp) | Temperature Blade %s |
| [blade_health](#check-blade-health) | Summary health state |
| [blade_mediatray](#check-blade-mediatray) | Media tray |
| [blade_powerfan](#check-blade-powerfan) | Power Module Cooling Device %s |
| [blade_powermod](#check-blade-powermod) | Power Module %s |
| [bluecoat_diskcpu](#check-bluecoat-diskcpu) | %s |
| [bluenet2_powerrail](#check-bluenet2-powerrail) | Inlet %s |
| [bluenet2_powerrail_fuses](#check-bluenet2-powerrail-fuses) | Fuse %s |
| [bluenet2_powerrail_inlet](#check-bluenet2-powerrail-inlet) | Inlet %s |
| [bluenet2_powerrail_rcm](#check-bluenet2-powerrail-rcm) | Inlet %s |
| [bluenet2_powerrail_sockets](#check-bluenet2-powerrail-sockets) | Socket %s |
| [bluenet_sensor_hum](#check-bluenet-sensor-hum) | Humidity %s |
| [brocade_fan](#check-brocade-fan) | FAN %s |
| [brocade_info](#check-brocade-info) | Brocade Info |
| [brocade_mlx_fan](#check-brocade-mlx-fan) | Fan %s |
| [brocade_mlx_module_mem](#check-brocade-mlx-module-mem) | Memory Module %s |
| [brocade_mlx_module_status](#check-brocade-mlx-module-status) | Status Module %s |
| [brocade_mlx_power](#check-brocade-mlx-power) | Power supply %s |
| [brocade_mlx_temp](#check-brocade-mlx-temp) | Temperature %s |
| [brocade_power](#check-brocade-power) | Power supply %s |
| [brocade_sys](#check-brocade-sys) | CPU utilization |
| [brocade_sys_mem](#check-brocade-sys-mem) | Memory |
| [brocade_temp](#check-brocade-temp) | Temperature Ambient %s |
| [brocade_vdx_status](#check-brocade-vdx-status) | Status |
| [bvip_info](#check-bvip-info) | System Info |
| [bvip_poe](#check-bvip-poe) | POE Power |
| [bvip_temp](#check-bvip-temp) | Temperature %s |
| [bvip_util](#check-bvip-util) | CPU utilization %s |
| [cadvisor_diskstat](#check-cadvisor-diskstat) | Disk IO %s |
| [canon_pages](#check-canon-pages) | Pages |
| [casa_fan](#check-casa-fan) | Fan %s |
| [cbl_airlaser_hardware](#check-cbl-airlaser-hardware) | CBL Airlaser Hardware |
| [checkpoint_fan](#check-checkpoint-fan) | Fan %s |
| [checkpoint_ha_status](#check-checkpoint-ha-status) | HA Status |
| [checkpoint_memory](#check-checkpoint-memory) | Memory System |
| [checkpoint_temp](#check-checkpoint-temp) | Temperature %s |
| [checkpoint_voltage](#check-checkpoint-voltage) | Voltage %s |
| [ciena_cpu_util_5142](#check-ciena-cpu-util-5142) | CPU utilization |
| [ciena_health](#check-ciena-health) | Health |
| [ciena_temperature](#check-ciena-temperature) | Temperature %s |
| [cisco_asa_failover](#check-cisco-asa-failover) | Failover state |
| [cisco_fan](#check-cisco-fan) | FAN %s |
| [cisco_fantray](#check-cisco-fantray) | Fan %s |
| [cisco_fru_module_status](#check-cisco-fru-module-status) | FRU Module Status %s |
| [cisco_fru_power](#check-cisco-fru-power) | FRU Power %s |
| [cisco_ie_temp](#check-cisco-ie-temp) | Temperature %s |
| [cisco_meraki_org_device_status_ps](#check-cisco-meraki-org-device-status-ps) | Power Supply %s |
| [cisco_sma_cpu_utilization](#check-cisco-sma-cpu-utilization) | CPU utilization |
| [cisco_temp](#check-cisco-temp) | Temperature %s |
| [cisco_ucs_cpu](#check-cisco-ucs-cpu) | CPU %s |
| [cisco_ucs_fan](#check-cisco-ucs-fan) | Fan %s |
| [cisco_ucs_faults](#check-cisco-ucs-faults) | Cisco UCS Faults |
| [cisco_ucs_mem_total](#check-cisco-ucs-mem-total) | Memory total |
| [cisco_ucs_psu](#check-cisco-ucs-psu) | psu %s |
| [cisco_ucs_raid](#check-cisco-ucs-raid) | RAID Controller |
| [cisco_ucs_system](#check-cisco-ucs-system) | System health |
| [cisco_ucs_temp_cpu](#check-cisco-ucs-temp-cpu) | Temperature CPU %s |
| [cisco_ucs_temp_env](#check-cisco-ucs-temp-env) | Temperature %s |
| [cisco_ucs_temp_mem](#check-cisco-ucs-temp-mem) | Temperature Mem %s |
| [cmciii_io](#check-cmciii-io) | %s |
| [cmciii_lcp_fans](#check-cmciii-lcp-fans) | LCP Fanunit FAN %s |
| [cmciii_lcp_waterflow](#check-cmciii-lcp-waterflow) | LCP Fanunit WATER FLOW |
| [cmciii_temp](#check-cmciii-temp) | Temperature %s |
| [cmciii_temp_in_out](#check-cmciii-temp-in-out) | Temperature %s |
| [cmctc_lcp_blower](#check-cmctc-lcp-blower) | Blower %s |
| [cmctc_lcp_current](#check-cmctc-lcp-current) | Current %s |
| [cmctc_lcp_temp](#check-cmctc-lcp-temp) | Temperature %s |
| [cmctc_ports](#check-cmctc-ports) | Port %s |
| [cmctc_psm_m](#check-cmctc-psm-m) | CMC %s |

### 3ware_disks

<a id="check-3ware-disks"></a>

*RAID 3ware disk %s*

#### Overview
Monitors the status of individual disks in 3ware RAID controllers, providing early warning of drive failures that could compromise array redundancy.

#### What it monitors
- Per-disk status (e.g., OK, degraded, failed)
- Disk model, serial number, and firmware version
- Disk size and health indicators
- Controller-specific details like RPM, interface type, and physical location

#### How it works
The check relies on the yolo-man agent’s `<<<3ware_disks>>>` section, which is generated by the agent when 3ware utilities (e.g., `tw_cli`) are installed. During discovery, it parses the agent’s output to enumerate each disk as a separate service item. In check mode, it evaluates the status field of each disk: a disk in "OK" state yields OK; non-OK states (e.g., "FAIL", "DEGRADED") trigger WARN or CRIT depending on the exact status.

#### Parameters
None.

#### States
- **OK**: All monitored disks report "OK" status.
- **WARN/CRIT**: One or more disks report non-OK status (e.g., "FAIL", "DEGRADED", "OFFLINE").
- **UNKNOWN**: No 3ware disks data is available (e.g., agent section missing, no controller present).

#### Metrics
None.

### 3ware_info

<a id="check-3ware-info"></a>

*RAID 3ware controller %s*

#### Overview
This check monitors the presence and status of 3ware RAID controllers using the `tw_cli` utility. It matters because RAID controller health and visibility are critical for data integrity and system reliability.

#### What it monitors
- Availability of 3ware RAID controllers via `tw_cli show`
- Per-controller identification and basic status information (model, serial, firmware, etc.)

#### How it works
In discovery mode (`_discover: true`), it runs `tw_cli show`, parses controller entries (skipping the first two header lines), and returns discovered items. In normal mode, it retrieves controller details by the specified `item` (e.g., `c0`) and reports OK with a concatenated info string if found, or UNKNOWN if not. No state transitions (WARN/CRIT) are defined.

#### Parameters
None.

#### States
- **OK**: Controller item is found and details are retrieved successfully.
- **UNKNOWN**: Controller item not found, `tw_cli show` fails, or discovery fails.
- **WARN/CRIT**: Not defined by this check.

#### Metrics
None.

### 3ware_units

<a id="check-3ware-units"></a>

*RAID 3ware unit %s*

#### Overview
Monitors the status of RAID units managed by 3ware RAID controllers using the `tw_cli` tool, ensuring RAID health and timely detection of failures or rebuilds.

#### What it monitors
- RAID unit name (e.g., `u0`)
- Unit type (e.g., RAID0, RAID1)
- Current status (e.g., OK, DEGRADED, REBUILDING)
- Unit size in GB
- Rebuild/verification completion percentage (if applicable)

#### How it works
Discovers units via `tw_cli show` in discovery mode; for checks, parses `tw_cli show` output to extract per-unit data. Status determines state: `OK`/`VERIFYING` → OK; `INITIALIZING`/`VERIFY-PAUSED`/`REBUILDING` → WARN; all other statuses → CRIT. Returns UNKNOWN if unit not found.

#### Parameters
None.

#### States
- **OK**: Status is OK or VERIFYING
- **WARN**: Status is INITIALIZING, VERIFY-PAUSED, or REBUILDING
- **CRIT**: Any other status (e.g., DEGRADED, FAILED)
- **UNKNOWN**: Specified unit not found in `tw_cli show` output

#### Metrics
None.

### acme_fan

<a id="check-acme-fan"></a>

*Fan %s*

#### Overview
Monitors the operational status and speed of cooling fans on devices supporting the ADCX SNMP MIB (e.g., APC UPS units), ensuring adequate thermal management.

#### What it monitors
- Fan speed as a percentage
- Fan state/status (e.g., normal, warning, critical, not present)

#### How it works
In discovery mode (`_discover=true`), it runs `snmpwalk` on `.1.3.6.1.4.1.9148.3.3.1.4.1.1` to enumerate fans; it parses description (`.3.<n>`), value (`.4.<n>`), and state (`.5.<n>`) OIDs per index, skipping fans with state "7" (not present). In check mode, it uses `snmpget` for the first four fans’ OIDs, maps item (fan description) to its value/state, and converts state codes to yolo-man states (OK/WARN/CRIT/UNKNOWN). Fan state "2" is OK; "3"/"4" → WARN; "5"/"6"/"7"/"8"/"9" → CRIT.

#### Parameters
None.

#### States
- OK: Fan state is "1" (initial) or "2" (normal).
- WARN: Fan state is "3" (minor) or "4" (major).
- CRIT: Fan state is "5" (critical), "6" (shutdown), "7" (not present), "8" (not functioning), or "9" (unknown).
- UNKNOWN: Item not found in SNMP data.

#### Metrics
None.

### acme_powersupply

<a id="check-acme-powersupply"></a>

*Power supply %s*

#### Overview
Monitors the operational status of ACME power supplies via SNMP, detecting failures or degradation that could compromise system reliability and uptime.

#### What it monitors
- Power supply unit descriptions (item names)
- Power supply state (e.g., normal, minor fault, critical, not present)

#### How it works
In discovery mode, it performs two `snmpwalk` commands against the ACME environment MIB (OIDs `.1.3.6.1.4.1.9148.3.3.1.5.1.1.3` for descriptions and `.1.3.6.1.4.1.9148.3.3.1.5.1.1.4` for states), parses indices, and builds a mapping. It excludes items in state "7" (not present). In check mode, for a discovered item, it repeats the walk to locate the specific power supply by description, retrieves its state, and maps the numeric state to yolo-man states (OK, WARN, CRIT) using a predefined table.

#### Parameters
None.

#### States
- **OK**: States "1" (initial) or "2" (normal).
- **WARN**: States "3" (minor) or "4" (major).
- **CRIT**: States "5" (critical), "6" (shutdown), "7" (not present), "8" (not functioning), or "9" (unknown).
- **UNKNOWN**: Power supply description not found or state value missing/unreadable.

#### Metrics
None.

### acme_temp

<a id="check-acme-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on ACME devices via SNMP, providing per-sensor status and threshold-based alerts for critical thermal events.

#### What it monitors
- Temperature sensor descriptions (e.g., "CPU TEMP0")
- Raw temperature values in degrees Celsius
- Sensor state (e.g., normal, minor, major, critical, not present)

#### How it works
Discovers sensors by querying four SNMP MIB OIDs (`.1.3.6.1.4.1.9148.3.3.1.3.1.1.{3,4,5,6}.*`). During check mode, it fetches all entries, locates the specified item, and evaluates temperature against user-defined upper/lowerWARN/CRIT thresholds. Sensor state overrides apply: device states ≥2 (minor) downgrade status to WARN/CRIT; state 7 ("not present") is excluded during discovery.

#### Parameters
None.

#### States
- **OK**: Temperature within bounds and device state is normal ("2").
- **WARN**: Temperature exceeds WARN thresholds OR device state is minor ("3").
- **CRIT**: Temperature exceeds CRIT thresholds OR device state is ≥major ("4"–"9").
- **UNKNOWN**: SNMP query failure or item not found.

#### Metrics
- `acme_temp.<item>` — current temperature value in °C.

### acme_voltage

<a id="check-acme-voltage"></a>

*Voltage %s*

#### Overview
Monitors ACME network device voltage sensors via SNMP, reporting voltage levels (in volts) and health states. Critical for detecting power supply or motherboard issues that could lead to hardware failure.

#### What it monitors
- Voltage sensor descriptions (e.g., "MAIN 1.20V")
- Measured voltage values (as millivolts, converted to volts)
- Sensor state (e.g., normal, minor alarm, critical)

#### How it works
Uses `snmpwalk` against OID `.1.3.6.1.4.1.9148.3.3.1.2.1.1.{3,4,5}` to fetch descriptions, values, and states. In discovery mode, groups and parses output into per-sensor items. In check mode, locates the requested item, converts millivolt values to volts, maps numeric state codes to yolo-man states (OK/WARN/CRIT/UNKNOWN), and returns voltage and state.

#### Parameters
None.

#### States
- **OK**: State codes 1 or 2 (initial/normal)
- **WARN**: State codes 3 or 4 (minor/major)
- **CRIT**: State codes 5 or 6 (critical/shutdown)
- **UNKNOWN**: Missing data, sensor not found, or unrecognized state

#### Metrics
- `voltage` — Measured voltage in volts (V)

### adva_fsp_current

<a id="check-adva-fsp-current"></a>

*Power Supply %s*

#### Overview
Monitors the DC current (in amperes) of power supply units on an Adva Fiber Service Platform F7 device via SNMP, alerting when current exceeds a fixed critical threshold.

#### What it monitors
- DC current draw (in A) per power supply unit
- Unit identification (via `unitName` SNMP OID)

#### How it works
First discovers items by verifying the device SNMP sysDescr contains “Fiber Service Platform F7”, then walking five parallel OIDs to build a table of power supplies. Only sensors with non-zero power are included. During check mode, it fetches live SNMP data, maps the requested item to its OID index, extracts current and threshold values, and compares current against a fixed critical threshold (WARN = CRIT level).

#### Parameters
None.

#### States
- **OK**: current < threshold
- **CRIT**: current ≥ threshold
- **UNKNOWN**: device not F7, sensor not found, or missing SNMP data

#### Metrics
- `current` — measured current in amperes (A)

### adva_fsp_temp

<a id="check-adva-fsp-temp"></a>

*Temperature %s*

#### Overview
Monitors the temperature of sensors on Adva optical networking equipment, providing alerts when temperatures exceed safe operational thresholds.

#### What it monitors
- Ambient or component temperature from Adva FSP (Fiber Service Platform) devices, reported as a decimal value in degrees Celsius.

#### How it works
The check queries the `adva_fsp_temp` agent section via `check_mk_agent`. In discovery mode, it parses the section’s output to enumerate individual temperature sensors, validating numeric fields and excluding invalid entries (e.g., sensor values ≤ -273.0°C). During normal operation, it matches the requested `item` (sensor name), applies user-defined thresholds (`warn`, `crit`, `warn_lower`, `crit_lower`) and device-provided thresholds, and determines OK/WARN/CRIT/UNKNOWN states accordingly.

#### Parameters
None.

#### States
- **OK**: Temperature is within all defined (user or device) limits.
- **WARN**: Temperature exceeds user-defined warning thresholds or device warning limits.
- **CRIT**: Temperature exceeds user-defined critical thresholds or device critical limits, or temperature is ≤ -273.0°C (invalid sensor data).
- **UNKNOWN**: Sensor `item` not found or no valid sensor data returned.

#### Metrics
- `temperature` — current sensor reading, in °C.

### akcp_daisy_temp

<a id="check-akcp-daisy-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature readings from daisy-chain sensors on AKCP environmental monitoring devices via SNMP. Critical for preventing overheating in server rooms or data centers where these sensors are deployed.

#### What it monitors
- Ambient or probe temperature values from up to 8 daisy-chained temperature sensors per device
- Each sensor identified by name (e.g., sensor label from SNMP)

#### How it works
Discovers sensors via SNMP `snmpwalk` on OID `.1.3.6.1.4.1.3854.1.2.2.1.19.33.{chain}.2.1`, extracts sensor names, then retrieves corresponding temperature values via `snmpget` on OID suffix `.14`. Temperature is returned as float (`raw integer / 10.0`). For monitoring, it compares against user-configurable thresholds (default: WARN ≥28.0 °C, CRIT ≥32.0 °C).

#### Parameters
None.

#### States
- **OK**: temperature < warning threshold
- **WARN**: temperature ≥ warning threshold and < critical threshold
- **CRIT**: temperature ≥ critical threshold
- **UNKNOWN**: sensor name not found or SNMP query fails

#### Metrics
- `temperature` — temperature in degrees Celsius

### akcp_exp_drycontact

<a id="check-akcp-exp-drycontact"></a>

*Dry Contact %s*

#### Overview
Monitors the state of dry contact sensors on AKCP Environmental Monitoring units via SNMP. Ensures physical sensor connectivity and detects open/closed contact states critical for environmental safety.

#### What it monitors
- Dry contact sensor descriptions (names)
- Sensor status (e.g., OK, alarm, offline)
- Online status (whether sensor is responding)
- Critical and normal descriptive messages associated with sensor states

#### How it works
Uses `snmpwalk` to query AKCP MIB `.1.3.6.1.4.1.3854.2.3.4.1`. During discovery, it collects all dry contact descriptions. In check mode, it parses a table of sensor records (description, status, online, critical_desc, normal_desc) and matches the requested item. State logic: `online=1` and `status=2` → OK; `status` in [4,6] → CRIT; `online≠1` → UNKNOWN (offline); other values → UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Sensor online and status is "2" (normal closed contact).
- **CRIT**: Sensor online but status is "4" or "6" (alarm condition).
- **UNKNOWN**: Sensor offline (`online≠1`), status unknown/invalid (e.g., "1", "7", "8", "9", or other), or item not found.
- **WARN**: Not used (no WARN level in state logic).

#### Metrics
None.

### akcp_exp_temp

<a id="check-akcp-exp-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on AKCP environmental monitoring devices via SNMP, checking sensor status and temperature values against configurable thresholds.

#### What it monitors
- Sensor description/name
- Current temperature value (in Celsius or Fahrenheit)
- Sensor status (normal, high/low warning, high/low critical, error, offline)
- Online status of the sensor
- Configurable warning and critical thresholds for temperature

#### How it works
Performs SNMP walk on AKCP MIB `.1.3.6.1.4.1.3854.2.3.2.1` to gather sensor data. In discovery mode, it identifies online sensors and returns them for service discovery. In check mode, it locates the specific sensor by description, validates online status, maps SNMP status codes to states, normalizes units (handling raw sensor values), and compares temperature against thresholds (default 32/35°C) to determine OK/WARN/CRIT/UNKNOWN states.

#### Parameters
None.

#### States
- **OK**: Sensor online, status is normal, and temperature below warning threshold.
- **WARN**: Sensor online, status is high/low warning, or temperature at/above warning but below critical threshold.
- **CRIT**: Sensor offline, status is high/low critical or error, or temperature at/above critical threshold.
- **UNKNOWN**: Temperature information missing, item not found, or sensor status code unhandled.

#### Metrics
- `temperature` — current temperature value, unit: degrees Celsius (normalized).

### akcp_sensor_drycontact

<a id="check-akcp-sensor-drycontact"></a>

*Dry Contact %s*

#### Overview
Monitors the status of dry contact sensors on an AKCP SNMP-managed device (e.g., environmental probes), detecting offline sensors or abnormal contact states (e.g., open/closed circuits indicating alarms).

#### What it monitors
- Dry contact sensor presence and name (description)
- Sensor online status (SNMP `.1.3.6.1.4.1.3854.1.2.2.1.18.1.5`)
- Dry contact state: normal, critical (high/low), or error conditions (e.g., sensor error, output limits)

#### How it works
Uses `snmpwalk` to query AKCP-specific OIDs for dry contact descriptions (`.1.3.6.1.4.1.3854.1.2.2.1.18.1.1`), status (`.1.3.6.1.4.1.3854.1.2.2.1.18.1.3`), and online state (`.1.3.6.1.4.1.3854.1.2.2.1.18.1.5`). When `"_discover": true`, it enumerates online dry contacts as services; otherwise, it checks the specified `item`. Status codes map to OK (`2`=normal), CRIT (`4`, `6`, or error codes), and UNKNOWN if sensor is missing or offline.

#### Parameters
None.

#### States
- OK: Sensor online and status `"2"` (normal).
- CRIT: Sensor online but status `"4"`, `"6"`, `"1"`, `"7"`, `"8"`, or `"9"` (error/critical states); or sensor offline (`online != "1"`).
- UNKNOWN: Sensor not found by name or SNMP query fails.

#### Metrics
None.

### akcp_sensor_humidity

<a id="check-akcp-sensor-humidity"></a>

*Humidity %s*

#### Overview
Monitors humidity levels from AC-PK SNMP-enabled environmental sensors, ensuring critical infrastructure environments (e.g., data centers) remain within safe humidity ranges to prevent equipment damage or operational issues.

#### What it monitors
- Relative humidity percentage (%) for each individual sensor
- Sensor online status (online/offline)
- Sensor operational status (e.g., normal, error, no status)

#### How it works
Uses `snmpwalk` to query AKCP sensor humidity MIB tables (two fallback OIDs). In discovery mode, it enumerates all online humidity sensors, emitting services with default warning/critical thresholds. In check mode, it retrieves the value for a specific sensor and compares against user-configurable or default thresholds (warn: 60%/65% high, 30%/35% low) to determine OK/WARN/CRIT states.

#### Parameters
None.

#### States
- **OK**: Sensor online, status normal, and humidity within acceptable bounds.
- **WARN**: Humidity exceeds warning thresholds (high or low).
- **CRIT**: Sensor offline, sensor error/no status, or humidity exceeds critical thresholds.
- **UNKNOWN**: Sensor not found, humidity value missing, or SNMP query fails.

#### Metrics
- `humidity` — humidity percentage (%) measured by the sensor.

### alcatel_cpu

<a id="check-alcatel-cpu"></a>

*CPU utilization*

#### Overview
Monitors CPU utilization on Alcatel-Lucent Enterprise (ALE) devices, distinguishing between AOS7 and classic OS versions via SNMP. Critical for ensuring device stability and performance.

#### What it monitors
- CPU utilization percentage on Alcatel-Lucent enterprise switches/routers.

#### How it works
Discovers one service (no items). In check mode, it first retrieves the system OID to detect the OS version, then queries the appropriate CPU OID (.1.3.6.1.4.1.6486.800.1.2.1.16.1.1.1.13 for classic, .1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1.15 for AOS7). Parses the integer value from the SNMP response and compares against fixed default thresholds (WARN=90%, CRIT=95%) to determine state.

#### Parameters
None.

#### States
- **OK**: CPU utilization < 90%
- **WARN**: 90% ≤ CPU < 95%
- **CRIT**: CPU ≥ 95%
- **UNKNOWN**: SNMP failure, non-Alcatel device, or unparseable response.

#### Metrics
- `util` — CPU utilization in percent (%).

### alcatel_cpu_aos7

<a id="check-alcatel-cpu-aos7"></a>

*CPU utilization*

#### Overview
Monitors CPU utilization on Alcatel-Lucent Enterprise (ALE) OS7 devices via SNMP to detect performance degradation or overload risks.

#### What it monitors
- Total CPU utilization (percentage) on the target device.

#### How it works
Uses SNMP `snmpget` to query OID `.1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1.15`. In discovery mode, it yields one item with `item=""`. In check mode, it parses the retrieved integer value, compares against upper thresholds (default: WARN at ≥90%, CRIT at ≥95%), and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
None.

#### States
- **OK**: CPU utilization < 90% (default threshold)
- **WARN**: ≥90% but <95%
- **CRIT**: ≥95%
- **UNKNOWN**: SNMP query fails (timeout, error, or empty response)

#### Metrics
- `util` — CPU utilization in percent (%).

### alcatel_fans

<a id="check-alcatel-fans"></a>

*Fan %s*

#### Overview
Monitors the operational status of fans on Alcatel-Lucent enterprise switches (AOS-6 and AOS-7) via SNMP to detect hardware failures that could lead to overheating.

#### What it monitors
- Per-fan operational status: whether each fan is running, not running, or has no status.

#### How it works
During discovery, it runs `snmpwalk` on the AOS-6 fan OID (`1.3.6.1.4.1.6486.801.1.1.1.3.1.1.11.1.2`) to enumerate fans; if none found, retries with the same OID (note: source code has a bug—reuses same OID instead of AOS-7 OID). In check mode, it issues `snmpget` on the fan-specific OID, falls back to an AOS-6 OID if the first fails, interprets the integer status (0=none, 1=not running, 2=running), and reports OK only if the fan is running.

#### Parameters
None.

#### States
- OK: fan status is `2` (running).
- CRIT: fan status is `0` or `1` (no status or not running).
- UNKNOWN: fan item invalid, fan not found, or SNMP returns no parsable value.

#### Metrics
None.

### alcatel_fans_aos7

<a id="check-alcatel-fans-aos7"></a>

*Fan %s*

#### Overview
Monitors the operational status of fans on Alcatel-Lucent Enterprise OS7 devices via SNMP, ensuring cooling systems are functioning to prevent hardware overheating.

#### What it monitors
- Fan operational state (not running, running, or no status) on a per-fan basis, identified by SNMP index.

#### How it works
- In discovery mode (`_discover=true`), it runs `snmpwalk` on the fan status OID (`.1.3.6.1.4.1.6486.801.1.1.1.3.1.1.11.1.2`) to enumerate fans and creates one service per fan (items numbered 1, 2, …).
- For a specific fan (`item` required), it runs `snmpget` for that fan’s OID. The returned INTEGER is interpreted: 2 → OK (running), any other value (0 or 1) → CRIT.

#### Parameters
None.

#### States
- **OK**: Fan state = 2 (running).
- **CRIT**: Fan state = 0 (no status) or 1 (not running).
- **UNKNOWN**: Discovery fails, `item` missing, SNMP query fails, or unexpected output format.

#### Metrics
None.

### alcatel_power

<a id="check-alcatel-power"></a>

*Power Supply %s*

#### Overview
This check monitors the operational status and type of power supplies on Alcatel-Lucent enterprise equipment via SNMP, ensuring冗余 power systems are functioning correctly.

#### What it monitors
- Operational status (up/down/testing/etc.) of each power supply unit
- Power supply type (AC, DC, or none)
- Discovery-based per-unit monitoring (items are numeric power supply identifiers)

#### How it works
Uses two separate `snmpwalk` calls (to OIDs `.1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1.2` for status and `.1.3.6.1.4.1.6486.800.1.1.1.1.1.1.1.36` for type) to fetch power supply data. During discovery, it lists all power supplies with both type and status (excluding “no power supply” or “not present”). In check mode, it verifies the status of the specified item: `up` → OK, any other status → CRIT.

#### Parameters
None.

#### States
- **OK**: Power supply is operational (`operational status = up`).
- **CRIT**: Power supply is non-operational (e.g., `down`, `unpowered`, `testing`, etc.).
- **UNKNOWN**: SNMP query fails, or the specified item is not found.

#### Metrics
None.

### alcatel_power_aos7

<a id="check-alcatel-power-aos7"></a>

*Power Supply %s*

#### Overview
Monitors the operational status and type of power supplies on Alcatel-Lucent Enterprise OS7 devices via SNMP. Ensures critical power components are functioning correctly to maintain device uptime and availability.

#### What it monitors
- Operability status of each power supply (e.g., up, down, not present, unpowered)
- Power supply type (AC, DC, or none)

#### How it works
Discovery: Uses `snmpwalk` to fetch OID `.1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.2` (operability) and `.1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.35` (type), correlates by index, and filters out non-existent or irrelevant supplies.
Check mode: Uses `snmpget` for the specific item index to retrieve status/type, maps values via hardcoded tables, and sets state to `CRIT` if not "up", otherwise `OK`.

#### Parameters
None.

#### States
- **OK**: Power supply status is "up".
- **CRIT**: Status is any value other than "up" (e.g., down, not present, unpowered).
- **UNKNOWN**: SNMP query fails (non-zero exit), response parsing fails, or item not found.

#### Metrics
None.

### alcatel_temp

<a id="check-alcatel-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Alcatel-Lucent enterprise devices via SNMP, providing status alerts for board and CPU temperatures to prevent overheating-related failures.

#### What it monitors
- Board temperature per slot (e.g., Slot 1 Board)
- CPU temperature per slot (e.g., Slot 1 CPU)
- Temperature values in degrees Celsius

#### How it works
During discovery, it runs `snmpwalk` on two OIDs (`.1.3.6.1.4.1.6486.800.1.1.1.3.1.1.3.1.4` for boards, `.1.3.6.1.4.1.6486.800.1.1.1.3.1.1.3.1.5` for CPUs) to enumerate sensors. For each detected sensor, it creates a service with default temperature thresholds (45 °C warning, 50 °C critical). In check mode, it runs `snmpget` for the specific sensor OID and parses the INTEGER value to compute state.

#### Parameters
None.

#### States
- **OK**: Temperature < 45 °C
- **WARN**: Temperature ≥ 45 °C and < 50 °C
- **CRIT**: Temperature ≥ 50 °C
- **UNKNOWN**: No SNMP data or unparseable response

#### Metrics
- `temperature` — measured temperature in °C

### alcatel_temp_aos7

<a id="check-alcatel-temp-aos7"></a>

*Temperature Board %s*

#### Overview
Monitors temperature sensors on Alcatel-Lucent Enterprise (ALE) OS7 network devices via SNMP, detecting disconnected boards and reporting real-time board temperatures.

#### What it monitors
- Temperature readings (in °C) for 16 specific hardware boards: CPMA, CFMA, CPMB, CFMB, CFMC, CFMD, FTA, FTB, and NI1–NI8.
- Board presence/disconnection status (a value of `0` indicates a disconnected or absent board).

#### How it works
In discovery mode (`_discover=true`), it runs `snmpwalk` on specific OIDs to enumerate active boards and their temperatures, emitting per-board services only for boards with non-zero temperatures. In check mode, it retrieves the same SNMP data, maps board names to temperatures, validates the requested board exists, applies default or user-specified thresholds (`(45.0, 50.0)` °C warn/crit), and sets state based on upper-level comparisons.

#### Parameters
None.

#### States
- **OK**: Temperature < warning threshold and board is connected (non-zero).
- **WARN**: Temperature ≥ warning threshold but < critical threshold.
- **CRIT**: Temperature ≥ critical threshold.
- **UNKNOWN**: Board not found or disconnected (temperature = 0).

#### Metrics
- `temp` — current temperature reading for the board, in °C.

### alcatel_timetra_cpu

<a id="check-alcatel-timetra-cpu"></a>

*CPU utilization*

#### Overview
Monitors CPU utilization on Alcatel-Lucent (Nokia) TiMERA devices via SNMP, providing early warning of performance degradation or overload.

#### What it monitors
- Single CPU utilization percentage on the target device.

#### How it works
- In discovery mode: uses `snmpget` with OID `.1.3.6.1.4.1.6527.3.1.2.1.1.1` to fetch CPU usage, parses the integer value, and discovers one service with empty item and default thresholds `(90.0, 95.0)`.
- In check mode: re-reads the same OID, parses the value, and compares against thresholds from `params["util"]` to determine state. Returns UNKNOWN on SNMP or parse errors.

#### Parameters
`util` (tuple of two floats, `(90.0, 95.0)`) — warning and critical thresholds for CPU utilization in percent.

#### States
- **OK**: CPU utilization < warning threshold.
- **WARN**: CPU utilization ≥ warning and < critical threshold.
- **CRIT**: CPU utilization ≥ critical threshold.
- **UNKNOWN**: SNMP command fails or output cannot be parsed.

#### Metrics
`util` — CPU utilization as a percentage (`float`).

### allnet_ip_sensoric_humidity

<a id="check-allnet-ip-sensoric-humidity"></a>

*Humidity %s*

#### Overview
Monitors humidity levels from allnet IP sensoric devices, supporting discovery of humidity sensors and evaluating them against configurable threshold levels to detect abnormal environmental conditions.

#### What it monitors
- Humidity percentage (%RH) from individual sensors on allnet IP sensoric hardware.
- Sensor metadata: name, ID, and function code (used to identify humidity sensors).

#### How it works
In discovery mode, it runs `cmk inventory` and `cmk agent` to extract the `allnet_ip_sensoric` section, parses sensor lines (e.g., `sensor1 name=HumiditySensor unit=% function=2 value_float=55.2`), and discovers sensors where `function=2` or `unit=%`. In check mode, it runs `cmk agent`, parses the section again, locates the specific sensor by item (e.g., `"HumiditySensor 1"` → `"sensor1"`), reads `value_float`, and compares against thresholds (`levels` high, `levels_lower` low). Verdicts are determined by high/low critical/warning bounds.

#### Parameters
None.

#### States
- **OK**: Humidity within both high and low normal ranges.
- **WARN**: Humidity ≥ upper warning threshold or ≤ lower warning threshold, but not yet critical.
- **CRIT**: Humidity ≥ upper critical threshold or ≤ lower critical threshold.
- **UNKNOWN**: Agent fails, sensor not found, or `value_float` missing/invalid.

#### Metrics
- `humidity` — Current relative humidity percentage (%RH).

### allnet_ip_sensoric_pressure

<a id="check-allnet-ip-sensoric-pressure"></a>

*Pressure %s*

#### Overview
Monitors atmospheric pressure readings from allnet IP sensoric devices via the yolo-man agent, converting hPa values to bar for standardized reporting.

#### What it monitors
- Atmospheric pressure values from individual sensors, specifically those configured with function ID "16" and unit "hPa"

#### How it works
Reads cached or raw agent data from `/var/lib/yolo-man-agent/{cache,raw}/allnet_ip_sensoric`. In discovery mode, it enumerates sensors matching the pressure criteria and creates items like "{name} Sensor {num}". In check mode, it extracts the sensor number from the item name, retrieves the corresponding `value_float` (in hPa), converts it to bar (÷1000), and reports OK with the value in the message and metric.

#### Parameters
None.

#### States
- OK: Pressure value found and successfully converted.
- UNKNOWN: Agent section missing, item not provided, sensor number extraction failed, sensor ID not found, or sensor data malformed.

#### Metrics
- `pressure` — atmospheric pressure in bar (float).

### allnet_ip_sensoric_temp

<a id="check-allnet-ip-sensoric-temp"></a>

*Temperature %s*

#### Overview
Monitors the temperature of sensors from an allnet IP sensoric device, providing alerts when readings exceed user-defined thresholds.

#### What it monitors
- Temperature values (in °C) from individual sensors identified via `sensorN` IDs.
- Sensor names and numeric IDs are used to build descriptive items (e.g., “Temperature Sensor 1”).

#### How it works
Reads JSON data from `/tmp/agent_output/allnet_ip_sensoric`. In discovery mode (`_discover` = true), it lists all sensors with `function="1"` or `unit="°C"`, assigning default thresholds `[35.0, 40.0]`. In check mode, it parses the sensor ID from the item string (e.g., from “Temperature Sensor 1” → `sensor1`), retrieves the temperature value, compares it against configurable thresholds, and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
None.

#### States
- **OK**: Temperature < warning threshold.
- **WARN**: Temperature ≥ warning and < critical threshold.
- **CRIT**: Temperature ≥ critical threshold.
- **UNKNOWN**: Agent data missing, sensor not found, or temperature value absent.

#### Metrics
- `temp` — current temperature reading, in °C.

### apc_ats_output

<a id="check-apc-ats-output"></a>

*Phase %s output*

#### Overview
Monitors output parameters (voltage, current, power, load percentage) of APC Automatic Transfer Switch (ATS) phases via SNMP.

#### What it monitors
- Output voltage (V)
- Output current (A)
- Output power (W)
- Load percentage (%)

#### How it works
In discovery mode, it runs `snmpwalk` on the OID `.1.3.6.1.4.1.318.1.1.8.5.4.3.1` to enumerate ATS output items, parsing results into per-phase metrics. In check mode, it runs the same SNMP command for a specific item, extracts its values, and compares against configurable thresholds. States are determined by level checks (WARN/CRIT if values exceed min/max bounds).

#### Parameters
None.

#### States
- OK: All measured values within configured thresholds (or thresholds not set).
- WARN: One or more values exceed upper or lower warning bounds.
- CRIT: One or more values exceed upper or lower critical bounds.
- UNKNOWN: SNMP query fails or item not found.

#### Metrics
- `volt` — output voltage, V
- `watt` — output power, W
- `current` — output current, A
- `load_perc` — load percentage, %

### apc_inputs

<a id="check-apc-inputs"></a>

*Input %s*

#### Overview
Monitors the status and alarm conditions of APC power input circuits via the yolo-man agent, ensuring critical power infrastructure is functioning correctly.

#### What it monitors
- Input name, location, and operational state (closed/open/disabled/not applicable)
- Alarm status (normal/warning/critical/not applicable)
- Per-item state changes detected since discovery

#### How it works
Uses the `yolo-man-agent apc_inputs` command to fetch tab-separated agent data. In discovery mode, it omits disabled/not applicable inputs and records item metadata. In check mode, it validates a specific input against its current status and compares against the discovered state. State is determined by `alarm_status`: 1→OK, 2 or 4→WARN, 3→CRIT, else UNKNOWN.

#### Parameters
None.

#### States
- **OK**: `alarm_status` is 1 (normal)
- **WARN**: `alarm_status` is 2 (warning) or 4 (not applicable), or port state changed since discovery
- **CRIT**: `alarm_status` is 3 (critical)
- **UNKNOWN**: `alarm_status` is invalid, or input not found

#### Metrics
None.

### apc_inrow_airflow

<a id="check-apc-inrow-airflow"></a>

*Airflow*

#### Overview
Monitors airflow in APC IN-Row cooling units to ensure proper thermal management in data centers, preventing equipment overheating.

#### What it monitors
- Airflow rate (in liters per second) from APC IN-Row air handling units.

#### How it works
Discovers one service with default thresholds. In check mode, executes `snmpget` against OID `.1.3.6.1.4.1.318.1.1.13.3.2.2.2.5` via SNMP v2c (community: `public`). Parses the integer response, validates format, and compares the value against low/high warning/critical thresholds. State is OK, WARN, CRIT, or UNKNOWN based on threshold breaches or failures.

#### Parameters
None.

#### States
- **OK**: Airflow within acceptable range (between `warn_low`/`crit_low` and `warn_high`/`crit_high` thresholds).
- **WARN**: Airflow below `warn_low` or at/above `warn_high`.
- **CRIT**: Airflow below `crit_low` or at/above `crit_high`.
- **UNKNOWN**: SNMP query fails, empty response, unparseable value, or invalid format.

#### Metrics
- `airflow` — measured airflow rate in liters per second.

### apc_inrow_fanspeed

<a id="check-apc-inrow-fanspeed"></a>

*Fanspeed*

#### Overview
Monitors the fan speed of APC InRow cooling units via SNMP, ensuring thermal management systems are operating within expected ranges.

#### What it monitors
- Fan speed as a percentage of maximum capacity (`fan_perc`)

#### How it works
In discovery mode, it checks if the host is an APC ATS device (by querying `sysObjectID` `.1.3.6.1.2.1.1.2.0`) and validates access to the fan speed OID `.1.3.6.1.4.1.318.1.1.13.3.2.2.2.16.0`. In check mode, it queries the same fan OID via `snmpget`, parses the integer value, and converts it to a percentage (raw value / 10.0). The state is always OK unless SNMP fails or parsing fails (UNKNOWN), as no thresholds are defined.

#### Parameters
None.

#### States
- **OK**: Fan speed successfully read and converted to percentage.
- **UNKNOWN**: SNMP query failed or parsed value is invalid; fan speed cannot be determined.
- **WARN/CRIT**: Not used — no thresholds are configured.

#### Metrics
- `fan_perc` — fan speed as a percentage (float, unit: %).

### apc_netbotz_other_sensors

<a id="check-apc-netbotz-other-sensors"></a>

*Numeric sensors summary*

#### Overview
This check monitors numeric sensors on APC NetBotz devices (v2 and v50 series), providing a summary of sensor states via SNMP. It matters because these sensors detect environmental issues like leaks, temperature extremes, or humidity problems critical for data center reliability.

#### What it monitors
- Numeric sensor states (e.g., water leak, temperature, humidity)
- Sensor labels (descriptive names)
- Error state codes and human-readable status strings

#### How it works
In discovery mode, it runs `snmpwalk` against both v2 (`.1.3.6.1.4.1.5528.100.4.2.10.1`) and v50 (`.1.3.6.1.4.1.52674.500.4.2.10.1`) OIDs for sensor label (`.4`), error state (`.3`), and readable state (`.7`). In check mode, it repeats the SNMP query and evaluates each sensor: non-OK `state_readable` values (unless error state is `0`) trigger CRIT. Discovery yields one service if any sensor has a non-empty `state_readable`.

#### Parameters
None.

#### States
- **OK**: At least one sensor is present and all sensors are either `state_readable == "OK"` or have `error_state == "0"`.
- **CRIT**: One or more sensors have non-OK `state_readable` *and* non-zero `error_state`.
- **UNKNOWN**: No sensors are found (no `state_readable` values returned).

#### Metrics
None.

### apc_netbotz_smoke

<a id="check-apc-netbotz-smoke"></a>

*Smoke Detector %s*

#### Overview
Monitors the operational status of smoke detectors connected to APC NetBotz appliances via SNMP, ensuring fire safety systems are functioning correctly and alerting on smoke detection events.

#### What it monitors
- Individual smoke sensor states (e.g., smoke detected, no smoke, unknown)
- Discovery of all available smoke sensors by module and sensor index

#### How it works
In discovery mode (`_discover=true`), it runs `snmpwalk` on four OIDs to enumerate sensors and their states. It parses the output, validates entries, and creates one service per valid sensor (states 1–3). In check mode, it runs `snmpget` on the specific sensor’s OID (derived from the item string like `"sensor_name 1/2"`) to retrieve and evaluate the current state: state `1` → CRIT, `2` → OK, others → UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Sensor reports state `2` (“No smoke detected”).
- **CRIT**: Sensor reports state `1` (“Smoke detected”).
- **UNKNOWN**: Sensor reports an invalid state (e.g., not 1 or 2), sensor not found, SNMP failure, or malformed data.
- **UNKNOWN** (service): Returned if item is missing, malformed, or discovery fails.

#### Metrics
None.

### apc_netshelterpdu_power

<a id="check-apc-netshelterpdu-power"></a>

*PDU %s*

#### Overview
Monitors power distribution unit (PDU) metrics—specifically output load, current, and power—for APC NetShelter PDUs via the yolo-man agent. Ensures PDUs operate within safe electrical thresholds to prevent overloads or failures.

#### What it monitors
- Output load (% of rated capacity)
- Current draw (amperes)
- Power consumption (watts)
for Device, Phase, and Bank entries discovered on the PDU.

#### How it works
Reads parsed agent data from `/var/lib/yolo-man/agent/output.json`. In discovery mode, enumerates items starting with `"Device "`, `"Phase "`, or `"Bank "` and assigns appropriate metrics per type. In check mode, evaluates thresholds: default `warn_output_load=80%`, `crit_output_load=90%`; user-defined `warn_current` and `crit_current`. State escalates to WARN or CRIT if thresholds are exceeded.

#### Parameters
`warn_current` (float, None) — warning threshold for current (A).
`crit_current` (float, None) — critical threshold for current (A).
`warn_output_load` (float, 80.0) — warning threshold for output load (%).
`crit_output_load` (float, 90.0) — critical threshold for output load (%).

#### States
- **OK**: All metrics within thresholds.
- **WARN**: Output load ≥ warning threshold or current ≥ warning threshold (but below critical).
- **CRIT**: Output load ≥ critical threshold or current ≥ critical threshold.
- **UNKNOWN**: Missing agent data, section, or item; no valid metric values found.

#### Metrics
`output_load` — Output load as percentage (%).
`current` — Current draw in amperes (A).
`power` — Power consumption in watts (W).

### apc_powerswitch

<a id="check-apc-powerswitch"></a>

*Power Outlet Port %s*

#### Overview
Monitors the status of individual power outlets on an APC power switch (PDU) via agent-provided SNMP data. Critical for detecting unexpected power loss to connected equipment.

#### What it monitors
- Power outlet index, name, and status (on/off/unknown) for each outlet.
- Discovery targets only outlets with status `"1"` (on).

#### How it works
- **Discovery**: Reads `/var/lib/yolo-man-agent/sections/apc_powerswitch` if present; parses lines (index name status), yields items for outlets with `status == "1"`.
- **Check mode**: Reads same file, locates the specified outlet by index, determines state: `"1"` → OK, `"2"` → WARN, anything else → UNKNOWN.
- Relies on pre-parsed agent data (no SNMP execution in Starlark).

#### Parameters
None.

#### States
- **OK**: Outlet status is `"1"` (on).
- **WARN**: Outlet status is `"2"` (off).
- **UNKNOWN**: Agent section missing, outlet index not found, or status is neither `"1"` nor `"2"`.

#### Metrics
None.

### apc_rackpdu_power

<a id="check-apc-rackpdu-power"></a>

*PDU %s*

#### Overview
Monitors APC Rack PDU power consumption and per-phase/bank current using SNMP. Ensures power usage stays within safe limits and detects overloads that could trip breakers or damage equipment.

#### What it monitors
- Total PDU power draw (watts)
- Per-phase or per-bank current draw (amperes)
- Load state (normal, low, near overload, over load)

#### How it works
Discovers PDUs and their phases/banks via SNMP walk on `.1.3.6.1.4.1.318.1.1.12` OIDs. For discovery, it extracts device name, power value, and number of phases. Then iterates through load and state OIDs to enumerate phases/banks. For checks, it fetches current device power or per-item current/state via SNMP, compares against thresholds (if configured), and returns OK/WARN/CRIT.

#### Parameters
None.

#### States
- **OK**: Power/current within normal range; load state normal.
- **WARN**: Power/current exceeds warning threshold or load state is "near overload".
- **CRIT**: Power/current exceeds critical threshold or load state is "over load".
- **UNKNOWN**: PDU not detected, item name invalid, or SNMP query fails.

#### Metrics
- `power` — PDU total power consumption, in watts (W)
- `current` — Phase/bank current draw, in amperes (A)

### apc_sts_inputs

<a id="check-apc-sts-inputs"></a>

*Input %s*

#### Overview
Monitors voltage, current, and power readings from APCSTS input power lines—critical for ensuring stable power delivery and preventing hardware damage or outages.

#### What it monitors
- Input voltage (volts)
- Input current (amperes)
- Input power (watts)

#### How it works
The check uses a discovered section `section_apc_sts_inputs` (dictionary keyed by input name). During discovery (`_discover: true`), it yields per-input items with metrics: `voltage`, `current`, `power`. For a specific input, it retrieves the three metrics and compares them against optional upper/lower warning/critical thresholds (configured via parameters). It aggregates the worst state among the three values (OK → WARN → CRIT). UNKNOWN if the item is missing.

#### Parameters
None.

#### States
- **OK**: All metrics within bounds (no thresholds exceeded).
- **WARN**: At least one metric exceeds a warning bound (upper or lower), but no critical bound exceeded.
- **CRIT**: At least one metric exceeds a critical bound (upper or lower).
- **UNKNOWN**: Item name not found in the section.

#### Metrics
- `voltage` — measured input voltage in volts
- `current` — measured input current in amperes
- `power` — measured input power in watts

### apc_sts_source

<a id="check-apc-sts-source"></a>

*Source*

#### Overview
Monitors the power source status of an APCSTS (PowerNet SNMP MIB) UPS system by checking if the two power sources are in their expected states via SNMP.

#### What it monitors
- Current state (IN USE or NOT USED) of Power Source 1 and Power Source 2 on the APC UPS.

#### How it works
Discovers services by running `snmpwalk` on OIDs `.1.3.6.1.4.1.705.2.3.5.0` and `.1.3.6.1.4.1.705.2.4.5.0` to extract source states and discover a single service. In check mode, it uses `snmpget` (falling back to `snmpwalk`) to retrieve current source states and compares them against the values recorded during discovery. If any source has changed from its discovered state, the state becomes WARN.

#### Parameters
None.

#### States
- OK — both sources match their discovered states (e.g., both “in use” or “not used”).
- WARN — at least one source state has changed since discovery.
- UNKNOWN — SNMP data cannot be retrieved (no response from either `snmpget` or `snmpwalk`).

#### Metrics
None.

### apc_symmetra

<a id="check-apc-symmetra"></a>

*APC Symmetra status*

#### Overview
Monitors the status of APC Symmetra UPS systems via SNMP data, providing operational insight into critical power infrastructure health.

#### What it monitors
- UPS status and cartridge state (via SNMP OIDs under `.1.3.6.1.4.1.318.1.1.10.4.2.3.1` and `.1.3.6.1.4.1.318.1.1.1`)
- Device health indicators derived from Symmetra-specific SNMP MIBs

#### How it works
The check performs discovery to identify one service per device (item is empty). During normal execution, it attempts to fetch SNMP data via the host agent (simulated via JSON), but in the Starlark sandbox no real data source is available—therefore it returns UNKNOWN with a message indicating agent/SNMP misconfiguration. In real environments, the agent would supply the SNMP data.

#### Parameters
None.

#### States
- **UNKNOWN**: Agent data not available (e.g., SNMP not configured or agent not producing expected output)
- **OK/WARN/CRIT**: Not implemented in current Starlark simulation—would depend on parsed SNMP data values in a real environment

#### Metrics
None.

### apc_symmetra_elphase

<a id="check-apc-symmetra-elphase"></a>

*Phase %s*

#### Overview
Monitors the battery current of an APC Symmetra UPS using SNMP, critical for detecting battery degradation or overload conditions that could lead to failure.

#### What it monitors
- Battery current (in amperes) drawn from the UPS battery

#### How it works
- On discovery mode (`_discover=True`), runs `snmpwalk` on OID `.1.3.6.1.4.1.318.1.1.1.2.2.2.0` to confirm the presence of a single battery phase item.
- In check mode, uses `snmpget` on the same OID to fetch the current value.
- Parses the SNMP response, extracts the numeric current value, and compares it against hardcoded thresholds: WARN ≥ 2.0 A, CRIT ≥ 3.0 A.
- Reports OK/WARN/CRIT/UNKNOWN based on the value and SNMP command success.

#### Parameters
None.

#### States
- OK: Battery current < 2.0 A
- WARN: Battery current ≥ 2.0 A and < 3.0 A
- CRIT: Battery current ≥ 3.0 A
- UNKNOWN: SNMP command fails or output is unparseable

#### Metrics
- `current` — Battery current in amperes (A)

### apc_symmetra_ext_temp

<a id="check-apc-symmetra-ext-temp"></a>

*Temperature External %s*

#### Overview
Monitors external temperature sensors on APC Symmetra UPS systems via agent-provided data. Critical for ensuring operating environment safety and preventing overheating-related failures.

#### What it monitors
- External temperature sensor readings (in Celsius or Fahrenheit)
- Sensor status (only active sensors with status “2” are monitored)
- Temperature units reported by each sensor

#### How it works
Discovers active sensors by reading agent cache/rawfile data (path fallback: `/var/lib/yolo-man-agent/cache/apc_symmetra_ext_temp` or `rawfile/...`). Parses lines where status equals “2”, using the first field as the item index. In check mode, retrieves the temperature and unit for the specified item, converts Fahrenheit to Celsius if needed, and compares against configurable warning/critical levels (default: 30.0/35.0°C).

#### Parameters
None.

#### States
- **OK**: Temperature is below warning threshold
- **WARN**: Temperature is at or above warning, below critical threshold
- **CRIT**: Temperature is at or above critical threshold
- **UNKNOWN**: Sensor not found, data unavailable, or item unspecified

#### Metrics
- `temp` — current temperature in °C (float)

### apc_symmetra_output

<a id="check-apc-symmetra-output"></a>

*Phase %s*

#### Overview
Monitors the output phase parameters (voltage, current, and output load) of an APC Symmetra UPS device via SNMP. Ensures power delivery remains within safe operational limits.

#### What it monitors
- Output voltage (V)
- Output current (A)
- Output load (%)

#### How it works
First, discovers APC UPS devices by checking `sysObjectID` (`.1.3.6.1.4.1.318.*`). In discovery mode, it performs `snmpwalk` on output-related OIDs and creates a single item `"Output"`. In check mode, it runs `snmpget` for the scalar OIDs `.1.3.6.1.4.1.318.1.1.1.4.2.1.0` (voltage), `.4.2.4.0` (current), and `.4.2.3.0` (load), converts values to floats, and evaluates against thresholds.

#### Parameters
`voltage` (list of float, `[220.0, 220.0]`) — warning and critical thresholds for voltage (absolute values; deviation triggers CRIT).

#### States
- **OK**: Voltage is exactly 220.0 V and no errors occur.
- **CRIT**: Voltage differs from 220.0 V.
- **UNKNOWN**: SNMP error, no output data, or item mismatch.

#### Metrics
`voltage` — output voltage in V
`current` — output current in A
`output_load` — output load as percentage (%)

### apc_symmetra_temp

<a id="check-apc-symmetra-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature readings from APC Symmetra UPS units, distinguishing between battery and sensor temperatures to ensure safe operating conditions and prevent thermal failure.

#### What it monitors
- Battery temperature
- Ambient or internal temperature sensors

#### How it works
The check expects an `item` parameter specifying either "Battery" or a sensor name. It retrieves the temperature `reading` from parameters (provided by yolo-man runtime). It applies upper-level thresholds: default WARN at 25°C (sensors) or 50°C (battery), CRIT at 30°C or 60°C respectively. If no reading is provided, it returns UNKNOWN. Discovery is handled by yolo-man infrastructure, and the Starlark implementation returns an empty discovery list.

#### Parameters
`item` (string, required) — specifies which temperature item to check ("Battery" or a sensor name).
`levels_battery` (list of 2 floats, default `[50, 60]`) — WARN and CRIT thresholds for battery temperature.
`levels_sensors` (list of 2 floats, default `[25, 30]`) — WARN and CRIT thresholds for non-battery sensors.

#### States
OK — temperature below WARN threshold.
WARN — temperature ≥ WARN and < CRIT threshold.
CRIT — temperature ≥ CRIT threshold.
UNKNOWN — temperature `reading` is missing.

#### Metrics
`temp` — current temperature reading, in °C.

### apc_symmetra_test

<a id="check-apc-symmetra-test"></a>

*Self Test*

#### Overview
Monitors the self-test status and elapsed time since the last self-test of an APC Symmetra UPS device via SNMP to ensure regular health validation and timely maintenance.

#### What it monitors
- Last self-test result (OK, failed, invalid, or in progress)
- Date of the last self-test
- Elapsed days since the last self-test

#### How it works
First, discovers if the host is an APC Symmetra by querying the SNMP OID `.1.3.6.1.2.1.1.2.0`. If discovered, it proceeds to fetch two OIDs via `snmpget`: the last test result (`.1.3.6.1.4.1.318.1.1.1.7.2.3.0`) and test date (`.1.3.6.1.4.1.318.1.1.1.7.2.4.0`). It parses the date, computes days elapsed using manual date arithmetic, and compares against optional elapsed-time thresholds. State is determined by test result severity and elapsed time.

#### Parameters
None.

#### States
- **OK**: Test succeeded and elapsed time within limits (or no levels set).
- **WARN**: Test invalid/in progress, or elapsed time exceeds warning threshold.
- **CRIT**: Test failed, or elapsed time exceeds critical threshold.
- **UNKNOWN**: Data missing, invalid date, or discovery failed.

#### Metrics
None.

### arbor_peakflow_sp_disk_usage

<a id="check-arbor-peakflow-sp-disk-usage"></a>

*Disk Usage %s*

#### Overview
Monitors disk usage percentage on Arbor Peakflow SP devices via SNMP, alerting when thresholds are exceeded to prevent storage exhaustion that could impact device operation.

#### What it monitors
- Disk usage percentage of the root filesystem (`/`) on the Peakflow SP device.

#### How it works
Discovers a single item `/`. In check mode, it runs `snmpwalk` against OID `.1.3.6.1.4.1.9694.1.4.2.1.4.0` to retrieve the disk usage value as an integer. It parses the SNMP output, applies upper-threshold levels (default: warn at 80%, crit at 90%), and returns OK/WARN/CRIT based on comparison.

#### Parameters
None.

#### States
- OK: disk usage is below warn threshold (default <80%).
- WARN: disk usage is at or above warn threshold but below crit (80%–89.99%).
- CRIT: disk usage is at or above crit threshold (≥90%).
- UNKNOWN: SNMP query fails, output is empty/unparseable, or item is not `/`.

#### Metrics
- `disk_utilization` — disk usage as a fractional value (0.0–1.0).

### arbor_pravail_host_fault

<a id="check-arbor-pravail-host-fault"></a>

*Host Fault*

#### Overview
This check monitors hardware fault conditions on an Arbor network appliance host via SNMP, reporting critical if any fault is detected.

#### What it monitors
- Host-level hardware fault status reported by the appliance (e.g., fan failure, power supply issue, temperature fault)

#### How it works
The check performs a single SNMP walk query (SNMP v2c, community `public`, localhost) against OID `.1.3.6.1.4.1.9694.1.6.2.1.0`. The response is parsed as a STRING value; if it equals `"No Fault"`, the state is OK, otherwise CRIT. Discovery always yields one service item `""`.

#### Parameters
None.

#### States
- **OK**: Host fault string is exactly `"No Fault"`.
- **CRIT**: Host fault string is any non-empty string other than `"No Fault"`.
- **UNKNOWN**: SNMP query fails or output format is unexpected.

#### Metrics
None.

### arris_cmts_cpu

<a id="check-arris-cmts-cpu"></a>

*CPU utilization Module %s*

#### Overview
Monitors CPU utilization of individual modules on an Arris Cable Modem Termination System (CMTS) via SNMP, helping detect performance degradation or resource exhaustion.

#### What it monitors
- Per-CPU-module utilization percentage
- Idle time of each CPU module, used to compute active utilization

#### How it works
Uses `snmptable` to query SNMP OID `.1.3.6.1.4.1.4998.1.1.5.3.1.1.1`. In discovery mode, it lists all CPU modules and prepares check items. During normal checks, it finds the specific module by ID, calculates utilization as `100 - idle`, and compares against thresholds (default: 90% WARN / 95% CRIT). Invalid idle values default to 0.0 idle (100% util), but no CRIT/WARN is triggered until valid parsing succeeds.

#### Parameters
None.

#### States
- **OK**: Utilization below warning threshold (< 90%)
- **WARN**: Utilization at or above warning, below critical (90–94.9%)
- **CRIT**: Utilization at or above critical threshold (≥ 95%)
- **UNKNOWN**: SNMP query fails, no data available, or specified module ID not found

#### Metrics
- `util` — CPU utilization percentage (%)

### arris_cmts_temp

<a id="check-arris-cmts-temp"></a>

*Temperature Module %s*

#### Overview
Monitors temperature sensors on Arris CMTS devices via SNMP to ensure operating temperatures stay within safe thresholds, preventing hardware damage or service degradation.

#### What it monitors
- Temperature readings from individual sensor modules on the CMTS device.

#### How it works
In discovery mode, the check runs `snmpwalk` to enumerate temperature sensors by querying OIDs `.1.3.6.1.4.1.4998.1.1.10.1.4.2.1.3` (sensor names) and `.1.3.6.1.4.1.4998.1.1.10.1.4.2.1.29` (temperature values in °C). In check mode, it retrieves the same SNMP data and matches the requested sensor `item` to report its temperature. Thresholds (`levels`) default to (40.0, 46.0) for WARN/CRIT.

#### Parameters
None.

#### States
- **OK**: Temperature is below WARN threshold.
- **WARN**: Temperature is at or above WARN, below CRIT threshold.
- **CRIT**: Temperature is at or above CRIT threshold.
- **UNKNOWN**: Sensor `item` not found in SNMP data.

#### Metrics
- `temp` — current temperature reading in °C.

### artec_temp

<a id="check-artec-temp"></a>

*Temperature %s*

#### Overview
Monitors the internal temperature of an Artec device (typically a network appliance or server) to prevent overheating-related failures.

#### What it monitors
- Internal temperature sensor reading from the Artec hardware.

#### How it works
Discovers a single service item named "Disk" with default temperature thresholds (36.0°C warn, 40.0°C crit). Reads the temperature value from the agent-provided file `/var/lib/yolo-man/artec_temp`. Parses the numeric value and compares it against upper thresholds to determine state: OK (below warn), WARN (at or above warn, below crit), CRIT (at or above crit), or UNKNOWN if file missing or data invalid.

#### Parameters
None.

#### States
- **OK**: Temperature is below warning threshold.
- **WARN**: Temperature is at or above warning, but below critical threshold.
- **CRIT**: Temperature is at or above critical threshold.
- **UNKNOWN**: Agent file not found or contains non-numeric data.

#### Metrics
- `temp` — current temperature in °C.

### aruba_chassis_temp

<a id="check-aruba-chassis-temp"></a>

*Temperature %s*

#### Overview
Monitors chassis temperature sensors on Aruba network devices via SNMP to detect overheating risks that could impact hardware reliability and performance.

#### What it monitors
- Current, minimum, maximum, average, and threshold temperatures (in °C, °F, or K) for individual chassis temperature sensors.

#### How it works
In discovery mode, it walks the OID `.1.3.6.1.4.1.11.2.14.11.1.2.8.1.1` to enumerate all sensor indices. In check mode, it queries specific OIDs for a given sensor index (e.g., `.3` for current temp) using `snmpget`, parses temperature strings (e.g., `"45C"`), converts them to Celsius, and compares the current temperature against configurable warning/critical levels and device-provided thresholds. The worst state (user or device levels) determines the final state.

#### Parameters
`levels` (tuple, (50.0, 60.0)) — warning and critical thresholds in °C.
`device_levels_handling` (str, "worst") — how to combine user and device thresholds: `"worst"` or `"device"`.

#### States
OK — current temperature below warning threshold.
WARN — current temperature meets or exceeds warning threshold, or meets device threshold (depending on `device_levels_handling`).
CRIT — current temperature meets or exceeds critical threshold.
UNKNOWN — current temperature value missing or unparseable.

#### Metrics
`temp` — current chassis temperature, in °C.

### aruba_cpu_util

<a id="check-aruba-cpu-util"></a>

*CPU utilization %s*

#### Overview
Monitors CPU utilization on Aruba devices via SNMP, alerting when utilization exceeds threshold levels to prevent performance degradation.

#### What it monitors
- Per-CPU utilization percentages on Aruba networking devices (e.g., controllers, switches).

#### How it works
- In discovery mode (`_discover=1`), runs `snmpwalk` on OID `1.3.6.1.4.1.14823.2.2.1.1.1.9.1` to enumerate CPU entries (description and utilization OIDs), building per-CPU items.
- For each discovered item, runs `snmpget` on the corresponding utilization OID (e.g., `.3.<index>`) to fetch current CPU usage.
- Compares value against warning (80%) and critical (90%) thresholds to determine state.

#### Parameters
None.

#### States
- **OK**: CPU utilization below warning threshold (< 80%).
- **WARN**: Utilization at or above warning but below critical threshold (≥ 80% and < 90%).
- **CRIT**: Utilization at or above critical threshold (≥ 90%).
- **UNKNOWN**: No usable value returned from SNMP (e.g., OID missing or non-numeric).

#### Metrics
- `cpu_util` — current CPU utilization as a percentage (unit: %).

### aruba_fan_status

<a id="check-aruba-fan-status"></a>

*Fan Status %s*

#### Overview
Monitors fan status on Aruba 2930M switches via SNMP to detect hardware failures or abnormal operation, ensuring proper cooling and system reliability.

#### What it monitors
- Fan tray identifiers
- Fan operational state (e.g., OK, Failed, Removed)
- Fan type (e.g., MM, FM, IM)
- Number of failures per fan

#### How it works
In discovery mode, it verifies the device is an Aruba 2930M using `sysDescr`, then walks the fan table OID `.1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1` to enumerate fans. In check mode, it fetches a specific fan entry with `snmpget`, parses the 5-field `STRING: "tray;type;state;unknown;failures"` response, and maps `state` to OK/WARN/CRIT using a predefined map (e.g., state `0` → CRIT). Returns UNKNOWN if the device isn’t Aruba 2930M, fan not found, or data malformed.

#### Parameters
None.

#### States
- **CRIT**: Fan state is `0` (Failed)
- **WARN**: Fan state is `1`–`4` (Removed, Off, Underspeed, Overspeed)
- **OK**: Fan state is `5`–`6` (OK, MaxState)
- **UNKNOWN**: Device not Aruba 2930M, fan not found, or malformed SNMP data

#### Metrics
None.

### aruba_psu_status

<a id="check-aruba-psu-status"></a>

*PSU Status %s*

#### Overview
Monitors the operational status and key metrics (power, temperature, uptime) of power supply units (PSUs) in Aruba network devices via SNMP.

#### What it monitors
- PSU operational state (e.g., Powered, Failed, NotPresent)
- Current power draw (watts)
- Maximum rated power (watts)
- Internal temperature (°C)
- Uptime (time since last PSU power-on or reset)

#### How it works
In discovery mode, it walks the Aruba PSU OID subtree (`.1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1`) to enumerate present PSUs, skipping those marked `NotPresent` or `NotPlugged`. In check mode, it fetches per-PSU metrics via `snmpget` and maps the numeric state code to human-readable states. CRIT is returned for `Failed`, `PermFailure`, `AuxFailure`, `NotPowered`, and `AuxNotPowered`; OK otherwise. UNKNOWN is returned for unrecognized states.

#### Parameters
None.

#### States
- **OK**: PSU is present, powered, or plugged but inactive (e.g., `Powered`, `NotPresent`, `NotPlugged`)
- **CRIT**: PSU has failed, is unpowered, or has auxiliary issues (`Failed`, `PermFailure`, `AuxFailure`, `NotPowered`, `AuxNotPowered`)
- **UNKNOWN**: PSU OID not found or state code unmapped

#### Metrics
- `psu_state` — 1 if powered, else 0 (unitless)
- `temperature` — current internal temperature (°C)
- `power` — current power draw (W)
- `wattage_max` — maximum rated power (W)

### aruba_psu_temp

<a id="check-aruba-psu-temp"></a>

*PSU Temperature %s*

#### Overview
Monitors the temperature of power supply units (PSUs) in Aruba networking devices to detect overheating that could indicate hardware failure or inadequate cooling.

#### What it monitors
- PSU temperature in degrees Celsius for each individually discoverable PSU.

#### How it works
Performs SNMP walks using `snmpwalk` to enumerate PSUs (OID `1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.1`) and their temperatures (OID `...1.55.1.1.1.4`). During discovery, it creates per-PSU services with default warning/critical thresholds of 50°C/60°C. In check mode, it matches the requested PSU `item` (index) to the temperature value and compares it against configurable levels.

#### Parameters
None.

#### States
- **OK**: Temperature below warning threshold (default < 50°C).
- **WARN**: Temperature at or above warning, below critical threshold (50–59.9°C by default).
- **CRIT**: Temperature at or above critical threshold (≥ 60°C default).
- **UNKNOWN**: PSU item not found or temperature unavailable.

#### Metrics
- `temperature` — PSU temperature in °C.

### aruba_psu_wattage

<a id="check-aruba-psu-wattage"></a>

*PSU Wattage %s*

#### Overview
Monitors the power supply unit (PSU) wattage on Aruba devices via SNMP, alerting on current power draw exceeding thresholds and reporting utilization percentage.

#### What it monitors
- Current PSU power consumption (watts)
- Maximum rated PSU wattage (watts)
- PSU operational state (e.g., Powered, Failed, NotPresent)
- PSU voltage info and uptime

#### How it works
Uses `snmpwalk` during discovery to enumerate PSUs by OID `.1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1`, extracting model and index to build item names. In check mode, uses `snmpget` per OID to retrieve wattage, state, and auxiliary data. Compares current wattage against absolute and percentage thresholds (default: 500/600 W upper absolute, 80/90% upper utilization) to determine OK/WARN/CRIT states.

#### Parameters
- `levels_abs_upper` (list of 2 floats, [500.0, 600.0]) — CRIT and WARN thresholds for absolute wattage.
- `levels_abs_lower` (list of 2 floats, [0.0, 0.0]) — WARN and CRIT thresholds for low wattage.
- `levels_perc_upper` (list of 2 floats, [80.0, 90.0]) — CRIT and WARN thresholds for utilization %.
- `levels_perc_lower` (list of 2 floats, [0.0, 0.0]) — WARN and CRIT thresholds for low utilization %.

#### States
- **OK**: PSU state is Powered/NotPresent/NotPlugged/Max, and wattage within all thresholds.
- **WARN**: Wattage or utilization exceeds WARN level (or falls below lower WARN threshold) while CRIT not triggered.
- **CRIT**: PSU state is Failed/PermFailure/AuxFailure/NotPowered/AuxNotPowered, or wattage/utilization exceeds CRIT level (or falls below lower CRIT threshold).
- **UNKNOWN**: Discovery failed, item format invalid, or required SNMP data missing.

#### Metrics
- `power` — current PSU power draw, in watts.
- `utilization` — current power as % of maximum rated capacity, in percent.

### aruba_sw_temp

<a id="check-aruba-sw-temp"></a>

*Temperature %s*

#### Overview
Monitors the temperature of sensors on Aruba network switches via SNMP, alerting on excessive temperatures or device-level fault conditions to prevent hardware damage or performance degradation.

#### What it monitors
- Current temperature (`cur`) of each sensor
- Sensor status (e.g., normal, warning, emergency, fault)
- Minimum and maximum temperature thresholds per sensor

#### How it works
Performs SNMP `snmpwalk` on OID `.1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1` to enumerate and read temperature sensors. In discovery mode, it builds a list of active sensors (excluding “absent” ones). In check mode, it locates the specified sensor by name, extracts its values, applies context-aware default thresholds (e.g., CPU/ASIC: 80/90 °C, inlet: 30/40 °C), and compares current temperature against those thresholds. Final state is overridden by device status (e.g., “emergency” → CRIT).

#### Parameters
None.

#### States
- **OK**: Temperature below warning threshold and sensor status is “normal”.
- **WARN**: Temperature between warn and crit thresholds, or sensor status is “warning”/“fault”.
- **CRIT**: Temperature at/above critical threshold, or sensor status is “emergency”.
- **UNKNOWN**: Sensor not found or status is “absent”.

#### Metrics
- `temp` — Current temperature in °C.

### atto_fibrebridge_chassis

<a id="check-atto-fibrebridge-chassis"></a>

*Throughput Status*

#### Overview
Monitors the temperature and throughput status of an ATTO FibreBridge chassis via SNMP to detect hardware anomalies that could lead to performance degradation or failure.

#### What it monitors
- Chassis temperature (°C) via SNMP OIDs related to operating limits and current readings.
- Throughput status (Normal/Warning/Unknown) via a dedicated SNMP OID.

#### How it works
In discovery mode, it enumerates two services: “Chassis” (temperature) and “” (throughput). For temperature: runs `snmpwalk` on four OIDs, parses integer values for min/max operating temps and current temp, then compares current temp against optional warning/critical thresholds. For throughput: runs `snmpget` on OID `.1.3.6.1.4.1.4547.2.3.2.11`, interprets status as 1=Normal (OK), 2=Warning (WARN), else UNKNOWN.

#### Parameters
None.

#### States
- OK: Chassis temp below thresholds (and valid SNMP data); throughput status = 1 (Normal).
- WARN: Chassis temp ≥ warning threshold; or throughput status = 2 (Warning).
- CRIT: Chassis temp ≥ critical threshold.
- UNKNOWN: SNMP errors, malformed output, non-numeric values, or throughput status is neither 1 nor 2.

#### Metrics
- `temperature` — current chassis temperature in °C. Throughput status emits no metrics.

### atto_fibrebridge_chassis_temp

<a id="check-atto-fibrebridge-chassis-temp"></a>

*Temperature %s*

#### Overview
Monitors the internal chassis temperature of an ATTO FibreBridge SAN-to-SAN bridge device via SNMP, ensuring it stays within safe operating limits to prevent hardware failure or performance degradation.

#### What it monitors
- Internal chassis temperature (°C) of the ATTO FibreBridge device
- Minimum and maximum operating temperature thresholds (used for alerting)

#### How it works
The check uses `snmpwalk` to query four specific OIDs on the local host (SNMP community: `public`). In discovery mode, it verifies presence of all required OIDs to confirm the chassis is detectable. In check mode, it reads the current chassis temperature (OID `.1.3.6.1.4.1.4547.2.3.2.8`) and compares it against the min/max operating thresholds (OIDs `.1.3.6.1.4.1.4547.2.3.2.4` and `.1.3.6.1.4.1.4547.2.3.2.5`), using those thresholds directly as warning and critical limits.

#### Parameters
None.

#### States
- **OK**: Temperature is between the min/max operating thresholds (inclusive).
- **WARN**: Temperature equals or exceeds upper threshold or equals or falls below lower threshold.
- **CRIT**: Temperature exceeds upper threshold or falls below lower threshold (same logic as WARN per current code).
- **UNKNOWN**: SNMP query fails or required OIDs are missing.

#### Metrics
- `temperature` — Current chassis temperature in °C.

### atto_fibrebridge_sas

<a id="check-atto-fibrebridge-sas"></a>

*SAS Port %s*

#### Overview
Monitors the operational and administrative states of SAS (Serial Attached SCSI) ports on an ATTO Technology FibreBridge device via SNMP. Ensures ports are enabled and online, which is critical for reliable high-speed storage connectivity.

#### What it monitors
- SAS port operational state (e.g., online, offline, degraded, unknown)
- SAS port administrative (admin) state (enabled/disabled)
- Operational states of up to four physical PHY lanes per port

#### How it works
In discovery mode, it runs `snmpwalk` on `.1.3.6.1.4.1.4547.2.3.3.3.1` to enumerate enabled SAS ports; each port is discovered as a service item. In check mode, it uses `snmpget` for a specific port’s OIDs to retrieve current port and PHY states, then maps integer values to textual states. State verdicts follow a strict hierarchy: `online`→OK, `degraded`→WARN, `offline`→CRIT, `unknown`→UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Port is operational and online.
- **WARN**: Port is degraded.
- **CRIT**: Port is offline.
- **UNKNOWN**: State is unknown, SNMP query fails, or data is incomplete.

#### Metrics
None.

### audiocodes_fru

<a id="check-audiocodes-fru"></a>

*FRU %s*

#### Overview
Monitors Field Replaceable Units (FRUs) on AudioCodes devices via SNMP, checking both their operational status and action state to detect hardware failures or maintenance issues.

#### What it monitors
- FRU module status (e.g., exists/ok, out of service, faulty)
- FRU action state (e.g., action done, out of service, not applicable)

#### How it works
Uses `snmpwalk` on OID `.1.3.6.1.4.1.5003.9.10.10.4.21.1` to fetch FRU action (`.13`) and status (`.14`) values. During discovery, items are derived from OID indices. In check mode, it retrieves values for a specific item and maps numeric codes to states using predefined mappings; CRIT/WARN states take precedence over OK/UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Status/action indicates healthy or neutral state (e.g., “Action done”, “Module exists and ok”).
- **WARN**: Out of service action (status not directly mapped, but action=“Out of service” triggers WARN).
- **CRIT**: Faulty, mismatch, or out-of-service module status (e.g., “Module faulty”, “Module mismatch”).
- **UNKNOWN**: SNMP failure, missing item, or unmapped status/action codes.

#### Metrics
None.

### audiocodes_leds

<a id="check-audiocodes-leds"></a>

*LED Status*

#### Overview
Monitors the status of LEDs on Audiocodes network devices (such as voice gateways) via SNMP to provide immediate visual indication of hardware health.

#### What it monitors
- Module LEDs (up to 20 modules)
- Fan tray LEDs (up to 10 trays)
- Power supply LEDs (up to 5 PSUs, plus redundant ones)
- Redundant fan tray and power supply LEDs

Each LED’s status (ON/FLASHING) and color (GREEN, RED, YELLOW, ORANGE, BLUE, NONE, or UNKNOWN) are captured.

#### How it works
Uses `snmpget` to query specific OIDs for LED data (hex-encoded status). Converts each hex string’s last character to a status/color pair via a lookup table. Aggregates results across all LED types: counts colors, determines worst state per color (GREEN=OK, YELLOW/ORANGE/BLUE=WARN, RED=CRIT, others=UNKNOWN), and reports aggregate state.

#### Parameters
None.

#### States
- **OK**: All LEDs GREEN or NONE.
- **WARN**: Any YELLOW, ORANGE, or BLUE LEDs present.
- **CRIT**: Any RED LEDs present.
- **UNKNOWN**: No LEDs found, or LEDs with UNKNOWN status/color.

#### Metrics
None.

### audiocodes_operational_state

<a id="check-audiocodes-operational-state"></a>

*Operational state module %s*

#### Overview
This check monitors the operational state of AudioCodes hardware modules (e.g., voice cards or DSP units) on supported devices. It ensures timely detection of hardware failures or degraded states that could impact telephony services.

#### What it monitors
- Operational state of individual modules (running, not ready, failed, inactive, power off)
- Presence status (present/absent)
- HA (High Availability) status (active/standby/disabled/error)

#### How it works
In discovery mode, the check reads `/var/lib/yolo-man/json/audiocodes_operational_state` and enumerates each module key as an individual item. In check mode, it retrieves the JSON file and evaluates the `operational_state` integer (1–5) to determine OK/WARN/CRIT/UNKNOWN states. Details are built from presence and HA status fields. Returns UNKNOWN if file, item, or fields are missing.

#### Parameters
None.

#### States
- OK: `operational_state == 1` (running)
- WARN: `operational_state == 2` (not ready) or `4` (inactive)
- CRIT: `operational_state == 3` (failed) or `5` (power off)
- UNKNOWN: any other value, missing module, or missing agent data

#### Metrics
- `operational_state` — raw integer code of the module’s operational state (unit: dimensionless)

### audiocodes_operational_state_redundant

<a id="check-audiocodes-operational-state-redundant"></a>

*Operational state redundant module %s*

#### Overview
Monitors the operational state of redundant audioCodes modules via SNMP to detect hardware failures or degraded redundancy.

#### What it monitors
- Operational state of a specific redundant module (identified by `item`)
- Module presence (present/missing)
- HA (High Availability) status

#### How it works
- In discovery mode (`_discover`), runs `snmpwalk` on OID `.1.3.6.1.4.1.5003.9.10.10.4.27.21.1.8` to enumerate module IDs.
- For each module, runs `snmpget` for three OIDs: operational state (`.8`), presence (`.4`), and HA status (`.9`).
- Maps operational state: 1→OK, 2→WARN, 3/4→CRIT.
- Returns UNKNOWN if the module is missing (`presence == 2`) or data is incomplete.

#### Parameters
None.

#### States
- **OK**: `operational_state == 1`
- **WARN**: `operational_state == 2`
- **CRIT**: `operational_state == 3 or 4`
- **UNKNOWN**: module missing, missing data, or unparseable state

#### Metrics
- `operational_state` — numeric operational state value (1–4), or -1 if unavailable
- `ha_status` — numeric HA status, or -1 if unavailable

### audiocodes_temperature

<a id="check-audiocodes-temperature"></a>

*Temperature %s*

#### Overview
This check monitors the internal temperature of Audiocodes VoIP devices via SNMP, ensuring hardware operates within safe thermal limits to prevent failures or degraded performance.

#### What it monitors
- Temperature of individual sensors on the Audiocodes device (e.g., CPU, line cards, power modules)
- Each sensor is identified by its SNMP index

#### How it works
In discovery mode, it runs `snmpwalk` on OID `.1.3.6.1.4.1.5003.9.10.10.4.21.1.11` to enumerate all temperature sensors. In check mode, it uses `snmpget` on the specific sensor OID. It parses the integer temperature values (in °C), skips sensors reporting `-1` (not available), and applies configurable warning/critical thresholds (default: 25°C/35°C). The state is CRIT if temperature ≥ critical, WARN if ≥ warning, else OK.

#### Parameters
None.

#### States
- **OK**: Temperature is below warning threshold (default < 25°C) or sensor reports `-1` (not available).
- **WARN**: Temperature ≥ warning threshold and < critical threshold.
- **CRIT**: Temperature ≥ critical threshold.
- **UNKNOWN**: SNMP query fails, response malformed, or value not parseable.

#### Metrics
- `temperature` — current temperature reading in °C

### avaya_45xx_cpu

<a id="check-avaya-45xx-cpu"></a>

*CPU utilization CPU %s*

#### Overview
Monitors CPU utilization on Avaya 45xx series network devices via SNMP to detect performance degradation or overload risks.

#### What it monitors
- CPU utilization percentage per logical CPU item on the device

#### How it works
Uses `snmpwalk` to query the OID `.1.3.6.1.4.1.45.1.6.3.8.1.1.5.3` for integer CPU utilization values. During discovery, it enumerates all returned items as per-CPU services (indexed by occurrence order). In check mode, it extracts the value corresponding to the given item index and compares it against levels (default 90%/95% WARN/CRIT).

#### Parameters
None.

#### States
- **OK**: CPU utilization < 90% (or configured WARN threshold)
- **WARN**: CPU utilization ≥ 90% but < 95%
- **CRIT**: CPU utilization ≥ 95%
- **UNKNOWN**: SNMP walk fails or no matching CPU item found for the index

#### Metrics
- `util` — CPU utilization as a percentage (%)

### avaya_45xx_fan

<a id="check-avaya-45xx-fan"></a>

*Fan Chassis %s*

#### Overview
This check monitors the operational status of fans in Avaya 45xx series chassis via SNMP, ensuring cooling systems are functioning properly to prevent hardware overheating and failures.

#### What it monitors
- Fan status (e.g., normal, warning, critical, removed, disabled) for each discovered fan unit in the chassis.

#### How it works
On discovery (`_discover` mode), it performs an `snmpwalk` on OID `.1.3.6.1.4.1.45.1.6.3.3.1.1.10.6` to enumerate fan indices and their statuses. For each discovered fan, it creates a per-item service. In normal mode, it uses `snmpget` on the specific fan’s OID to retrieve its status, maps the numeric status to textual and state equivalents using a predefined map, and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
None.

#### States
- **OK**: Fan status is Normal (5), Removed (3), Disabled (4), or Obsoleted (12).
- **WARN**: Fan status is Reset in Progress (6), Testing (7), Warning (8), Non-fatal error (9), or Not configured (11).
- **CRIT**: Fan status is Fatal error (10).
- **UNKNOWN**: Status is Other (1), Not available (2), or unrecognized value; or SNMP query fails.

#### Metrics
None.

### avaya_45xx_temp

<a id="check-avaya-45xx-temp"></a>

*Temperature Chassis %s*

#### Overview
Monitors chassis temperature sensors on Avaya S5-series network devices via SNMP to detect overheating conditions that could impair hardware reliability.

#### What it monitors
- Individual temperature sensor values from the device chassis (e.g., ambient, component-specific sensors)

#### How it works
In discovery mode (`_discover=true`), it walks the OID `.1.3.6.1.4.1.45.1.6.3.7.1.1.5` via `snmpwalk`, extracts integer sensor values, and returns discovered items. In check mode, it retrieves the same OID, finds the sensor matching the provided `item`, converts the raw integer value to Celsius (divided by 2), and compares against configurable upper warning/critical levels to determine state.

#### Parameters
`levels` (tuple, `(55.0, 60.0)`) — upper warning and critical temperature thresholds in °C.

#### States
- **OK**: Temperature below warning threshold
- **WARN**: Temperature ≥ warning threshold and < critical threshold
- **CRIT**: Temperature ≥ critical threshold
- **UNKNOWN**: Sensor not found in SNMP output

#### Metrics
`temp` — chassis temperature in °C

### avaya_88xx

<a id="check-avaya-88xx"></a>

*Temperature Fan %s*

#### Overview
This check monitors the temperature of sensors on Avaya 88xx series network devices via SNMP, critical for preventing hardware overheating and ensuring stable operation.

#### What it monitors
- Temperature values (in °C) of individual temperature sensors
- Optional fan state discovery (via same SNMP subtree, but not used in check mode)

#### How it works
In discovery mode, it runs `snmpwalk` on `.1.3.6.1.4.1.2272.1.4.7.1.1` to enumerate temperature (`.2.`) and fan (`.3.`) instances. For each discovered temperature sensor, it creates a check item with default warning/critical levels of 55°C/60°C. In check mode, it runs `snmpget` for the specific sensor OID, parses the integer temperature value, and compares it to configured levels to determine OK/WARN/CRIT.

#### Parameters
- `item` (string, required) — sensor instance identifier
- `levels` (tuple of two floats, default `(55.0, 60.0)`) — warning and critical temperature thresholds in °C

#### States
- **OK**: temperature < warning level
- **WARN**: temperature ≥ warning and < critical level
- **CRIT**: temperature ≥ critical level
- **UNKNOWN**: SNMP query fails, malformed response, or invalid value

#### Metrics
- `temp` — temperature in °C

### avaya_88xx_fan

<a id="check-avaya-88xx-fan"></a>

*Fan %s Status*

#### Overview
Monitors the status of fans in Avaya 88xx series network devices via SNMP to detect hardware failures early.

#### What it monitors
- Fan operational state (Running, Down, or Unknown) for each fan unit.

#### How it works
- In discovery mode, it performs an SNMP walk on OID `.1.3.6.1.4.1.2272.1.4.7.1.1.2` to count fans; creates a single discovery item (no per-fan items) for single-service monitoring.
- In check mode, it re-fetches the same OID, maps numeric fan states to text and yolo-man states: `1` → UNKNOWN, `2` → OK (Running), `3` → CRIT (Down). Defaults to fan index 0 if no item specified.

#### Parameters
None.

#### States
- **OK**: Fan is Running (`INTEGER: 2`).
- **CRIT**: Fan is Down (`INTEGER: 3`).
- **UNKNOWN**: Fan state is Unknown (`INTEGER: 1`) or SNMP walk/command fails, or index out of range.

#### Metrics
None.

### avaya_chassis_card

<a id="check-avaya-chassis-card"></a>

*Card %s*

#### Overview
Monitors the operational status of Avaya chassis cards via SNMP, ensuring critical hardware components are functioning correctly in telecom infrastructure.

#### What it monitors
- Card operational status (up, down, testing, dormant, unknown)
- Card identity (name/index) during service discovery

#### How it works
In discovery mode, performs an SNMP walk on `.1.3.6.1.4.1.2272.1.4.9.1.1.1` (card name) and `.1.3.6.1.4.1.2272.1.4.9.1.1.6` (oper status), pairing entries by index to enumerate cards. For a specific item, it first walks the name table to map the card name to its numeric index, then uses `snmpget` to retrieve that card’s oper status. The status value is mapped to OK/WARN/CRIT/UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Card status is `1` (up) or `3` (testing) or `5` (dormant).
- **CRIT**: Card status is `2` (down).
- **UNKNOWN**: Card not found, SNMP operations fail, or status is `4` (unknown).

#### Metrics
None.

### avaya_chassis_ps

<a id="check-avaya-chassis-ps"></a>

*Power Supply %s*

#### Overview
Monitors the operational status of power supplies on Avaya network devices via SNMP, ensuring redundancy and reliability of critical infrastructure.

#### What it monitors
- Power supply name (e.g., "PS1")
- Power supply status (e.g., present and supplying power, failure indicated)

#### How it works
Uses `snmpwalk` to query OID `.1.3.6.1.4.1.2272.1.4.8.1.1` for power supply inventory and status. In discovery mode, it enumerates installed units (status ≠ 2) and registers them as services. In check mode, it retrieves the status of a specific power supply and maps numeric codes to states (OK/WARN/CRIT/UNKNOWN). Returns UNKNOWN if item not found.

#### Parameters
None.

#### States
- **OK**: Power supply is present and supplying power (status code 3).
- **WARN**: Power supply not installed (code 2) or unknown status (code 1).
- **CRIT**: Failure indicated (code 4).
- **UNKNOWN**: Item not specified or not found.

#### Metrics
None.

### avaya_chassis_temp

<a id="check-avaya-chassis-temp"></a>

*Temperature %s*

#### Overview
Monitors the internal chassis temperature of an Avaya device via SNMP to ensure hardware remains within safe operating limits and prevent thermal damage.

#### What it monitors
- Chassis temperature in degrees Celsius.

#### How it works
Uses `snmpget` to query the Avaya-specific SNMP OID `.1.3.6.1.4.1.2272.1.100.1.2`. In discovery mode, it yields a single service item named `"Chassis"` with default warning/critical thresholds `[55.0, 60.0]`. In check mode, it parses the SNMP response manually (no `try/except`), extracts the integer temperature value, compares against configurable upper levels, and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
None.

#### States
- **OK**: Temperature is below the warning threshold.
- **WARN**: Temperature is at or above the warning level but below the critical level.
- **CRIT**: Temperature is at or above the critical level.
- **UNKNOWN**: SNMP query fails, returns no data, or response format is invalid.

#### Metrics
- `temperature` — Chassis temperature in °C.

### bdtms_tape_info

<a id="check-bdtms-tape-info"></a>

*Tape Library Info*

#### Overview
Monitors tape library hardware by gathering basic identification information via SNMP, ensuring the device is present and responding with expected firmware and serial details.

#### What it monitors
- Tape library vendor name
- Product ID
- Serial number
- Software revision

#### How it works
In discovery mode, yields a single service item. In check mode, queries four specific SNMP OIDs under `.1.3.6.1.4.1.20884.1.{1-4}` using `ctx.snmp_get`. If fewer than 4 values are returned (or `None`), reports UNKNOWN. Otherwise, constructs a summary of each field (or `<empty>` if missing) and reports OK.

#### Parameters
None.

#### States
- OK: All four SNMP values retrieved successfully (even if some are empty).
- UNKNOWN: SNMP query returns `None` or fewer than 4 values.
- WARN/CRIT: Not applicable.

#### Metrics
None.

### bdtms_tape_module

<a id="check-bdtms-tape-module"></a>

*Tape Library Module %s*

#### Overview
Monitors the status of tape library modules in BDTMS tape libraries via SNMP, checking module, board, and power supply health to detect hardware failures.

#### What it monitors
- Module status (e.g., “ok”, “fail”)
- Board status
- Power supply status

#### How it works
In discovery mode (`_discover`), it walks `.1.3.6.1.4.1.20884.2.4.1` via `snmpwalk`, confirms the device OID matches BDTMS (.1.3.6.1.4.1.20884.77.83.1), and extracts module IDs from OID suffixes. In check mode, it uses `snmpget` per module to fetch three status strings (OID suffixes .4, .5, .6), parses them, and maps “ok” → OK, else CRIT. Overall state is CRIT if any subcomponent is CRIT, else WARN (if any WARN), else OK.

#### Parameters
None.

#### States
- **OK**: All module, board, and power supply statuses are “ok”.
- **WARN**: None are CRIT, but at least one is “warn” (note: source maps only “ok” to OK/CRIT; no explicit WARN handling—this state likely does not occur unless statuses include “warn”).
- **CRIT**: Any of module, board, or power supply status is not “ok” (e.g., “fail”).
- **UNKNOWN**: Module ID not found in SNMP data.

#### Metrics
None.

### bintec_cpu

<a id="check-bintec-cpu"></a>

*CPU utilization*

#### Overview
This check monitors CPU utilization on Bintec devices via SNMP, aggregating user, system, and streams CPU usage percentages into a total utilization metric. It matters because high CPU usage can indicate performance degradation or resource exhaustion on network devices.

#### What it monitors
- CPU user utilization percentage
- CPU system utilization percentage
- CPU streams utilization percentage
- Total CPU utilization (sum of user + system + streams)

#### How it works
The check uses `snmpwalk` to query three specific Bintec OID branches (`.1.3.6.1.4.1.272.4.17.4.1.1.15.1.0`, `.1.3.6.1.4.1.272.4.17.4.1.1.16.1.0`, `.1.3.6.1.4.1.272.4.17.4.1.1.17.1.0`). During discovery, it checks if any SNMP data exists to determine if one service instance applies. In check mode, it parses SNMP integer values from the response, sums the three components, and compares the total against warning (default 80.0) and critical (default 90.0) thresholds.

#### Parameters
None.

#### States
- OK: total utilization < warning threshold (default 80%)
- WARN: total utilization ≥ warning threshold but < critical threshold
- CRIT: total utilization ≥ critical threshold (default 90%)
- UNKNOWN: SNMP query fails or returns no data

#### Metrics
- `streams` — streams CPU utilization percentage (%)
- `util` — total CPU utilization percentage (%)

### bintec_sensors_fan

<a id="check-bintec-sensors-fan"></a>

*%s*

#### Overview
Monitors fan speed (RPM) on Bintec network devices via SNMP, ensuring cooling components operate within safe thresholds to prevent hardware overheating.

#### What it monitors
- Fan rotation speed in revolutions per minute (RPM) for each discovered fan.

#### How it works
Performs SNMP walk on OID `1.3.6.1.4.1.272.4.17.7.1.1.1` to retrieve fan data. During discovery (`_discover` mode), it parses entries where fan type (column 3) equals "2" (running fan) and creates per-fan services. In check mode, it locates the specified fan item, extracts its RPM value from column 5, and compares against thresholds. States are determined by comparing RPM against user-defined warning (default 2000) and critical (default 1000) lower bounds.

#### Parameters
None.

#### States
- **OK**: RPM is above the warning threshold (>2000 by default).
- **WARN**: RPM is at or below warning threshold but above critical (≤2000 and >1000 by default).
- **CRIT**: RPM is at or below critical threshold (≤1000 by default).
- **UNKNOWN**: Fan item not found or RPM value unparsable.

#### Metrics
- `rpm` — Fan rotation speed in revolutions per minute.

### bintec_sensors_temp

<a id="check-bintec-sensors-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Bintec devices via SNMP, providing alerts when readings exceed configured thresholds to prevent hardware overheating.

#### What it monitors
- Temperature values from individual sensors (e.g., internal components, ambient) identified by description.

#### How it works
Uses `snmpwalk` to query the Bintec MIB subtree `.1.3.6.1.4.1.272.4.17.7.1.1.1`. During discovery, it enumerates sensors of type `"1"` (temperature) and creates per-sensor services with default levels (35.0°C warn, 40.0°C crit). During checks, it locates the specified sensor by description, extracts the integer value (scaled by 1/10), and compares it against thresholds to determine state.

#### Parameters
None.

#### States
- OK: Temperature < warn threshold.
- WARN: Temperature ≥ warn threshold but < critical.
- CRIT: Temperature ≥ critical threshold.
- UNKNOWN: Sensor not found in SNMP data.

#### Metrics
- `temp` — Temperature in degrees Celsius (°C), as a floating-point value derived from the raw integer sensor reading divided by 10.

### bintec_sensors_voltage

<a id="check-bintec-sensors-voltage"></a>

*Voltage %s*

#### Overview
Monitors DC voltage levels of sensors on Bintec devices via SNMP, providing real-time voltage readings for operational status and health assessment.

#### What it monitors
- Voltage values (in millivolts) from individual voltage sensors detected on the device.

#### How it works
- In discovery mode, it performs an SNMP walk on OID `.1.3.6.1.4.1.272.4.17.7.1.1.1`, parses entries by index, and identifies sensors where `sensor_type == "3"` (voltage type), returning them as discoverable items.
- In check mode, it walks the same OID, matches the requested sensor item by descriptor (`field 3`), then retrieves its voltage value (`field 5`) at the same index, converts millivolts to volts, and reports the result.

#### Parameters
None.

#### States
- **OK**: Voltage value is found and reported successfully.
- **UNKNOWN**: Sensor item is not found or no valid data retrieved.
- **WARN/CRIT**: Not applicable; no threshold logic implemented in this check.

#### Metrics
- `voltage` — measured voltage in volts (V), derived from sensor’s millivolt reading divided by 1000.

### blade_bays

<a id="check-blade-bays"></a>

*BAY %s*

#### Overview
Monitors blade server bays in IBM BladeCenter or compatible chassis via SNMP, tracking bay identity, operational state, and power consumption to ensure hardware integrity and detect failures.

#### What it monitors
- Bay identifier (e.g., "Bay 1")
- Bay type (e.g., "blade", "fan", "power")
- Operational state (e.g., 1=online, 2=offline, 3=failed)
- Current power draw (e.g., "120W")
- Maximum rated power capacity (e.g., "200W")

#### How it works
Gathers SNMP data from two power domain trees (OIDs `.1.3.6.1.4.1.2.3.51.2.2.10.2.1.1` and `.1.3.6.1.4.1.2.3.51.2.2.10.3.1.1`) using `snmpwalk`. Discovery enumerates all bays via SNMP walks on both trees. For each discovered bay, the check reads state and power values; it reports CRIT if state indicates failure/offline, WARN if power exceeds 80% of maximum, otherwise OK.

#### Parameters
None.

#### States
- OK: Bay state is online and power draw ≤80% of max.
- WARN: Bay power draw >80% of max.
- CRIT: Bay state indicates failure or offline.
- UNKNOWN: SNMP data unavailable or parsing fails.

#### Metrics
- `power` — Current power draw in watts
- `power_max` — Maximum rated power capacity in watts

### blade_blades

<a id="check-blade-blades"></a>

*Blade %s*

#### Overview
Monitors the status of individual blades in a BladeCenter chassis via SNMP, checking existence, power state, and health to detect hardware issues early.

#### What it monitors
- Blade existence (present or absent)
- Power state (on, off, standby, hibernate, unknown)
- Health status (good, warning, critical, maintenance mode, etc.)
- Blade name

#### How it works
During discovery, runs `snmpwalk` on `.1.3.6.1.4.1.2.3.51.2.22.1.5.1.1` to identify blades by `.2.<index>` OIDs. For each discovered blade, runs `snmpget` for OIDs `.2.<item>`, `.3.<item>`, `.4.<item>`, `.5.<item>`, and `.6.<item>` to fetch existence, power, health, name, and unknown field. Maps SNMP integer values to states using predefined tables; overall state prioritizes CRIT > WARN > OK > UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Blade exists, power is on, health is good.
- **WARN**: Power in standby/hibernate, or health in warning/maintenance/flashing mode.
- **CRIT**: Blade missing, power off/no power/insufficient power, or health critical/communication failure.
- **UNKNOWN**: SNMP query fails, incomplete data, or unmapped values.

#### Metrics
None.

### blade_blowers

<a id="check-blade-blowers"></a>

*Blower %s*

#### Overview
Monitors the operational status and speed of hardware blowers (typically in server or network equipment) via SNMP, ensuring cooling systems are functioning correctly to prevent overheating.

#### What it monitors
- Blower operational state (OK/CRIT)
- Blower speed as a percentage of maximum
- Blower speed in RPM

#### How it works
Discovers blowers via SNMP walk on `.1.3.6.1.4.1.2.3.51.2.2.3`, counting devices with state OID `.3.10.x`/`.3.11.x` and excluding those with state `"0"` (unknown). For check mode, it queries specific OIDs for the given item (`index/total` format), extracting speed `%`, RPM, and state. OK if state is `"1"`, otherwise CRIT. UNKNOWN if SNMP fails or item data is missing.

#### Parameters
None.

#### States
- **OK**: Blower state is `"1"` (operational).
- **CRIT**: Blower state is not `"1"` (e.g., failed or error).
- **UNKNOWN**: SNMP query fails, item format invalid, or required OID data not found.

#### Metrics
- `perc` — Blower speed as percentage of max (unit: `%`)
- `rpm` — Blower speed in revolutions per minute (unit: `RPM`)

### blade_bx_blades

<a id="check-blade-bx-blades"></a>

*Blade %s*

#### Overview
This check monitors the operational status of physical blades (e.g., in blade server chassis) using agent-mode data. It ensures critical hardware components are present and functioning.

#### What it monitors
- Presence of individual blades (via status code)
- Blade identification (ID, name, serial number)
- Operational state: OK, error, critical, standby, unknown, or absent

#### How it works
In discovery mode, the check reads agent section data from `/var/lib/check_mk_agent/section/blade_bx_blades` (or spool fallback), parses tab-separated lines (`id status serial name`), and discovers blades where status ≠ "3" (not present). In check mode, it finds the requested blade item, maps the numeric status to a state (OK/WARN/CRIT/UNKNOWN) using internal rules, and reports details including name and serial.

#### Parameters
None.

#### States
- **OK**: Blade status is "2" (OK) or "6" (standby).
- **CRIT**: Blade status is "4" (error) or "5" (critical).
- **UNKNOWN**: Blade status is "1" (unknown), "3" (not present), or item not found.
- **UNKNOWN**: Agent section file unavailable.

#### Metrics
None.

### blade_bx_load

<a id="check-blade-bx-load"></a>

*CPU load*

#### Overview
Monitors CPU load on BladeBX devices via SNMP, providing single, 5-, and 15-minute load averages. It matters for detecting sustained high CPU utilization that may indicate performance degradation or system overload.

#### What it monitors
- 1-minute, 5-minute, and 15-minute CPU load averages
- SNMP OID `.1.3.6.1.4.1.2021.10.1.6.0` (UCD-SNMP `laLoad`)

#### How it works
In discovery mode, it queries the load OID once, defaults 5- and 15-minute values to the 1-minute reading, and returns a single-service item with default thresholds. In check mode, it fetches the same OID, parses the load value, computes per-interval states using upper-bound thresholds (single-sided), and aggregates the worst state (CRIT > WARN > OK). Metrics and state are returned.

#### Parameters
None.

#### States
- **OK**: All three load averages (1/5/15 min) below their respective thresholds.
- **WARN**: Any load average meets or exceeds its warning threshold (if configured), but none reach critical.
- **CRIT**: Any load average meets or exceeds its critical threshold.
- **UNKNOWN**: SNMP query fails or returns unparseable data.

#### Metrics
- `load1` — 1-minute CPU load (unitless, dimensionless)
- `load5` — 5-minute CPU load (unitless, dimensionless)
- `load15` — 15-minute CPU load (unitless, dimensionless)

### blade_bx_powerfan

<a id="check-blade-bx-powerfan"></a>

*Blade Cooling %s*

#### Overview
Monitors the speed and status of cooling fans in BladeCenter BX systems via SNMP, ensuring adequate airflow and early detection of fan failures.

#### What it monitors
- Fan rotational speed (RPM)
- Fan speed as a percentage of maximum rated speed
- Fan operational status (OK, failed, not present, etc.)
- Fan control state (enabled/disabled)

#### How it works
Uses `snmpwalk` to query the `.1.3.6.1.4.1.7244.1.1.1.3.3.1.1` OID (BladeCenter fan table). In discovery mode, it parses fan entries and creates services for fans with status code 8 ("not-present" excluded). For each fan, it calculates speed percentage from RPM/max RPM. The check reports CRIT if control state ≠ "2" (enabled), status ≠ "3" (ok), or speed is outside configured lower/upper thresholds. Otherwise, OK or WARN based on threshold breaches.

#### Parameters
`levels_lower` (list, [20.0, 10.0]) — lower thresholds for warning and critical speed percentage.
`levels` (list, [80.0, 90.0]) — upper thresholds for warning and critical speed percentage.

#### States
- OK: fan present, enabled, status ok, speed within normal range.
- WARN: fan present and enabled, but speed below lower or above upper warning thresholds.
- CRIT: fan disabled or failed, or speed below lower or above upper critical thresholds.
- UNKNOWN: fan with requested description not found.

#### Metrics
- `perc` — fan speed as percentage of max speed (%)
- `rpm` — actual rotational speed (RPM)

### blade_bx_powermod

<a id="check-blade-bx-powermod"></a>

*Power Module %s*

#### Overview
Monitors the status of power modules in BladeCenter BX systems via SNMP, ensuring critical power infrastructure is operational.

#### What it monitors
- Per power module: operational status (e.g., OK, error, not present) and product name.

#### How it works
In discovery mode, it walks `.1.3.6.1.4.1.7244.1.1.1.3.2.4.1.1` to enumerate modules, then fetches their product names via `.1.3.6.1.4.1.7244.1.1.1.3.2.4.1.4.<idx>`. In check mode, it performs an `snmpget` for status (`.1.3.6.1.4.1.7244.1.1.1.3.2.4.1.2.<item>`) and product name (`.4.<item>`) for the specified item. It maps status integers to states: 2=OK, 3/4/5/6/7=CRIT, 1/8=UNKNOWN/OK respectively.

#### Parameters
None.

#### States
- OK: status integer is 2 (ok) or 8 (fanmodule).
- CRIT: status integer is 3 (not-present), 4 (error), 5 (critical), 6 (off), or 7 (dummy).
- UNKNOWN: status integer is 1 (unknown), parsing fails, SNMP fails, or no item specified.

#### Metrics
None.

### blade_bx_temp

<a id="check-blade-bx-temp"></a>

*Temperature Blade %s*

#### Overview
Monitors temperature sensors on BladeCenters (HP/HP Enterprise hardware) via SNMP, providing per-sensor status and alerts based on configured thresholds.

#### What it monitors
- Temperature readings from individual blade sensors (in °C)
- Sensor status (OK, warning, critical, failed, etc.)
- Sensor-specific warning and critical threshold levels

#### How it works
Uses SNMP to query the `1.3.6.1.4.1.7244.1.1.1.3.4.1.1` OID subtree. On discovery (`_discover=True`), it enumerates sensors by extracting description and status OIDs, adding only non-disabled sensors to discovery. For monitoring, it fetches full sensor rows, matches by item (sensor description), and evaluates state based on status code, critical reaction flag, and temperature vs thresholds. OK/WARN/CRIT decided via threshold comparison and status values.

#### Parameters
None.

#### States
- **OK**: Sensor status is `ok` (3), `crit_react` is `2` (normal), and temperature is below warning threshold.
- **WARN**: Same as OK, but temperature is at or above warning threshold.
- **CRIT**: Sensor status not OK, `crit_react` ≠ 2, or temperature at/above critical threshold.
- **UNKNOWN**: Discovery fails, SNMP query fails, or item not found.

#### Metrics
- `temp` — current temperature reading, unit: °C

### blade_health

<a id="check-blade-health"></a>

*Summary health state*

#### Overview
Monitors the hardware health state of blade servers via SNMP, providing a summary of system status (e.g., OK, degraded, or critical).

#### What it monitors
- Blade server health status OID (`.1.3.6.1.4.1.2.3.51.2.2.7.1.0`)
- Corresponding health description string (`.1.3.6.1.4.1.2.3.51.2.2.7.2.1.3.1`)

#### How it works
In discovery mode, it checks if the health status OID exists using `snmpwalk`. If found, it reports one service. In check mode, it retrieves the numeric state code and description via `snmpwalk`, maps the code to a status (255→OK, 2/4→WARN, 0→CRIT, else→UNKNOWN), and appends the description to the summary message.

#### Parameters
None.

#### States
- **OK**: State code is `255`
- **WARN**: State code is `2` or `4`
- **CRIT**: State code is `0`
- **UNKNOWN**: Unreachable OID, invalid/non-digit value, or unrecognized state code

#### Metrics
None.

### blade_mediatray

<a id="check-blade-mediatray"></a>

*Media tray*

#### Overview
Monitors the media tray of a device (e.g., printer or scanner) via SNMP to ensure it is physically present and communicating properly—critical for device functionality and preventing operational failures.

#### What it monitors
- Physical presence of the media tray
- Communication status of the media tray (i.e., whether it is responding)

#### How it works
Uses `snmpwalk` in discovery mode to check for presence (OID `.1.3.6.1.4.1.2.3.51.2.2.5.2.74`). If a value of `"1"` is found, one service is discovered (no item name, single-service check). In check mode, it runs `snmpget` for the same presence OID and a communication OID (`.75`). It parses both values; if either is not `"1"`, it reports CRIT; otherwise OK.

#### Parameters
None.

#### States
- **OK**: Media tray is present (OID .74 = "1") *and* communicating (OID .75 = "1").
- **CRIT**: Media tray not present (.74 ≠ "1") or not communicating (.75 ≠ "1").
- **UNKNOWN**: SNMP query fails or output lacks required values.

#### Metrics
None.

### blade_powerfan

<a id="check-blade-powerfan"></a>

*Power Module Cooling Device %s*

#### Overview
Monitors the speed and operational status of power module cooling fans on IBM BladeCenter hardware via SNMP, ensuring adequate thermal management to prevent overheating.

#### What it monitors
- Fan rotation speed as a percentage of maximum speed
- Fan RPM value
- Fan operational status (OK/failed)
- Fan controller state (OK/failed)

#### How it works
Uses `snmpwalk` to query the IBM BladeCenter power fan OID `.1.3.6.1.4.1.2.3.51.2.2.6.1.1`. In discovery mode, it enumerates all fans; in check mode, it validates a specific fan item. It parses SNMP values grouped in 7-field rows per fan. Critical states are triggered if fan status or controller state is not OK, or if speed falls below thresholds (CRIT ≤40%, WARN ≤50%).

#### Parameters
None.

#### States
- **OK**: Fan present, status OK, controller OK, speed >50%.
- **WARN**: Fan present, status OK, controller OK, speed ≤50% but >40%.
- **CRIT**: Fan absent, status not OK, controller not OK, or speed ≤40%.
- **UNKNOWN**: Fan not found or SNMP query failed.

#### Metrics
- `perc` — fan speed percentage (%)
- `rpm` — fan speed in revolutions per minute (RPM)

### blade_powermod

<a id="check-blade-powermod"></a>

*Power Module %s*

#### Overview
Monitors the operational status of power modules in BladeCenter or compatible hardware via SNMP, ensuring redundancy and power supply health for high-availability systems.

#### What it monitors
- Presence of each power module (`present`)
- Operational status (e.g., OK, failed) per module (`status`)
- Human-readable status text (`text`)
- Module name/label (`name`)

#### How it works
Performs an SNMP walk on OID `.1.3.6.1.4.1.2.3.51.2.2.4.1.1` to enumerate power modules. During discovery, it groups entries by index, extracting name, presence, status, and text. In check mode, it filters to the specified `item`, verifies presence (`present == "1"`), and sets state based on `status`: `1` = OK, otherwise CRIT.

#### Parameters
None.

#### States
- **OK**: Power module present and `status == "1"`.
- **CRIT**: Module not present (`present != "1"`) or `status != "1"`.
- **UNKNOWN**: SNMP walk fails.

#### Metrics
None.

### bluecoat_diskcpu

<a id="check-bluecoat-diskcpu"></a>

*%s*

#### Overview
Monitors CPU/disk sensor readings from Bluecoat devices via SNMP, tracking per-item health status and metric values to detect hardware issues.

#### What it monitors
- Per-CPU or per-disk sensor name, numeric reading (e.g., temperature, usage), and operational status (OK/failed) from Bluecoat devices.

#### How it works
Performs an SNMP walk on OID `1.3.6.1.4.1.3417.2.4.1.1.1` to discover items (names, readings, status). During check mode, it re-fetches SNMP data, maps index-based values to names, and evaluates each item: if status == 1 → OK, otherwise CRIT; missing items → UNKNOWN. Discovery enumerates per-item services.

#### Parameters
None.

#### States
- OK: item exists and status == 1 (healthy).
- CRIT: item exists but status != 1 (faulty).
- UNKNOWN: item not found or SNMP walk fails.

#### Metrics
- `value` — numeric sensor reading (unit depends on sensor type, e.g., %, °C).

### bluenet2_powerrail

<a id="check-bluenet2-powerrail"></a>

*Inlet %s*

#### Overview
Monitors power inlet metrics (voltage, current, power, apparent power, frequency) on Bachmann blue NET2 devices via SNMP. Critical for detecting electrical faults or overloads in infrastructure power supply.

#### What it monitors
- Voltage (RMS)
- Current (RMS)
- Real power (W)
- Apparent power (VA)
- AC frequency (Hz)

#### How it works
In discovery mode, it enumerates "Inlet" items—currently only "Inlet 1"—from SNMP data (simulated). In check mode, it validates that the item starts with `"Inlet "`, then reports OK with placeholder metrics since SNMP access is unavailable in this Starlark runtime. Real operation requires SNMP via a special agent.

#### Parameters
None.

#### States
- **OK**: Item discovered and metrics within expected thresholds (placeholder values used here due to runtime constraints).
- **UNKNOWN**: Item name does not start with `"Inlet "` or SNMP data unavailable.
- **WARN/CRIT**: Not implemented in this translation (requires thresholds from config, not present).

#### Metrics
- `voltage` — Volts
- `current` — Amperes
- `power` — Watts
- `appower` — Volt-Amperes
- `frequency` — Hertz

### bluenet2_powerrail_fuses

<a id="check-bluenet2-powerrail-fuses"></a>

*Fuse %s*

#### Overview
This check monitors the status and electrical readings (current, voltage, power, etc.) of individual fuses in a BlueNET2 power rail system. It matters for early detection of overloads, failures, or abnormal behavior in power distribution units.

#### What it monitors
- Per-fuse electrical metrics: current, voltage, power, apparent power, and frequency
- Fuse status state (OK, WARN, CRIT, UNKNOWN) derived from embedded health indicators

#### How it works
The check reads a JSON agent output file (`/var/lib/cmk-agent/agent_output.json`) containing the `bluenet2_powerrail` section. In discovery mode (`_discover`), it enumerates all fuses under the `fuses` dict and creates one service per fuse. In check mode, it retrieves data for the specified `item` (fuse name), extracts metric values and status states, and sets the overall state based on the worst status (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN).

#### Parameters
None.

#### States
- OK: All metrics present, status state 0.
- WARN: Any metric reports status state 1.
- CRIT: Any metric reports status state 2.
- UNKNOWN: No fuse data found, section missing, or status state 3.

#### Metrics
- `current` — fuse current draw in amperes (A)
- `voltage` — fuse voltage in volts (V)
- `power` — real power in watts (W)
- `appower` — apparent power in volt-amperes (VA)
- `frequency` — frequency in hertz (Hz)

### bluenet2_powerrail_inlet

<a id="check-bluenet2-powerrail-inlet"></a>

*Inlet %s*

#### Overview
Monitors the neutral current (in Ampere) of a BlueNexus 2 power inlet via SNMP, reporting status-based health and alarming on deviations.

#### What it monitors
- Neutral current (Ampere) for a specific inlet (e.g., "Inlet 1")
- Inlet status (e.g., OK, warning, error, lost, off)

#### How it works
In discovery mode, it walks `.1.3.6.1.4.1.31770.2.2.6.2.1.4` to enumerate inlets and create per-inlet services. In check mode, it walks four SNMP OIDs: type (`.6`), status (`.7`), scaling (`.9`), and raw value (`.5`), identifies the neutral current sensor (type `9`), computes current from the raw value, and maps status codes to yolo-man states (OK/WARN/CRIT/UNKNOWN).

#### Parameters
None.

#### States
- **OK**: Status `2` (OK), current within normal range.
- **WARN**: Status `5/6` (warning high/low) or `8/20/38` (deactivate/off/ongoing switch).
- **CRIT**: Status `3/4/7` (error high/low/lost).
- **UNKNOWN**: Discovery failed, item not found, sensor missing, or SNMP error.

#### Metrics
- `current` — Neutral current in Ampere (A).

### bluenet2_powerrail_rcm

<a id="check-bluenet2-powerrail-rcm"></a>

*Inlet %s*

#### Overview
Monitors differential leakage currents (AC and DC) in Residual Current Monitoring (RCM) phases of BlueNET2 power rails to detect potentially hazardous ground faults or insulation failures in electrical installations.

#### What it monitors
- Differential current AC (`differential_current_ac`) in amperes
- Differential current DC (`differential_current_dc`) in amperes
- Per RCM phase item discovered (e.g., phase identifiers from the `bluenet2_powerrail` SNMP section)

#### How it works
Uses `ctx.agent_section("bluenet2_powerrail")` to retrieve parsed JSON from the agent. For discovery, iterates over `rcm_phases` keys; for check mode, evaluates thresholds on the current AC/DC leakage values. Thresholds are applied in mA: values are converted from A (agent data) to mA for comparison with thresholds in mA (default: AC 3.5/30 mA, DC 70/100 mA). State is CRIT if either exceeds critical, WARN if either exceeds warning, else OK.

#### Parameters
None.

#### States
- OK: Both AC and DC leakage currents are below warning thresholds.
- WARN: At least one current (AC or DC) meets or exceeds warning threshold but not critical.
- CRIT: At least one current meets or exceeds critical threshold.
- UNKNOWN: Specified RCM phase item not found in the section.

#### Metrics
- `differential_current_ac` — AC leakage current in amperes (A)
- `differential_current_dc` — DC leakage current in amperes (A)

### bluenet2_powerrail_sockets

<a id="check-bluenet2-powerrail-sockets"></a>

*Socket %s*

#### Overview
Monitors the status and electrical metrics (voltage, current, power, etc.) of power rail sockets on a BlueNet2 device via SNMP, ensuring reliable power delivery and early detection of hardware issues.

#### What it monitors
- Voltage (volts)
- Current (amperes)
- Apparent power (VA)
- Active power (W)
- Frequency (Hz)
- Socket operational status (e.g., OK, warning, critical, lost)

#### How it works
In discovery mode, it runs `snmpwalk` on OID `.1.3.6.1.4.1.31770.2.2.6.5.1.8` to enumerate sockets and extract friendly names and indices. In check mode, it uses `snmpget` on per-socket OIDs to retrieve individual metrics and status. Status codes are mapped to OK/WARN/CRIT/UNKNOWN states.

#### Parameters
None.

#### States
- OK: Socket status code maps to OK (e.g., “2” or “43”)
- WARN: Warning-level status (e.g., “5”, “6”, “20”)
- CRIT: Critical status (e.g., “3”, “4”, “7”)
- UNKNOWN: Undefined status (code “1”) or socket not found/SNMP failure

#### Metrics
- `voltage` — Voltage in volts
- `apparent_power` — Apparent power in VA
- `power` — Active power in W
- `frequency` — Frequency in Hz
- `status_code` — Raw numeric status (not emitted, used internally); status is reflected in state

### bluenet_sensor_hum

<a id="check-bluenet-sensor-hum"></a>

*Humidity %s*

#### Overview
Monitors humidity levels from BlueNET environmental sensors via SNMP, alerting when readings exceed safe thresholds—critical for preventing equipment damage or environmental hazards.

#### What it monitors
- Humidity percentage (%) from combined temperature/humidity sensors (type "2") on BlueNET devices.
- Sensors identified as “internal” (ID 0) or “external *N*”.

#### How it works
Uses `snmpwalk` to query OID `.1.3.6.1.4.1.21695.1.10.7.3.1` for sensor data. In discovery mode, it parses output to enumerate humidity-capable sensors; in check mode, it retrieves the specific sensor’s humidity value (divided by 10), compares against configurable thresholds, and returns OK/WARN/CRIT based on upper/lower limits.

#### Parameters
None.

#### States
- **OK**: Humidity between lower and upper thresholds (inclusive of safe zones).
- **WARN**: Humidity ≥ upper threshold (e.g., >60%) or ≤ lower threshold (e.g., <40%).
- **CRIT**: Humidity ≥ critical upper (e.g., ≥65%) or ≤ critical lower (e.g., ≤35%).
- **UNKNOWN**: SNMP query failure or sensor not found/matching item.

#### Metrics
- `humidity` — Current relative humidity percentage (%).

### brocade_fan

<a id="check-brocade-fan"></a>

*FAN %s*

#### Overview
Monitors the speed of fans on Brocade hardware via SNMP/agent data, alerting when fan RPM falls below configured thresholds, which may indicate cooling failure.

#### What it monitors
- Fan RPM values (speed in revolutions per minute) for each discovered fan unit.

#### How it works
- **Discovery mode**: Reads the Brocade agent section (via `/var/lib/check-mk-agent/source/brocade` or fallback `grep`), parses lines starting with `<<<brocade>>>`, filters entries whose name starts with `FAN`, presence ≠ 6, and state > 0, extracts sensor IDs, and yields per-fan services with default `{"lower": [3000, 2800]}`.
- **Check mode**: Reuses agent parsing, locates the specific fan by item, retrieves its RPM, compares against lower thresholds (default: warn ≤3000, crit ≤2800), and returns state.

#### Parameters
None.

#### States
- **OK**: Fan RPM ≥ lower warn threshold (≥3000 by default).
- **WARN**: Fan RPM ≤ lower warn but > lower crit (e.g., 2800 < RPM ≤ 3000).
- **CRIT**: Fan RPM ≤ lower crit (≤2800 by default).
- **UNKNOWN**: Fan item not found or agent section unavailable.

#### Metrics
- `fan_speed` — current fan speed in RPM.

### brocade_info

<a id="check-brocade-info"></a>

*Brocade Info*

#### Overview
Monitors Brocade Fibre Channel switch hardware by gathering model, serial number (SSN), firmware version, and world-wide name (WWN) via SNMP. Useful for inventory, asset tracking, and verifying device identity.

#### What it monitors
- Switch model (e.g., Brocade Fabric OS device model)
- Serial number (SSN)
- Firmware version
- World-wide name (WWN)

#### How it works
Performs SNMP walk commands using `snmpwalk` with community `public` to fetch device identification OIDs. In discovery mode, checks for Brocade OID prefixes to confirm device type. In check mode, retrieves and parses four specific OIDs: `.1.3.6.1.2.1.47.1.1.1.1.2.1` (model), `.1.3.6.1.4.1.1588.2.1.1.1.1.6.0` (firmware), `.1.3.6.1.4.1.1588.2.1.1.1.1.10.0` (SSN), `.1.3.6.1.3.94.1.6.1.1.0` (WWN). Parses output strings to extract values; formats WWN as colon-separated hex bytes. Reports OK if at least one field is non-default; UNKNOWN otherwise.

#### Parameters
None.

#### States
- OK: At least one of model, SSN, firmware, or WWN is successfully retrieved and non-empty.
- UNKNOWN: All four values are missing or default ("−"), i.e., no information found.
- CRIT/WARN: Not used.

#### Metrics
None.

### brocade_mlx_fan

<a id="check-brocade-mlx-fan"></a>

*Fan %s*

#### Overview
Monitors the operational state of fans on Brocade MLXe routers via SNMP. Fan failures can lead to overheating and hardware damage, so detecting them early is critical for system reliability.

#### What it monitors
- Fan identifier (`id`)
- Fan description (`descr`)
- Fan operational state (`state`), mapped as: 1=other, 2=normal, 3=failure

#### How it works
The check uses `snmpwalk` to fetch fan data from the OID `.1.3.6.1.4.1.1991.1.1.1.3.1.1`. In discovery mode, it builds a list of non-"other" state fans (i.e., states 2 or 3) as discoverable items. During normal checks, it matches the specified item (by ID or ID+description) and maps state 2 → OK, 3 → CRIT, 1 → UNKNOWN, and unknown states → UNKNOWN.

#### Parameters
None.

#### States
- OK: Fan state is 2 (normal)
- CRIT: Fan state is 3 (failure)
- UNKNOWN: Fan state is 1 (other), an unhandled state value, or the fan item is not found
- UNKNOWN (also): Discovery mode returns metadata only; no health state applies

#### Metrics
None.

### brocade_mlx_module_mem

<a id="check-brocade-mlx-module-mem"></a>

*Memory Module %s*

#### Overview
Monitors memory usage of NI-MLX and BR-MLX line cards on Brocade MLX series routers by querying SNMP. Ensures memory utilization remains within safe thresholds to prevent performance degradation or module failure.

#### What it monitors
- Memory module state (must be "Running")
- Total memory (bytes)
- Available memory (bytes)
- Used memory (bytes and percentage)

#### How it works
In discovery mode, SNMP walks `.1.3.6.1.4.1.1991.1.1.2.2.1.1` to list memory modules; skips empty ("0") or non-running ("11") modules and non-NI/BR-MLX types. In check mode, retrieves same data, finds the requested module by item name, verifies it is in "Running" state ("10"), computes used memory, and compares percentage used against thresholds (default 80%/90% warn/crit).

#### Parameters
`levels` (list, `[80.0, 90.0]`) — warning and critical thresholds as percentages of memory used.

#### States
- OK: Module is running and used memory % < warning threshold.
- WARN: Module is running and used memory % ≥ warning but < critical threshold.
- CRIT: Module is running and used memory % ≥ critical threshold.
- UNKNOWN: Module not found, not running, memory total ≤ 0, or SNMP parse failure.

#### Metrics
`mem_used` — used memory in bytes.
`mem_used_percent` — used memory as percentage of total.

### brocade_mlx_module_status

<a id="check-brocade-mlx-module-status"></a>

*Status Module %s*

#### Overview
Monitors the operational status of Brocade MLX module hardware (e.g., line cards, fabric cards) via the Brocade MLX agent output. Critical for ensuring chassis subsystems are healthy and functioning correctly.

#### What it monitors
- Module presence and identity (ID and description)
- Module operational state (e.g., running, rejected, faulty, in power-up cycle)

#### How it works
Reads `/var/lib/yolo-man/agent_output/brocade_mlx.json`, a JSON array where the first element lists modules as `[id, description, state_code]`. In discovery mode (`_discover`), it generates per-module services for non-empty slots (state ≠ "0"). For a specific service item, it matches the item string (ID + cleaned description) and maps numeric state codes to OK/WARN/CRIT/UNKNOWN states using a fixed states map.

#### Parameters
None.

#### States
- OK: Module state is "10" (Running) or "11" (Blocked for full height card).
- WARN: Slot empty ("0"), module going down ("2"), configured/stacking ("8"), or in power-up cycle ("9").
- CRIT: Module rejected due to wrong configuration ("3") or hardware failure ("4").
- UNKNOWN: Module not found, or an unhandled state code.

#### Metrics
None.

### brocade_mlx_power

<a id="check-brocade-mlx-power"></a>

*Power supply %s*

#### Overview
Monitors the operational state of power supplies on Brocade MLX/E-series network devices via SNMP, ensuring redundant power systems remain functional to prevent unexpected outages.

#### What it monitors
- Power supply unit (PSU) state (normal, failure, other/unknown)
- Discovery of PSUs with non-normal states for alerting

#### How it works
Uses `snmpwalk` to query Brocade-specific SNMP OIDs (`.1.3.6.1.4.1.1991.1.1.1.2.2.1` first, falls back to `.1.3.6.1.4.1.1991.1.1.1.2.1.1`). In discovery mode, it groups SNMP responses into `(id, description, state)` triples and reports only PSUs not in state `1` ("other"/normal). In check mode, it matches the requested `item`, retrieves its state, and maps: `2` → OK, `3` → CRIT, `1`/others → UNKNOWN.

#### Parameters
None.

#### States
- **OK**: PSU state code `2` (normal).
- **CRIT**: PSU state code `3` (failure).
- **UNKNOWN**: PSU state code `1`, any other code, SNMP failure, or PSU not found.

#### Metrics
None.

### brocade_mlx_temp

<a id="check-brocade-mlx-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Brocade MLX series routers via SNMP to detect overheating risks that could lead to hardware failure or performance degradation.

#### What it monitors
- Individual temperature sensor readings (e.g., module or sensor temperatures) on Brocade MLX devices.

#### How it works
In discovery mode (`_discover`), it walks OID `.1.3.6.1.4.1.1991.1.1.2.13.1.1.3` to enumerate sensor descriptions, extracts indices, and constructs service items. For a specific sensor, it maps the item name to its OID index using the description OID, then retrieves the raw value from OID `.1.3.6.1.4.1.1991.1.1.2.13.1.1.4`, multiplies it by 0.5 to get Celsius, and compares against default levels (105.0/110.0 °C). UNKNOWN is returned if the sensor is not found or the value cannot be retrieved.

#### Parameters
None.

#### States
- **OK**: Temperature is below the warning threshold (≤105.0 °C).
- **WARN**: Temperature is at or above 105.0 °C but below 110.0 °C.
- **CRIT**: Temperature is at or above 110.0 °C.
- **UNKNOWN**: Sensor name not found, discovery issue, or value retrieval failed.

#### Metrics
- `temp` — Current temperature in degrees Celsius (°C).

### brocade_power

<a id="check-brocade-power"></a>

*Power supply %s*

#### Overview
Monitors the operational state of Brocade fabric switch power supplies via SNMP, detecting failures or anomalies that could lead to system instability or outages.

#### What it monitors
- Power supply presence (via SNMP table index 3, value “6” means absent)
- Power supply state (value “1” = OK; any other numeric value = error)
- Power supply name (e.g., “Power#1”) for identification

#### How it works
In discovery mode, it runs `snmpwalk` on `.1.3.6.1.4.1.1588.2.1.1.1.1.22.1` to enumerate power supplies, grouping entries by index and column (presence=3, state=4, name=5). Supplies with name starting with “Power”, present (presence ≠ 6), and valid state are added to the discovery list. In check mode, it queries the same OID for a specific supply (`item`) and returns CRIT if state ≠ 1, OK if state = 1, or UNKNOWN if not found or invalid state.

#### Parameters
None.

#### States
- OK: Supply present, state = 1
- CRIT: Supply present, state ≠ 1 (e.g., failure, warning)
- UNKNOWN: Supply not found, SNMP query fails, state is non-numeric, or item missing

#### Metrics
None.

### brocade_sys

<a id="check-brocade-sys"></a>

*CPU utilization*

#### Overview
Monitors CPU utilization on Brocade fabric switches by reading agent section data or falling back to SNMP. Critical for assessing switch health and performance.

#### What it monitors
- CPU utilization percentage
- Memory utilization percentage (collected but not used in state logic)

#### How it works
First attempts to read from `/var/cache/mktxp/brocade_sys.json`. If unavailable, executes `snmpwalk` against specific Brocade OIDs (`.1.3.6.1.4.1.1588.2.1.1.1.26.1.0` and `.1.3.6.1.4.1.1588.2.1.1.1.26.6.0`) to extract CPU and memory metrics. If both values are present, it stores them; otherwise returns UNKNOWN. In discovery mode, it reports one discovered item. In check mode, compares `cpu_util` against optional warn/crit levels to decide OK/WARN/CRIT.

#### Parameters
None.

#### States
- **OK**: CPU utilization is below warning threshold.
- **WARN**: CPU utilization meets or exceeds the warning threshold but not the critical threshold.
- **CRIT**: CPU utilization meets or exceeds the critical threshold.
- **UNKNOWN**: Agent section file missing and SNMP query fails or returns incomplete data.

#### Metrics
- `cpu_util` — CPU utilization percentage (unit: percent)

### brocade_sys_mem

<a id="check-brocade-sys-mem"></a>

*Memory*

#### Overview
This check monitors system memory usage on Brocade network devices via SNMP, alerting when memory consumption exceeds configured thresholds—critical for detecting resource exhaustion that could impair device performance or stability.

#### What it monitors
- Memory usage as a percentage (sysMemUsage) on Brocade devices.

#### How it works
Performs SNMPv2c GET requests for OIDs `.1.3.6.1.4.1.1588.2.1.1.1.26.1` (CPU) and `.1.3.6.1.4.1.1588.2.1.1.1.26.6` (memory). In discovery mode (`_discover=true`), it creates a single service with empty item and default `levels=None`. In check mode, it parses the memory OID response to extract an integer percentage, then compares it against optional warning/critical thresholds to determine state.

#### Parameters
None.

#### States
- **OK**: Memory usage is below warning threshold (or thresholds not set).
- **WARN**: Usage meets or exceeds the warning level but is below critical.
- **CRIT**: Usage meets or exceeds the critical level.
- **UNKNOWN**: SNMP query fails or memory value cannot be parsed.

#### Metrics
- `mem_used_percent` — current memory utilization as a percentage (%).

### brocade_temp

<a id="check-brocade-temp"></a>

*Temperature Ambient %s*

#### Overview
Monitors ambient temperature sensors on Brocade FC switches via SNMP to detect overheating risks that could cause hardware failure.

#### What it monitors
- Temperature readings from individual sensors labeled like "SLOT #0: TEMP #1"
- Sensor presence and validity via SNMP OID `.1.3.6.1.4.1.1588.2.1.1.1.1.22.1`

#### How it works
On discovery (`_discover` flag), it walks the SNMP table, parses sensor strings (format `presence,state,name`), and yields per-sensor services with default levels (55/60 °C). In check mode, it queries the same OID, matches the requested sensor `item`, and compares its integer temperature value against levels: `CRIT` if ≥ critical, `WARN` if ≥ warn, else `OK`.

#### Parameters
`levels` (tuple, `(55.0, 60.0)`) — warn/critical temperature thresholds in °C.

#### States
- **OK**: temperature < warn threshold
- **WARN**: warn ≤ temperature < critical
- **CRIT**: temperature ≥ critical
- **UNKNOWN**: SNMP query fails or sensor not found

#### Metrics
`temperature` — current sensor reading in °C

### brocade_vdx_status

<a id="check-brocade-vdx-status"></a>

*Status*

#### Overview
Monitors the operational status and firmware version of a Brocade VDX switch via SNMP. Critical for ensuring hardware health and timely identification of potential failures.

#### What it monitors
- Operational status (online, offline, testing, faulty)
- Firmware version

#### How it works
Performs an SNMP GET request on two OIDs (`.1.3.6.1.4.1.1588.2.1.1.1.1.6.0` for firmware, `.1.3.6.1.4.1.1588.2.1.1.1.1.7.0` for status) using community string `public`. Parses responses to extract firmware string and integer status code, mapping status to OK/WARN/CRIT/UNKNOWN. If SNMP data is missing, returns UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Status code `1` (online)
- **WARN**: Status code `3` (testing)
- **CRIT**: Status code `2` (offline) or `4` (faulty)
- **UNKNOWN**: Missing SNMP data or unparseable status/firmware

#### Metrics
None.

### bvip_info

<a id="check-bvip-info"></a>

*System Info*

#### Overview
Monitors Basic Virtual IP (BVIP) system information via SNMP, ensuring the presence and consistency of unit identification data for embedded hardware devices.

#### What it monitors
- Unit name (OID `.1.3.6.1.4.1.3967.1.1.1.1.0`)
- Unit ID (OID `.1.3.6.1.4.1.3967.1.1.1.2.0`)

#### How it works
In discovery mode, runs `snmpwalk` against the BVIP root OID; if output exists, it discovers one service per host. In check mode, uses `snmpget` to fetch the unit name and unit ID OIDs. Parses SNMP `STRING:` values, then reports OK if both are retrieved, with a summary line combining them. Fails with UNKNOWN on SNMP errors or incomplete data.

#### Parameters
None.

#### States
- **OK**: Both unit name and unit ID retrieved successfully.
- **UNKNOWN**: SNMP query fails (`snmpget` returns non-zero RC) or fewer than two lines in output.
- **WARN/CRIT**: Not applicable.

#### Metrics
None.

### bvip_poe

<a id="check-bvip-poe"></a>

*POE Power*

#### Overview
Monitors Power over Ethernet (POE) power consumption on Beward VIP/X-series IP cameras via SNMP. Ensures POE load stays within safe limits to prevent overloading or equipment damage.

#### What it monitors
- POE power output (in watts) delivered to connected devices, retrieved from the device-specific SNMP OID `.1.3.6.1.4.1.3967.1.1.10`.

#### How it works
- In discovery mode, checks if the host is a Beward device (via system description) and if POE is active (non-zero OID value). Only creates a service if POE is present and enabled.
- In check mode, reads the POE power OID via `snmpget`, converts the integer value to watts (divide by 10), and compares against configurable thresholds (`levels`).
- Returns OK/WARN/CRIT based on thresholds; UNKNOWN if OID value is missing.

#### Parameters
None.

#### States
- **OK**: POE power is below warning threshold.
- **WARN**: POE power is at or above warning threshold but below critical threshold.
- **CRIT**: POE power is at or above critical threshold.
- **UNKNOWN**: POE power value cannot be retrieved (e.g., SNMP error or zero/missing value).

#### Metrics
- `power` — POE power consumption in watts.

### bvip_temp

<a id="check-bvip-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on IPMI-enabled hardware via SNMP to detect overheating risks.

#### What it monitors
- Temperature readings (in °C) from individual sensors discovered via SNMP OID `.1.3.6.1.4.1.3967.1.1.7.1`

#### How it works
In discovery mode, runs `snmpwalk` to enumerate sensor OIDs and creates per-sensor check services with default thresholds (50°C warn, 60°C crit). In check mode, retrieves the specific sensor’s value via SNMP, divides it by 10 (raw value is in 0.1°C units), and compares to configurable thresholds to decide OK/WARN/CRIT.

#### Parameters
None.

#### States
- **OK**: Temperature < warn threshold (default < 50°C)
- **WARN**: Temperature ≥ warn and < crit threshold (50–60°C)
- **CRIT**: Temperature ≥ crit threshold (≥ 60°C)
- **UNKNOWN**: SNMP walk fails or sensor item not found

#### Metrics
- `temp` — Current sensor temperature in °C

### bvip_util

<a id="check-bvip-util"></a>

*CPU utilization %s*

#### Overview
Monitors CPU utilization for specific components (Total, Coder, VCA) on a hardware device via SNMP, providing alerting based on configurable thresholds to detect performance degradation or overload.

#### What it monitors
- CPU utilization percentage for Total (aggregate), Coder, and VCA (Video Content Analyzer) subsystems.

#### How it works
The check performs an SNMP walk on OID `.1.3.6.1.4.1.3967.1.1.9.1` to fetch three integer utilization values. During discovery, it auto-generates three check items (Total, Coder, VCA) with default levels of 90/95%. For each item, it extracts the corresponding value, inverts Total (100 − value) to represent used CPU, compares against thresholds, and returns OK/WARN/CRIT/UNKNOWN based on state logic.

#### Parameters
`levels` (list or tuple, [90.0, 95.0]) — warning and critical thresholds (percent). None.

#### States
- OK: utilization below warning threshold.
- WARN: utilization at or above warning, below critical threshold.
- CRIT: utilization at or above critical threshold.
- UNKNOWN: invalid item, SNMP failure, or unexpected value count.

#### Metrics
`util` — CPU utilization percentage for the selected item (%).

### cadvisor_diskstat

<a id="check-cadvisor-diskstat"></a>

*Disk IO %s*

#### Overview
Monitors disk I/O utilization and throughput metrics collected by cAdvisor via the yolo-man agent. It helps detect storage performance degradation or bottlenecks before they impact applications.

#### What it monitors
- Disk utilization (% busy time)
- Read and write I/O operations per second (IOS)
- Read and write throughput (bytes per second)

#### How it works
Reads pre-aggregated cAdvisor diskstat data from `/var/lib/check_mk_agent/state/cadvisor_diskstat` (a JSON file). In discovery mode (`_discover` param), it lists each discovered disk as a separate service item. In check mode, it validates the specified disk exists, extracts metrics, and evaluates utilization against warning (default 70%) and critical (default 90%) thresholds (configurable via `utilization` param). Other metrics are reported as perfdata only.

#### Parameters
None.

#### States
- OK: utilization < warning threshold (default <70%)
- WARN: utilization ≥ warning and < critical threshold (70–90%)
- CRIT: utilization ≥ critical threshold (≥90%)
- UNKNOWN: data file missing/empty, invalid JSON, or requested disk not found

#### Metrics
- `utilization` — disk busy percentage (%)
- `write_ios` — write operations per second (count/s)
- `read_ios` — read operations per second (count/s)
- `write_throughput` — write bandwidth (B/s)
- `read_throughput` — read bandwidth (B/s)

### canon_pages

<a id="check-canon-pages"></a>

*Pages*

#### Overview
Monitors page-count metrics from Canon multifunction devices via SNMP, providing visibility into print volume and usage patterns for capacity planning and maintenance scheduling.

#### What it monitors
- Total pages printed
- Black-and-white and color page counts
- A3 and A4 paper size breakdowns
- Combinations: color/bw × A3/A4

#### How it works
Runs `snmpwalk` on the Canon device MIB `.1.3.6.1.4.1.1602.1.11.1.3.1` to fetch SNMP page counters. Parses numeric values from OID suffixes (e.g., `.301` → `pages_total`). If `pages_total` is absent, it sums all individual page types. Always returns a single service (discovery mode yields item `""`). State is OK unless no data found.

#### Parameters
None.

#### States
- **OK**: Data retrieved successfully.
- **UNKNOWN**: No page data returned (e.g., SNMP failure or device not reporting).

#### Metrics
- `pages_total` — total number of pages (unit: pages)
- `pages_color` — color pages (pages)
- `pages_bw` — black-and-white pages (pages)
- `pages_a4` — A4 pages (pages)
- `pages_a3` — A3 pages (pages)
- `pages_color_a4`, `pages_bw_a4`, `pages_color_a3`, `pages_bw_a3` — respective combinations (pages)

### casa_fan

<a id="check-casa-fan"></a>

*Fan %s*

#### Overview
Monitors the operational status and speed of fans on a CASA device via SNMP, ensuring hardware cooling remains within safe thresholds to prevent overheating and potential system failure.

#### What it monitors
- Fan rotation speed (in RPM)
- Fan operational status (OK, under/over threshold, failure, or unknown)

#### How it works
Uses `snmpwalk` to query two SNMP OIDs: one for fan speed (`.1.3.6.1.4.1.20858.10.31.1.1.1.2`) and one for status (`.1.3.6.1.4.1.20858.10.33.1.4.1.4`). In discovery mode, it enumerates all fans and reports each as a separate item. During normal checks, it retrieves speed and status for the specified fan item. Status values `1` (OK), `2`/`3` (WARN), `4` (CRIT), and `0` (UNKNOWN) determine the state.

#### Parameters
None.

#### States
- OK: Fan status is `1` (OK), normal speed reported.
- WARN: Fan status is `2` (under threshold) or `3` (over threshold).
- CRIT: Fan status is `4` (failure).
- UNKNOWN: Fan status is `0`, or fan not found in SNMP output.

#### Metrics
None.

### cbl_airlaser_hardware

<a id="check-cbl-airlaser-hardware"></a>

*CBL Airlaser Hardware*

#### Overview
Monitors hardware status and temperatures of a CBL Airlaser device using agent-provided structured data, ensuring critical components remain within safe thermal and operational limits to prevent laser failure or safety hazards.

#### What it monitors
- Temperatures: chassis, front screen, optical transmit (opttx), optical receive (optrx), and amplifier module (apmod)
- Power supply statuses: +48 V, +230 V, +5 V, +3.3 V, +2.5 V
- Fan statuses: chassis fan 1 and fan 2

#### How it works
In discovery mode, it yields a single service item with default temperature thresholds. In check mode, it parses agent output (expected to include cbl_airlaser sections) and compares measured values against thresholds: if any temperature exceeds WARN or CRIT limits, or a power/fan status indicates failure, the state degrades accordingly.

#### Parameters
None.

#### States
- OK: all temperatures within limits and power/fan statuses normal
- WARN: any temperature ≥ WARN threshold (but < CRIT) or minor power/fan issues
- CRIT: any temperature ≥ CRIT threshold or power/fan failure
- UNKNOWN: agent data missing, malformed, or parsing fails (e.g., no agent section)

#### Metrics
- chassisFrontScreenTempValue — temperature in °C
- chassisTempValue — temperature in °C
- opttxTempValue — temperature in °C
- optrxTempValue — temperature in °C
- apmodTempValue — temperature in °C
- chassisFan1Status — status (0=OK, 1=FAIL)
- chassisFan2Status — status (0=OK, 1=FAIL)
- psStatus48V, psStatus230V, psStatus5V, psStatus3V3, psStatus2V5 — power supply status (0=OK, 1=FAIL)

### checkpoint_fan

<a id="check-checkpoint-fan"></a>

*Fan %s*

#### Overview
Monitors the operational status and readings of server fans via SNMP, using the Dell/EMC OpenManage OID .1.3.6.1.4.1.2620.1.6.7.8.2.1. Ensures thermal subsystem health by detecting failed or out-of-range fans.

#### What it monitors
- Fan name (e.g., “CPU Fan”, “System Fan”)
- Fan speed or status value
- Fan unit (e.g., RPM)
- Fan device status (OK, critical, or error)

#### How it works
In discovery mode, it runs `snmpwalk` on the Dell fan status OID and parses name, value, unit, and status fields to enumerate fans. In check mode, it retrieves the same data for a specific fan item and maps status codes: `"0"` → OK, `"1"` → CRIT, `"2"` → UNKNOWN. Fallbacks handle missing data.

#### Parameters
None.

#### States
- **OK**: Fan status is `"0"` (sensor in range).
- **CRIT**: Fan status is `"1"` (sensor out of range).
- **UNKNOWN**: Fan status is `"2"`, missing data, or item not found.

#### Metrics
- `status` — numeric status: 0 (OK), 1 (CRIT), 2 (UNKNOWN).

### checkpoint_ha_status

<a id="check-checkpoint-ha-status"></a>

*HA Status*

#### Overview
Monitors the high-availability (HA) status of a Check Point firewall device via SNMP, reporting operational state, version, and blocking conditions to ensure redundancy and failover readiness.

#### What it monitors
- HA installation status
- Software version (major/minor)
- HA service started status
- Active/standby state
- Blocking state (e.g., initializing)
- Problem status code and description

#### How it works
The check retrieves 8 specific Check Point HA OIDs using `snmpget` against localhost (`127.0.0.1`) with community `public` and SNMPv2c. It parses the responses, checks for HA installation (OID .2 ≠ "0"), and evaluates HA state, started status, blocking state, and problem code to determine overall status. Discovery mode checks only if HA is installed.

#### Parameters
None.

#### States
- **OK**: HA installed, started, status is active/standby, blocking is OK, and problem code is 0.
- **WARN**: HA installed and started, but blocking is "initializing".
- **CRIT**: HA not installed, not started, invalid status, blocking error, or problem code ≠ 0.
- **UNKNOWN**: Insufficient SNMP data retrieved.

#### Metrics
None.

### checkpoint_memory

<a id="check-checkpoint-memory"></a>

*Memory System*

#### Overview
Monitors memory usage on Check Point firewalls via SNMP, using real-time utilization to assess system health and capacity.

#### What it monitors
- Total physical memory (`memTotalReal`)
- Available physical memory (`memAvailReal`)
- Computed used memory in bytes and percentage

#### How it works
Fetches two SNMP OIDs via `snmpget` for Check Point devices. In discovery mode, it probes the same OIDs with `snmpwalk` to confirm the presence of memory data; if both values are present, it yields a single service (item `""`). In check mode, it computes used memory (total − available), calculates percentage, compares against warning/critical thresholds (default 80%/90%), and sets state accordingly.

#### Parameters
None.

#### States
- OK: Usage is below warning threshold.
- WARN: Usage ≥ warning threshold but < critical threshold.
- CRIT: Usage ≥ critical threshold.
- UNKNOWN: SNMP query fails, response incomplete, or values non-numeric.

#### Metrics
- `memory_used` — used memory in bytes
- `memory_used_percent` — memory usage as percentage

### checkpoint_temp

<a id="check-checkpoint-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Check Point firewall devices via SNMP, using device-specific OID `.1.3.6.1.4.1.2620.1.6.7.8.1.1`. Critical for preventing hardware overheating and ensuring system stability.

#### What it monitors
- Temperature sensor names
- Current temperature values (numeric)
- Temperature units (Celsius/Fahrenheit)
- Sensor device status (in range/out of range/reading error)

#### How it works
In discovery mode, performs `snmpwalk` on the device’s temperature OID tree, parses results into structured sensor entries (name, value, unit, status), and returns discovered items with default thresholds `[50.0, 60.0]`. In check mode, walks the same OID, locates the specified item, parses its temperature and status, applies upper-level thresholds, and maps device status (`0`→OK, `1`→CRIT, `2`→UNKNOWN) alongside temperature-based severity.

#### Parameters
None.

#### States
- **OK**: Sensor status `0` *and* temperature below warning threshold.
- **WARN**: Sensor status `0` *and* temperature at or above warning threshold (but below critical).
- **CRIT**: Sensor status `1` *or* temperature at or above critical threshold.
- **UNKNOWN**: Sensor status `2`, SNMP walk failure, or item not found.

#### Metrics
- `temp` — current temperature value in degrees (unit: C or F).

### checkpoint_voltage

<a id="check-checkpoint-voltage"></a>

*Voltage %s*

#### Overview
Monitors voltage sensors on Checkpoint appliances via SNMP, ensuring hardware health by detecting out-of-range or faulty voltage readings.

#### What it monitors
- Voltage sensor names (e.g., "VCC Core", "3.3V").
- Current voltage values.
- Units (e.g., Volts).
- Device status (OK, out of range, or error).

#### How it works
During discovery, it runs `snmpbulkget` on Checkpoint-specific OIDs to enumerate voltage sensors. It parses SNMP output by grouping entries per instance and cross-checks device type via SNMP system description or distribution facts. For each discovered item, it later polls the same OIDs to fetch real-time values. It maps device status codes to yolo-man states (OK, CRIT, UNKNOWN) and returns the status with value and unit in the summary.

#### Parameters
None.

#### States
- **OK**: Sensor in range (status `"0"`).
- **CRIT**: Sensor out of range (status `"1"`).
- **UNKNOWN**: Reading error (status `"2"`), item not found, or non-Checkpoint host.

#### Metrics
None.

### ciena_cpu_util_5142

<a id="check-ciena-cpu-util-5142"></a>

*CPU utilization*

#### Overview
This check monitors CPU utilization on Ciena 5142 or 5171 network devices via SNMP, providing early warning of performance degradation or overload.

#### What it monitors
- CPU utilization percentage on the target device

#### How it works
The check first detects the device type (5142 or 5171) by querying the system description OID and falling back to OID walks for device-specific identifiers. It then retrieves CPU utilization using device-specific SNMP OIDs: `.1.3.6.1.4.1.6141.2.60.12.1.11.9` for 5142 and `.1.3.6.1.4.1.1271.2.1.5.1.2.1.4.5.1` for 5171. In discovery mode (`_discover=true`), it reports a single service item "CPU utilization". Thresholds default to 80% (WARN) and 90% (CRIT) and are applied to the numeric utilization value to determine state.

#### Parameters
None.

#### States
- OK: CPU utilization is below the warning threshold.
- WARN: CPU utilization meets or exceeds the warning threshold but is below the critical threshold.
- CRIT: CPU utilization meets or exceeds the critical threshold.
- UNKNOWN: Unable to retrieve CPU utilization (SNMP failure or unexpected format).

#### Metrics
- `utilization` — CPU utilization as a percentage (unit: percent).

### ciena_health

<a id="check-ciena-health"></a>

*Health*

#### Overview
Monitors the hardware health of Ciena network devices (e.g., packet optical platforms) by evaluating statuses of key components like power supplies and fans, ensuring operational resilience.

#### What it monitors
- TCE (Transmission Control Element) health status
- Power supply state
- Fan status
- LEO (Line Entity Operator) system state
- LEO power supply state
- LEO fan status

#### How it works
Reads health data from `/var/lib/check-mk-agent/cache/ciena_health.json`. During discovery, it checks for this file’s existence and reports one service item (no items list). For service checks, it parses JSON entries containing `display_name`, `data_type`, and `occurrences` (state → count mappings). Compares each component’s counts against expected “good” states (e.g., `normal`, `online`, `ok`). Marks the service as CRIT if any component has non-good states; otherwise OK. Unknown component types are skipped. Total count of health items and per-component breakdowns are included in details.

#### Parameters
None.

#### States
- OK: All monitored hardware components are in expected “good” states.
- CRIT: At least one component has a non-good state.
- UNKNOWN: Health data file is missing.

#### Metrics
None.

### ciena_temperature

<a id="check-ciena-temperature"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Ciena 5171 (CPS) and 5142 (Leo) optical network devices via SNMP, providing critical thermal health insights to prevent hardware failure.

#### What it monitors
- Temperature readings from individual sensors (in 0.1°C units, reported as integer °C)
- Sensor status states (e.g., normal, warning, faulted) per device type

#### How it works
Performs SNMP discovery using device-specific OIDs to enumerate temperature sensors. For active checks, it queries the relevant OID branch for temperature and status values using `snmpget`. It determines device type (5171 vs 5142) from the item format. Status values are mapped to health states, and temperature is compared against thresholds (default: warn ≥40°C, crit ≥50°C) to decide OK/WARN/CRIT.

#### Parameters
- `warn` (float, 40.0) — warning threshold temperature in °C
- `crit` (float, 50.0) — critical threshold temperature in °C
- `_discover` (bool, false) — triggers discovery mode to list sensors

#### States
- **OK**: Temperature below warn threshold and sensor status normal
- **WARN**: Temperature ≥ warn but < crit, or sensor in warning/degraded state (device-dependent)
- **CRIT**: Temperature ≥ crit, or sensor in faulted state
- **UNKNOWN**: SNMP query fails, item format invalid, or status is unknown

#### Metrics
- `temperature` — measured temperature in °C

### cisco_asa_failover

<a id="check-cisco-asa-failover"></a>

*Failover state*

#### Overview
Monitors the failover state of Cisco ASA firewalls to ensure high availability is functioning correctly. A misconfigured or failed failover can leave the network unprotected during device outages.

#### What it monitors
- Local device role (primary/secondary) and its operational status (e.g., active, standby)
- Remote device status
- Failover link status and name
- Whether each device matches expected operational states

#### How it works
The check retrieves parsed agent data from the `cisco_asa_failover` section (obtained via SNMP walking of `1.3.6.1.4.1.9.9.147.1.2.1.1.1`). It extracts role, status, and detail fields, maps numeric status codes to human-readable names (e.g., "9" → "active"), and compares them against configurable expectations (primary expected to be active, secondary to be standby, link expected up). The verdict is determined by validating role status, remote status, and link state against thresholds.

#### Parameters
None.

#### States
- **OK**: Local and remote devices are in expected states (primary active, secondary standby) and failover link is up.
- **WARN/CRIT**: Triggered when local/remote status deviates from expectations or link is down; severity depends on parameterized state codes (default: CRIT for unexpected role/link).
- **UNKNOWN**: Agent data missing or fails to parse local role.

#### Metrics
None.

### cisco_fan

<a id="check-cisco-fan"></a>

*FAN %s*

#### Overview
Monitors Cisco device fan status via SNMP to detect hardware failures or airflow issues that could lead to overheating. Critical for maintaining equipment reliability.

#### What it monitors
- Fan operational state (normal, warning, critical, shutdown, not present, not functioning)
- Fan description (e.g., "Fan Tray 1, Status OK")
- Sensor ID for unique identification

#### How it works
In discovery mode, it runs `snmpwalk` on Cisco MIB OIDs `.1.3.6.1.4.1.9.9.13.1.4.1.2`, `.3`, `.4` to enumerate fans and build per-item services. In check mode, it repeats the walk, matches the specified `item`, and maps `dev_state` (1–6) to states using `cisco_fan_state_mapping`. Unknown states default to UNKNOWN.

#### Parameters
None.

#### States
- OK: `dev_state == "1"` (normal)
- WARN: `dev_state == "2"` (warning)
- CRIT: `dev_state == "3"` (critical), `"4"` (shutdown), `"6"` (not functioning)
- UNKNOWN: `dev_state` not in {1–6}, SNMP fails, or fan item not found

#### Metrics
None.

### cisco_fantray

<a id="check-cisco-fantray"></a>

*Fan %s*

#### Overview
Monitors the operational status of Cisco fan tray modules via SNMP, ensuring cooling systems are functioning properly to prevent hardware overheating.

#### What it monitors
- Fan tray module status (e.g., powered on, powered down, partial failure)
- Fan tray identification names (from `entPhysicalName`)

#### How it works
Uses `snmpwalk` to query two SNMP tables:
1. `.1.3.6.1.4.1.9.9.117.1.4.1.1.1` (fan status codes)
2. `.1.3.6.1.2.1.47.1.1.1.1.7` (fan module names)
During discovery, it builds a per-item service list. In check mode, it maps status codes to states:
- `1` (unknown), `2` (powered on) → OK
- `3` (powered down), `4` (partial failure) → CRIT
Duplicate names get disambiguated with `-1`, `-2`, etc.

#### Parameters
None.

#### States
- **OK**: Fan tray is powered on or unknown status.
- **CRIT**: Fan tray is powered down or reports partial failure.
- **UNKNOWN**: No SNMP data, item not found.

#### Metrics
- `status` — numeric status code (0 for OK, 2 for CRIT).

### cisco_fru_module_status

<a id="check-cisco-fru-module-status"></a>

*FRU Module Status %s*

#### Overview
Monitors the operational status of Field-Replaceable Unit (FRU) modules in Cisco devices via SNMP. Critical for ensuring hardware redundancy and detecting failures in high-availability infrastructure.

#### What it monitors
- FRU module presence and type (via `entPhysicalClass`).
- Module name (via `entPhysicalName`).
- Operational status (via `cefcModuleOperStatus`), including states like OK, failed, missing, boot, disabled, etc.

#### How it works
- **Discovery mode**: Executes two `snmpwalk` commands to fetch physical entity classes/names and Cisco FRU operational statuses. Filters for modules (`entPhysicalClass` = 5), then emits per-item services with the module index.
- **Check mode**: Uses `snmpget` to fetch class, name, and status for a specific module index. Validates it is a module (class = 5), maps the status code to OK/WARN/CRIT using a Cisco-defined state map, and returns status with human-readable details.

#### Parameters
None.

#### States
- **OK**: Module operational status is 2 ("OK").
- **WARN**: Status codes 3, 4, 5, 6, 16, 18, 19, 20, 21, 22, 24, 25, 26 (e.g., disabled, boot, power-up, upgrade).
- **CRIT**: Status codes 1, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 23, 27 (e.g., failed, missing, powered down, firmware failure).
- **UNKNOWN**: Not a module, SNMP failure, missing item, or unrecognized status code.

#### Metrics
None.

### cisco_fru_power

<a id="check-cisco-fru-power"></a>

*FRU Power %s*

#### Overview
Monitors the operational status of Field-Replaceable Unit (FRU) power supplies in Cisco devices, ensuring critical power components are functioning correctly to prevent system instability or outages.

#### What it monitors
- State of each FRU power supply (e.g., on, off, failed, in alarm conditions)
- Discovery of FRU power items based on non-OK states (states other than 1 and 3)

#### How it works
Reads cached JSON data from `/var/lib/yolo-man-agent/cache/cisco_fru_power`. During discovery, it identifies FRU power items with states other than 1 (off env other) or 3 (off admin). For individual checks, it maps numeric state codes to human-readable descriptions and determines OK/WARN/CRIT/UNKNOWN states based on predefined mappings.

#### Parameters
None.

#### States
- **OK**: State is 2 (on)
- **WARN**: State is 1, 3, 9, 10, or 11 (various off or degraded conditions)
- **CRIT**: State is 4, 5, 6, 7, 8, or 12 (failed, denied, environmental, or inline power failure)
- **UNKNOWN**: Item not found or state code unmapped (e.g., 0)

#### Metrics
None.

### cisco_ie_temp

<a id="check-cisco-ie-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Cisco Industrial Ethernet (IE) switches via SNMP. Critical for preventing hardware failure due to overheating or excessive cooling in industrial environments.

#### What it monitors
- Temperature of individual sensors on Cisco IE switches, reported in tenths of degrees Celsius.

#### How it works
Discovers all sensors using `snmpwalk` on the OID `.1.3.6.1.4.1.9.9.832.1.24.1.3.6.1.5` and extracts sensor IDs as item names. In check mode, it uses `snmpget` on the specific sensor OID, parses the integer value, converts to °C (divides by 10), and compares against configurable lower thresholds (default WARN: 35 °C, CRIT: 20 °C — lower temp is bad). Returns OK/WARN/CRIT/UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Temperature > WARN threshold (i.e., > 35 °C by default).
- **WARN**: Temperature ≤ WARN (≤ 35 °C) but > CRIT (i.e., > 20 °C).
- **CRIT**: Temperature ≤ CRIT (≤ 20 °C) — sensor too cold.
- **UNKNOWN**: SNMP query fails, sensor not found, or response malformed.

#### Metrics
- `temperature` — current sensor temperature in °C.

### cisco_meraki_org_device_status_ps

<a id="check-cisco-meraki-org-device-status-ps"></a>

*Power Supply %s*

#### Overview
This check monitors the operational status of individual power supplies in Cisco Meraki devices, ensuring redundancy and reliability in power delivery.

#### What it monitors
- Power supply status (e.g., "powering", "not_powering", etc.)
- Power supply model and serial number (used for reporting details)

#### How it works
The check reads pre-fetched JSON data from the yolo-man agent spool file `/var/lib/check_mk_agent/spool/cisco_meraki_org_device_status`. In discovery mode (`_discover` param), it enumerates power supplies by slot number and creates per-item services with default `state_not_powering=1`. In check mode, it locates the specific power supply by slot and reports OK if status is "powering"; otherwise, it uses the `state_not_powering` parameter (1=WARN, 2=CRIT, else UNKNOWN) to determine state.

#### Parameters
None.

#### States
- OK: Power supply status is "powering"
- WARN (default): Status is not "powering" and `state_not_powering=1`
- CRIT: Status is not "powering" and `state_not_powering=2`
- UNKNOWN: Power supply not found, agent error, empty/invalid data, or `state_not_powering` is neither 1 nor 2

#### Metrics
None.

### cisco_sma_cpu_utilization

<a id="check-cisco-sma-cpu-utilization"></a>

*CPU utilization*

#### Overview
Monitors Cisco Secure Mail Appliance (SMA) CPU utilization via SNMP to detect performance degradation or overload conditions.

#### What it monitors
- CPU utilization percentage on the SMA device

#### How it works
The check runs `snmpget` to query the OID `.1.3.6.1.4.1.15497.1.1.1.2` (Cisco SMA CPU utilization). In discovery mode, it reports one item with default thresholds `[70.0, 80.0]`. In check mode, it parses the integer value from the SNMP response, compares it to thresholds from `params["util"]` (default 70%/80%), and returns OK/WARN/CRIT accordingly. Returns UNKNOWN if the SNMP query fails or parsing yields no value.

#### Parameters
None.

#### States
- **OK**: CPU utilization is below the warning threshold (default <70%)
- **WARN**: Utilization is at or above warning threshold but below critical (70% ≤ value <80%)
- **CRIT**: Utilization meets or exceeds critical threshold (≥80%)
- **UNKNOWN**: SNMP query fails or response cannot be parsed

#### Metrics
- `util` — CPU utilization percentage (unit: percent)

### cisco_temp

<a id="check-cisco-temp"></a>

*Temperature %s*

#### Overview
This check monitors the temperature sensor status on Cisco network devices via SNMP, providing health insights critical for preventing hardware failures due to overheating.

#### What it monitors
- Temperature sensor states (e.g., OK, warning, critical) for named physical sensors on Cisco devices.

#### How it works
In discovery mode (`_discover`), it walks OID `.1.3.6.1.4.1.9.9.13.1.3.1.2` to enumerate sensor names. During checks, it maps the specified `item` (sensor name) to its index using the same OID, then fetches the corresponding state from OID `.1.3.6.1.4.1.9.9.13.1.3.1.6`. State codes (1–6) are mapped to yolo-man states: OK/WARN/CRIT/UNKNOWN. Fails with UNKNOWN if sensor not found or SNMP fails.

#### Parameters
None.

#### States
- OK: Sensor state code 1.
- WARN: State code 2 (warning).
- CRIT: Codes 3 (critical), 4 (shutdown), or unmapped/unexpected codes.
- UNKNOWN: State codes 5 (not present), 6 (out of range), missing sensor, or SNMP errors.

#### Metrics
None.

### cisco_ucs_cpu

<a id="check-cisco-ucs-cpu"></a>

*CPU %s*

#### Overview
Monitors the operational status of CPU units in Cisco UCS servers via SNMP, ensuring hardware health and alerting on failures or degraded states.

#### What it monitors
- CPU presence (e.g., equipped, missing, mismatched)
- CPU operability status (e.g., operable, inoperable, degraded, thermalProblem)
- Model and serial number for identification

#### How it works
Uses `snmpwalk` to query Cisco UCS MIB OIDs (`.1.3.6.1.4.1.9.9.719.1.41.9.1.*`) for CPU attributes. In discovery mode, it enumerates all CPUs (excluding `presence=11` = missing). In check mode, it verifies a specific CPU item by `rn`, maps operability and presence codes to OK/WARN/CRIT states via lookup tables, and returns aggregated status.

#### Parameters
None.

#### States
- **OK**: CPU is present (`equipped`, `removed`, etc.) and operability indicates normal operation (e.g., `1=operable`, `107=autoUpgrade`).
- **WARN**: Minor issues (e.g., `performanceProblem`, `mismatch`, `missingSlave`, `disabled`).
- **CRIT**: Critical failures (e.g., `inoperable`, `thermalProblem`, `equipmentProblem`, `discoveryFailed`).
- **UNKNOWN**: SNMP query fails or CPU item not found.

#### Metrics
None.

### cisco_ucs_fan

<a id="check-cisco-ucs-fan"></a>

*Fan %s*

#### Overview
This check monitors the operational status of Cisco UCS server fans via SNMP, ensuring cooling systems are functioning to prevent hardware overheating and failure.

#### What it monitors
- Fan operational state (e.g., operable, inoperable, degraded, powered off)
- Fan discovery via distinct identifiers (DN strings)

#### How it works
The check uses SNMP to fetch fan DN and operability OIDs. In discovery mode (`_discover: true`), it walks both OIDs to enumerate all fans, pairing each DN with its operability value. In check mode, it retrieves a specific fan’s operability via `snmpget`. Operability codes (0–14, 51–108) are mapped to yolo-man states (OK/WARN/CRIT/UNKNOWN) using `OPERABILITY_MAP`.

#### Parameters
None.

#### States
- **OK**: Fan operable (1) or removed (6), auto-upgrading (107)
- **WARN**: Powered off (4), performance/accessibility problems (9/10/11), disabled (13), upgrade/link issues, discovery, etc.
- **CRIT**: Unknown (0), inoperable (2), degraded (3), power/voltage/thermal/equipment problems (5/7/8/82), BIOS timeout (12), discovery failure (102), post failure (104), etc.
- **UNKNOWN**: No item specified, or fan DN not found in SNMP response.

#### Metrics
None.

### cisco_ucs_faults

<a id="check-cisco-ucs-faults"></a>

*Cisco UCS Faults*

#### Overview
Monitors active faults on Cisco UCS (Unified Computing System) hardware by polling the `cisco_ucs_fault` agent section. It matters because unresolved faults may indicate hardware degradation or failure, risking service outages.

#### What it monitors
- Active fault objects on the Cisco UCS system, including their code, description, severity, and acknowledgment status.
- Number of faults and their worst severity level.

#### How it works
The check executes an agent command to retrieve the `[cisco_ucs_fault]` section. It parses lines into components (DN, ack, code, description, severity), maps severity strings to monitoring states (0/1→OK, 3/4→WARN, 5/6→CRIT), and computes the worst state across all faults. Discovery yields one service with empty item.

#### Parameters
None.

#### States
- OK: No faults (or only cleared/info faults).
- WARN: One or more faults with severity 3 (minor) or 4 (major).
- CRIT: One or more faults with severity 5 (critical) or 6 (critical).
- UNKNOWN: Agent command fails or no data retrieved.

#### Metrics
None.

### cisco_ucs_mem_total

<a id="check-cisco-ucs-mem-total"></a>

*Memory total*

#### Overview
This check monitors the total physical memory installed on a Cisco UCS rack-mounted server by querying SNMP. It ensures visibility into available hardware resources for capacity planning and health assessment.

#### What it monitors
- Total available memory on the Cisco UCS rack unit (in MB), retrieved via SNMP.

#### How it works
The check uses `snmpget` to query the OID `.1.3.6.1.4.1.9.9.719.1.9.35.1.9` (cucsComputeRackUnitAvailableMemory) on localhost. In discovery mode, it reports one service with an empty item. In check mode, it parses the SNMP response to extract an integer value (in MB), returning OK if parsing succeeds, or UNKNOWN otherwise.

#### Parameters
None.

#### States
- **OK**: SNMP query succeeds and a valid integer memory value (MB) is parsed.
- **UNKNOWN**: SNMP query fails, output format is unexpected, or no numeric value is found.
- **WARN/CRIT**: Not used by this check.

#### Metrics
None.

### cisco_ucs_psu

<a id="check-cisco-ucs-psu"></a>

*psu %s*

#### Overview
Monitors the operational status of Cisco UCS Power Supply Units (PSUs) via SNMP, ensuring power redundancy and detecting hardware failures that could lead to system downtime.

#### What it monitors
- PSU operability status (e.g., operable, inoperable, degraded, powered off)
- PSU model and serial number
- Active hardware faults associated with each PSU (including severity, code, and description)

#### How it works
Performs SNMP walks against Cisco UCS MIB OIDs to collect PSU inventory and fault data. During discovery (when `_discover` is true), it enumerates all PSUs by parsing DNs. For monitoring, it maps operability codes to yolo-man states and aggregates fault severity to determine worst-case state. The item name is extracted from the DN path (e.g., `"chassis-1 blade-1 psu-2"`).

#### Parameters
None.

#### States
- **OK**: PSU is operable with no critical/warning faults.
- **WARN**: PSU is degraded, powered off, in accessibility/performance issue, or has warning-level faults.
- **CRIT**: PSU is inoperable, has power/voltage/thermal problems, or has major/critical faults.
- **UNKNOWN**: PSU not found or operability code unrecognised.

#### Metrics
None.

### cisco_ucs_raid

<a id="check-cisco-ucs-raid"></a>

*RAID Controller*

#### Overview
Monitors the operational status of RAID controllers on Cisco UCS systems to detect hardware failures or degradation that could risk data availability.

#### What it monitors
- RAID controller model, vendor, and serial number
- Controller operability status (e.g., operable, inoperable, degraded, poweredOff)

#### How it works
The check executes `cisco_ucs_raid_info` to retrieve controller data in `model|operability|serial|vendor` format. It parses operability status against a predefined mapping (`MAP_OPERABILITY`) to determine state: operability codes `1`/`6` map to OK, `3`/`4`/`9`/`10`/`11`/`13`/`14`/`51`/`52`/`81`/`100`/`101`/`103`/`106`/`107`/`108` map to WARN, and all others (including `0`, `2`, `5`, `7`, `8`, `12`, `82`, `83`, `84`, `102`, `104`, `105`) map to CRIT. Discovery mode returns a single item with empty `item` identifier.

#### Parameters
None.

#### States
- **OK**: Controller operability is `operable` (1) or `removed` (6).
- **WARN**: Operability indicates non-critical issues (e.g., `degraded` (3), `poweredOff` (4), `performanceProblem` (9)).
- **CRIT**: Operability indicates failure, inoperability, or severe issues (e.g., `inoperable` (2), `powerProblem` (5), `thermalProblem` (8)).
- **UNKNOWN**: Data parsing fails or command returns non-zero exit code.

#### Metrics
None.

### cisco_ucs_system

<a id="check-cisco-ucs-system"></a>

*System health*

#### Overview
Monitors the operational health of a Cisco UCS rack-mounted server by querying SNMP to determine its current operability status. Critical for proactive infrastructure management, ensuring hardware-level issues like thermal, power, or connectivity problems are detected early.

#### What it monitors
- System model and serial number
- Operability status (e.g., operable, inoperable, degraded, thermal problem)
- Derived health state (OK, WARN, CRIT)

#### How it works
In discovery mode, it yields one unnamed service for the system. In check mode, it runs `snmpget` to fetch three OIDs: model (`.1.3.6.1.4.1.9.9.719.1.9.35.1.32.0`), serial (`.1.3.6.1.4.1.9.9.719.1.9.35.1.47.0`), and operability status (`.1.3.6.1.4.1.9.9.719.1.9.35.1.43.0`). It parses the response, maps the numeric operability status code to a human-readable string and yolo-man state (OK/WARN/CRIT) via `MAP_OPERABILITY`.

#### Parameters
None.

#### States
- **OK**: Operability is "operable" (code `1`) or "removed" (`6`)
- **WARN**: Codes such as `9` (performanceProblem), `13` (disabled), `51` (fabricConnProblem), etc.
- **CRIT**: Codes like `2` (inoperable), `3` (degraded), `8` (thermalProblem), `82` (equipmentProblem), etc.
- **UNKNOWN**: SNMP failure, unexpected output, or unmapped status code

#### Metrics
None.

### cisco_ucs_temp_cpu

<a id="check-cisco-ucs-temp-cpu"></a>

*Temperature CPU %s*

#### Overview
This check monitors the temperature of individual CPUs on Cisco UCS systems via SNMP, alerting when temperatures exceed threshold limits to prevent thermal damage or performance degradation.

#### What it monitors
- Temperature (in degrees Celsius) of each CPU sensor discovered on the host.

#### How it works
In discovery mode, it runs `snmpwalk` on Cisco UCS-specific OIDs (`.1.3.6.1.4.1.9.9.719.1.41.2.1.2` for CPU names, `.1.3.6.1.4.1.9.9.719.1.41.2.1.10` for temperatures) and builds per-CPU services. In check mode, it runs `snmpget` on the specific CPU’s temperature OID, parses the result, and compares it against configurable thresholds (default: WARN ≥75 °C, CRIT ≥85 °C).

#### Parameters
None.

#### States
- **OK**: Temperature is below the warning threshold.
- **WARN**: Temperature is at or above the warning threshold, but below critical.
- **CRIT**: Temperature is at or above the critical threshold.
- **UNKNOWN**: Sensor data cannot be retrieved or parsed.

#### Metrics
- `temp` — CPU temperature in °C.

### cisco_ucs_temp_env

<a id="check-cisco-ucs-temp-env"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on Cisco UCS chassis via SNMP, ensuring environmental conditions stay within safe operating limits.

#### What it monitors
- Ambient temperature (°C)
- Front temperature (°C)
- IO-Hub temperature (°C)
- Rear temperature (°C)

#### How it works
Discovers sensors via SNMP walk on OID `.1.3.6.1.4.1.9.9.719.1.9.44.1` when `_discover` is set, mapping OID suffixes to named sensors. For individual checks, it polls the same OID, extracts the integer temperature for the specified sensor item, compares against configurable warning/critical thresholds (default: 30/35 °C), and returns OK/WARN/CRIT accordingly.

#### Parameters
`levels` (tuple of floats, (30.0, 35.0)) — warning and critical temperature thresholds in °C.

#### States
- **OK**: Temperature below warning threshold.
- **WARN**: Temperature at or above warning, but below critical threshold.
- **CRIT**: Temperature at or above critical threshold.
- **UNKNOWN**: Sensor item not found.

#### Metrics
`temp` — measured temperature in °C.

### cisco_ucs_temp_mem

<a id="check-cisco-ucs-temp-mem"></a>

*Temperature Mem %s*

#### Overview
Monitors memory temperature sensors on Cisco UCS devices via SNMP to detect overheating risks that could lead to hardware failure.

#### What it monitors
- Temperature readings from memory modules (in degrees Celsius), discovered via SNMP OID `.1.3.6.1.4.1.9.9.719.1.30.12.1.2.`

#### How it works
Uses `snmpwalk` in discovery mode to enumerate memory temperature sensor indices, then `snmpget` in check mode to retrieve the current temperature (as an INTEGER) for a specific sensor. Compares the value against configurable warning/critical thresholds (default: 75 °C / 85 °C). Returns UNKNOWN if the value cannot be parsed.

#### Parameters
None.

#### States
- OK: Temperature < warning threshold (default < 75 °C)
- WARN: Temperature ≥ warning and < critical threshold (75–84 °C)
- CRIT: Temperature ≥ critical threshold (≥ 85 °C)
- UNKNOWN: Temperature value not found or unparseable

#### Metrics
- `temp` — memory temperature in °C

### cmciii_io

<a id="check-cmciii-io"></a>

*%s*

#### Overview
This check monitors the status of digital input/output (IO) sensors reported by the CMC III monitoring system via its JSON agent interface. It ensures critical IO states (e.g., door contacts, relay positions) are within expected conditions.

#### What it monitors
- Digital IO sensor status (e.g., On/Off, Open/Closed, etc.)
- Associated sensor metadata: Logic, Delay, and Relay configuration values

#### How it works
The check runs `cmciii --json` to fetch sensor data, then discovers IO sensors as individual services (per-item discovery using sensor ID unless `use_sensor_description` is enabled). In check mode, it retrieves the specific IO sensor by item or `_item_key`, maps its `Status` field to a state (OK, WARN), and returns summary details. Failure to fetch or find the sensor yields UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Status is "OK", "Off", or "Closed"
- **WARN**: Status is "On" or "Open", or sensor not found, or agent fails
- **UNKNOWN**: IO section missing, agent command fails

#### Metrics
- `status_code` — numeric encoding of status (0 for OK/Off/Closed, 1 for On/Open); unitless

### cmciii_lcp_fans

<a id="check-cmciii-lcp-fans"></a>

*LCP Fanunit FAN %s*

#### Overview
Monitors the speed and operational status of fans in a CMC III LCP (Local Control Panel) unit via SNMP, ensuring cooling systems are functioning within safe thresholds to prevent overheating.

#### What it monitors
- Fan rotational speed (RPM) for each discovered fan unit.
- Fan operational status (e.g., “OK”, “off”).
- Configurable low RPM warning/critical threshold.

#### How it works
Performs SNMP walk on `.1.3.6.1.4.1.2606.7.4.2.2.1.10.2` (24 OIDs: 34–57). In discovery mode, parses entries in groups of three (name, RPM, status) and includes only fans with status ≠ "off" and name containing "FAN". In check mode, retrieves data for a specific fan (by 1-indexed item), extracts RPM value, compares against low RPM threshold (from first OID), and returns OK if RPM ≥ threshold and status = "OK", WARN if below threshold but status = "OK", CRIT otherwise. UNKNOWN on SNMP failure or missing fan.

#### Parameters
None.

#### States
- **OK**: Fan status = "OK" and RPM ≥ configured low threshold.
- **WARN**: Fan status = "OK" but RPM < low threshold.
- **CRIT**: Fan status ≠ "OK" (e.g., failed, off).
- **UNKNOWN**: SNMP command fails, no fan data, or requested fan not found.

#### Metrics
- `rpm` — Current fan speed in revolutions per minute (integer).

### cmciii_lcp_waterflow

<a id="check-cmciii-lcp-waterflow"></a>

*LCP Fanunit WATER FLOW*

#### Overview
This check monitors water flow in the LCP (Liquid Cooling Panel) fan unit of a server cabinet cooling system, ensuring adequate coolant circulation for proper thermal management.

#### What it monitors
- Water flow rate (current, minimum, and maximum thresholds)
- Operational status of the LCP fanunit
- Name/identifier of the sensor unit

#### How it works
The check reads JSON-formatted data from `/var/lib/yolo-man/cmciii_lcp_waterflow`. In discovery mode, it yields one service with item `""`. In check mode, it extracts `flow`, `minflow`, `maxflow`, and `status` fields. If `status` is not `"OK"`, state is CRIT; if flow is outside the min–max range, state is WARN; otherwise OK. Data missing or incomplete results in UNKNOWN.

#### Parameters
None.

#### States
- **OK**: status is `"OK"` and flow is within `[minflow, maxflow]`
- **WARN**: status is `"OK"` but flow is outside the specified range
- **CRIT**: status is not `"OK"`
- **UNKNOWN**: data file missing, empty, or required fields (`flow`, `minflow`, `maxflow`, `name`) absent/invalid

#### Metrics
- `flow` — current water flow rate, unit: typically L/min or similar (as reported by agent, scaled by factor 1/10 in display)

### cmciii_temp

<a id="check-cmciii-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature readings from sensors on devices managed by the CMC-III monitoring system, using the `cmcli` command-line tool. It ensures hardware stays within safe thermal limits to prevent overheating or equipment failure.

#### What it monitors
- Temperature values (in °C) from individual sensors on the CMC-III host.
- Sensor descriptions and device-specific warning/critical thresholds when available.

#### How it works
In discovery mode, it runs `cmcli list temp` to enumerate sensors, then creates per-item services. In check mode, it executes `cmcli get temp <sensor_key>` to fetch a single sensor’s value. It parses the response for temperature and optional thresholds (e.g., `25/35` in the output), prioritizing device-provided limits over user-defined `levels_upper`/`levels_lower`. Alerts trigger when temperature meets or exceeds upper warning/critical bounds.

#### Parameters
None.

#### States
- **OK**: Temperature is below warning threshold.
- **WARN**: Temperature ≥ upper warning threshold but < upper critical threshold (or critical not defined).
- **CRIT**: Temperature ≥ upper critical threshold.
- **UNKNOWN**: Sensor not found or output is malformed/unparseable.

#### Metrics
- `temp` — Current temperature reading in degrees Celsius.

### cmciii_temp_in_out

<a id="check-cmciii-temp-in-out"></a>

*Temperature %s*

#### Overview
Monitors ambient or component temperature readings from CMC III environmental sensors via the yolo-man agent. This helps detect overheating conditions that could damage hardware or disrupt operations.

#### What it monitors
- Temperature values (°C) from individual temperature sensors identified under the `temp_in_out` section of the CMC III agent data.

#### How it works
Discovers available temperature sensors by running `cmk-agent-ctl sections cmciii`, parsing the `cmciii.temp_in_out` JSON map, and creates one service per sensor ID. In check mode, it retrieves the same agent section, looks up the sensor by its item key, and compares its numeric `Value` against user-defined warning (`warn`) and critical (`crit`) thresholds (upper bounds only). Returns OK/WARN/CRIT based on thresholds or UNKNOWN if data is missing/invalid.

#### Parameters
- `warn` (float, 25.0) — warning threshold in °C
- `crit` (float, 30.0) — critical threshold in °C

#### States
- **OK**: Temperature is below warning threshold.
- **WARN**: Temperature is ≥ warning threshold but < critical threshold.
- **CRIT**: Temperature is ≥ critical threshold.
- **UNKNOWN**: Agent command fails, no CMC III or `temp_in_out` section, sensor not found, or value is non-numeric.

#### Metrics
- `value` — current temperature reading, in °C

### cmctc_lcp_blower

<a id="check-cmctc-lcp-blower"></a>

*Blower %s*

#### Overview
Monitors the operational status and rotational speed (RPM) of individual blowers in a Liebert/Cmctc LCP environmental monitoring system, ensuring critical cooling equipment is functioning within safe parameters.

#### What it monitors
- Blower status (e.g., OK, OFF, ERROR, WARNING)
- Blower rotational speed in RPM
- Device-specific thresholds (low/high/warn levels embedded in sensor metadata)

#### How it works
Gathers data by executing the `cmctc_lcp` command to retrieve JSON-formatted sensor data. In discovery mode, it enumerates all sensors with `"type_": "blower"`. In check mode, it retrieves the specific blower by item name, maps its numeric status code to health states (OK/WARN/CRIT/UNKNOWN), and evaluates RPM against user-provided or device-stored thresholds to determine final state.

#### Parameters
None.

#### States
- **OK**: Status code 4 or 6 (ok/on), and RPM within threshold bounds.
- **WARN**: Status code 7 (warning) or RPM meets warning threshold but not critical.
- **CRIT**: Status code 2, 5, 8, 9, or 10 (lost/off/too low/too high/error), or RPM meets or exceeds critical threshold.
- **UNKNOWN**: Blower not found in data.

#### Metrics
- `blower` — blower speed in RPM.

### cmctc_lcp_current

<a id="check-cmctc-lcp-current"></a>

*Current %s*

#### Overview
This check monitors the electrical current (in amperes) of sensors reported by the CMCTC LCP (Liebert Control Platform) hardware via the yolo-man agent, using SNMP-like data parsed from the agent section.

#### What it monitors
- Current readings (in A) from sensors identified by typeid 30 in the cmctc_lcp agent section.
- Sensor status codes (e.g., ok, warning, critical).
- Device-configured warning and critical thresholds (low/high, warn/high).

#### How it works
- During discovery, it reads `/var/lib/check_mk/agent_output/cmctc_lcp`, parses lines with typeid "30", and creates per-sensor services (items like `"<description> - 3.<index>"`).
- In check mode, it locates the matching sensor by item, extracts its status, reading, and thresholds, maps the status code to state (OK/WARN/CRIT/UNKNOWN), and applies device-level thresholds to elevate state if reading exceeds warn/crit bounds.

#### Parameters
None.

#### States
- **OK**: Sensor status code maps to “ok” or “on” and reading is within thresholds.
- **WARN**: Sensor status is “warning”, or reading ≥ warn threshold (but < critical high).
- **CRIT**: Sensor status is “too low”, “too high”, “error”, or reading violates low/high thresholds.
- **UNKNOWN**: Sensor not found, agent section missing, or unrecognised status code.

#### Metrics
- `current` — measured current in amperes (A).

### cmctc_lcp_temp

<a id="check-cmctc-lcp-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on devices supporting the CMCTC LCP SNMP MIB (e.g., liebert cooling controllers), using SNMP to discover and measure ambient or component temperatures.

#### What it monitors
- Per-sensor temperature readings (°C)
- Sensor status, type, and warning thresholds (high/low/warn levels)
- Sensor descriptions and IDs (via SNMP table walks)

#### How it works
In discovery mode, the check walks SNMP OIDs `.1.3.6.1.4.1.2606.4.2.{3-6}.5.2.1` to enumerate temperature sensors (type IDs 48–59), emitting services with default temperature thresholds (25.0/30.0 °C). In check mode, it attempts to locate the sensor by `item` (e.g., `3.2`), fetches its current reading, and compares against configured warning/critical levels. If discovery or data retrieval fails, it returns UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Temperature reading is within normal range (≤ warning level).
- **WARN**: Reading exceeds warning level but not critical level.
- **CRIT**: Reading exceeds critical level.
- **UNKNOWN**: Sensor not found, SNMP walk fails, or item missing in check mode.

#### Metrics
- `temp` — Temperature reading in °C.

### cmctc_ports

<a id="check-cmctc-ports"></a>

*Port %s*

#### Overview
Monitors the status of CMC-T CMC-P port modules (IO, climate, access, etc.) via SNMP, detecting configuration errors, hardware failures, or communication issues that could affect infrastructure management.

#### What it monitors
- Port module status (OK, error, timeout, supply voltage low, etc.)
- Device type (e.g., IO, Climate, FCS, PSM)
- Serial number and description per port

#### How it works
Discovers ports on discovery by walking `.1.3.6.1.4.1.2606.4.2.3`, parsing OIDs to extract unit (3–6) and port index. For each service, it issues `snmpget` for type, description, serial, and status (OID suffixes `.1.0` to `.4.0`). Verdicts: `OK` if status="ok"; `WARN` for "configuration changed"/"unit detected"; `CRIT` for "not available"/"error"/"timeout"/"supply voltage low"; else `UNKNOWN`.

#### Parameters
None.

#### States
- **OK**: Port status is "ok".
- **WARN**: Status is "configuration changed" or "unit detected".
- **CRIT**: Status is "not available", "error", "quit from sensor unit", "timeout", or "supply voltage low".
- **UNKNOWN**: Invalid item format, SNMP failure, unexpected result count, or unmapped status/type.

#### Metrics
None.

### cmctc_psm_m

<a id="check-cmctc-psm-m"></a>

*CMC %s*

#### Overview
This check monitors power and electrical parameters of CMC-T devices (e.g., current, voltage, power) via SNMP, supporting both discovery and per-item status/state reporting.

#### What it monitors
- Sensor status (OK/CRIT)
- Scaled sensor readings (e.g., kW, Hz, V, A)
- Sensor type and description via SNMP OIDs `.1.3.6.1.4.1.2606.4.2.{3,4,5,6}.5.2.1`

#### How it works
On discovery (`_discover` flag), it walks the four relevant subtrees, parses sensor rows (index, type, description, status, raw reading), scales readings by `/10.0`, and emits discovered items with their units. For a specific item, it retrieves the same data, matches by `item` key (`description subtree.idx`), sets state to CRIT unless status is 4 (OK), and returns status and reading.

#### Parameters
None.

#### States
- **OK**: Sensor `status` equals 4.
- **CRIT**: Sensor `status` is not 4.
- **UNKNOWN**: Specified sensor `item` not found.

#### Metrics
- `kW`, `hz`, `V`, or `A` — the sensor’s unit and scaled reading (e.g., `230.5` for `V`). Units are emitted as metric keys only if known; otherwise, no metric is produced.

## Storage

<a id="check-storage"></a>

| Check | Summary |
| --- | --- |
| [3par_capacity](#check-3par-capacity) | Capacity %s |
| [3par_cpgs](#check-3par-cpgs) | CPG %s |
| [3par_cpgs_usage](#check-3par-cpgs-usage) | CPG %s |
| [3par_hosts](#check-3par-hosts) | Host %s |
| [3par_ports](#check-3par-ports) | Port %s |
| [3par_remotecopy](#check-3par-remotecopy) | Remote copy |
| [3par_system](#check-3par-system) | 3PAR %s |
| [3par_volumes](#check-3par-volumes) | Volume %s |
| [aix_lvm](#check-aix-lvm) | Logical Volume %s |
| [aix_multipath](#check-aix-multipath) | Multipath %s |
| [arbor_pravail_disk_usage](#check-arbor-pravail-disk-usage) | Disk Usage %s |
| [arc_raid_status](#check-arc-raid-status) | Raid Array #%s |
| [atto_fibrebridge_fcport](#check-atto-fibrebridge-fcport) | FC Port %s |
| [bdt_tape_info](#check-bdt-tape-info) | Tape Library Info |
| [bdt_tape_status](#check-bdt-tape-status) | Tape Library Status |
| [bdtms_tape_status](#check-bdtms-tape-status) | Tape Library Status |
| [cadvisor_df](#check-cadvisor-df) | Filesystem |
| [ceph_df](#check-ceph-df) | Ceph Pool %s |
| [ceph_status](#check-ceph-status) | Ceph Status |
| [ceph_status_osds](#check-ceph-status-osds) | Ceph OSDs |
| [ceph_status_pgs](#check-ceph-status-pgs) | Ceph PGs |
| [cephdf](#check-cephdf) | Ceph Pool %s |
| [cephosd](#check-cephosd) | Ceph OSD %s |
| [cephosdbluefs_db](#check-cephosdbluefs-db) | Ceph OSD %s DB |
| [cephosdbluefs_slow](#check-cephosdbluefs-slow) | Ceph OSD %s Slow |
| [cephosdbluefs_wal](#check-cephosdbluefs-wal) | Ceph OSD %s WAL |
| [cisco_ucs_lun](#check-cisco-ucs-lun) | LUN |

### 3par_capacity

<a id="check-3par-capacity"></a>

*Capacity %s*

#### Overview
Monitors the capacity utilization and failed capacity on HPE 3PAR storage arrays to prevent unexpected storage exhaustion and detect hardware failures.

#### What it monitors
- Total, used, and free capacity (in MiB) per storage pool or system component.
- Failed capacity (MiB) representing unusable space due to disk or media failures.
- Derived metrics: used_percent and failed_percent.

#### How it works
The check fetches raw agent data via `cmk -d localhost`, parses the `3par_capacity` section, and processes per-item (discovered via `Capacity<name>` keys). During discovery, it enumerates items with non-zero total capacity. For each item, it calculates used and failed percentages against total capacity and compares them against user-configured warning/critical thresholds.

#### Parameters
None.

#### States
- **OK**: Used and failed percentages are below warning thresholds.
- **WARN**: Used or failed percentage meets or exceeds the respective warning level (but not critical).
- **CRIT**: Used or failed percentage meets or exceeds its critical level.
- **UNKNOWN**: Item not found, total capacity is zero, or agent data retrieval fails.

#### Metrics
- `used_percent` — percentage of total capacity currently in use.
- `failed_percent` — percentage of total capacity rendered unusable by hardware failures.

### 3par_cpgs

<a id="check-3par-cpgs"></a>

*CPG %s*

#### Overview
This check monitors the health and volume counts of Compound Priority Groups (CPGs) on an HPE 3PAR storage system. CPG status is critical for ensuring storage availability and performance—degraded or failed CPGs can impact data services and system reliability.

#### What it monitors
- CPG state (OK, degraded, or failed)
- Number of Virtual Volumes (VVs) assigned to each CPG (total of FP, TD, and TP VVs)

#### How it works
The check reads CPG data from a static JSON file (`/var/lib/dummy/3par_cpgs`). In discovery mode (`_discover=True`), it parses the `members` array to enumerate CPGs with at least oneVV. In check mode, it locates the specified CPG by name and evaluates its state: `1` → OK, `2` → WARN, `3` → CRIT. State validation ensures values are 1–3; otherwise UNKNOWN is returned.

#### Parameters
None.

#### States
- **OK**: CPG state value is `1` (Normal).
- **WARN**: CPG state value is `2` (Degraded).
- **CRIT**: CPG state value is `3` (Failed).
- **UNKNOWN**: CPG not found, data missing, malformed JSON, or invalid state value.

#### Metrics
None.

### 3par_cpgs_usage

<a id="check-3par-cpgs-usage"></a>

*CPG %s*

#### Overview
This check monitors the usage percentage of HPE 3PAR CPGs (Common Provisioning Groups), specifically tracking storage allocation across System Assist (SA), System Data (SD), and User (Usr) regions. High usage can signal risk of capacity exhaustion, impacting storage availability.

#### What it monitors
- Used and total MiB for each CPG’s SAUsage, SDUsage, and UsrUsage metrics.
- Computed `used_percent` for each combination.

#### How it works
During discovery (`_discover=true`), it runs `cmk` to fetch agent data, extracts CPGs with non-zero VV counts, and creates items for each CPG + usage type (SA/SD/Usr). For check mode, it parses the item (e.g., `MyCPG UsrUsage`), retrieves the corresponding usage data, computes `used_percent = (usedMiB / totalMiB) × 100`, and compares against configurable levels (default 80/90%).

#### Parameters
- `levels` (list, `(80.0, 90.0)`) — warning and critical thresholds for used_percent.

#### States
- **OK**: `used_percent < 80%`.
- **WARN**: `used_percent >= 80%` and `< 90%`.
- **CRIT**: `used_percent >= 90%`.
- **UNKNOWN**: Discovery fails, item malformed, CPG/usage type not found, or agent data retrieval fails.

#### Metrics
- `used_percent` — percentage of CPG usage (unit: `%`).
- `size` — total CPG size (unit: `MiB`).
- `used` — used CPG space (unit: `MiB`).

### 3par_hosts

<a id="check-3par-hosts"></a>

*Host %s*

#### Overview
Monitors HPE 3PAR storage system hosts (initiators) by retrieving and validating their configuration via the yolo-man agent. It ensures host information is present and reports basic connectivity/path status.

#### What it monitors
- Host name, ID, OS version, and number of Fibre Channel (FC) or iSCSI paths available.

#### How it works
During discovery, it runs `cmk -d 3par_hosts`, parses JSON output to extract host names, and creates per-host services. For an individual host, it re-runs the same command, locates the host JSON object by name, and extracts ID, OS, FC path count, and iSCSI path count. It reports OK if the host is found and details are retrieved.

#### Parameters
None.

#### States
- **OK**: Host exists and details (ID, OS, paths) are successfully extracted.
- **UNKNOWN**: Host not found, JSON parsing fails, or command execution fails.

#### Metrics
None.

### 3par_ports

<a id="check-3par-ports"></a>

*Port %s*

#### Overview
Monitors the status and configuration of Fibre Channel, iSCSI, FCoE, IP, SAS, and NVMe ports on a 3PAR storage array. Ensures ports are online, properly configured, and not in degraded or failed states—critical for maintaining storage connectivity and data availability.

#### What it monitors
- Port link state (e.g., READY, ERROR_STATE, OFFLINE)
- Port WWN (World Wide Name)
- Port operational mode (Initiator, Target, Peer, etc.)
- Failover state (e.g., ACTIVE, FAILED_OVER, FAILBACK_PENDING)

#### How it works
Discovers ports dynamically via `cmk --agent --section 3par_ports`, filtering for non-internal port types (`type != 3`) and supported protocols (1–6). For each discovered port, creates a check service named `{Protocol} Node {n} Slot {s} Port {p}`. In check mode, fetches current port data and evaluates link/failover states against configurable thresholds (default: WARN for most error states, CRIT for critical failures like ERROR_STATE or FAILED_OVER).

#### Parameters
None.

#### States
- **OK**: Port link state and failover state are in healthy conditions (e.g., READY + ACTIVE).
- **WARN**: Port link state or failover state is in a warning condition (e.g., LOSS_SYNC, FAILOVER_PENDING) based on threshold settings.
- **CRIT**: Port link state or failover state is in a critical condition (e.g., ERROR_STATE, FAILED_OVER).
- **UNKNOWN**: No item specified, agent section unavailable, or port not found.

#### Metrics
- `link_state` — numeric code of the port’s link state
- `mode` — numeric code of the port’s operational mode
- `port_wwn` — string representation of the port’s WWN (not emitted as metric, only in details; check emits only numeric state codes as metrics)
- `failover_state` — numeric code of the failover state

*Note: Only numeric state codes (`link_state`, `mode`, `failover_state`) are emitted as metrics; `port_wwn` appears in details but not as a metric.*

### 3par_remotecopy

<a id="check-3par-remotecopy"></a>

*Remote copy*

#### Overview
This check monitors the remote copy configuration and status of an HPE 3PAR storage system, which is critical for ensuring data replication and disaster recovery readiness.

#### What it monitors
- Remote copy mode (e.g., NONE, STARTED, STOPPED)
- Remote copy status (e.g., NORMAL, DISABLE, INVALID, SHUTDOWN)

#### How it works
The check retrieves JSON data via the `cmk` agent command for the `3par_remotecopy` section. In discovery mode (`_discover` parameter), it yields one service if `mode > 1`. In check mode, it determines state based on `mode` (2=OK, 3=CRIT, else UNKNOWN) and `status` (using yolo-man’s default severity mapping: 0=OK, 1=WARN, 2=CRIT).

#### Parameters
None.

#### States
- **OK**: `mode=2` (STARTED) *and* status is NORMAL, ENABLE, or UPGRADE.
- **WARN**: status is STARTUP, SHUTDOWN, NODEDUP *or* mode=1 (NONE) while status is non-critical.
- **CRIT**: `mode=3` (STOPPED) *or* status is DISABLE or INVALID *or* unknown status defaults to CRIT.
- **UNKNOWN**: Data unavailable or mode=1 with unrecognized status.

#### Metrics
None.

### 3par_system

<a id="check-3par-system"></a>

*3PAR %s*

#### Overview
Monitors HPE 3PAR storage system health by verifying cluster node availability and reporting system metadata. Critical because node unavailability can indicate failures impacting storage service continuity.

#### What it monitors
- System name, model, version, and serial number
- Total and online cluster nodes
- Node availability status (detects missing or inconsistent nodes)

#### How it works
Gathers system data via `cmk -d 3par_system` agent command. In discovery mode, yields one item per detected system. In check mode, validates the requested item matches the actual system name, then compares cluster and online node lists to compute state: OK if all nodes online, CRIT if any node mismatch (missing/inconsistent), UNKNOWN otherwise.

#### Parameters
None.

#### States
- **OK**: All cluster nodes are online and match expected membership.
- **CRIT**: One or more nodes are missing or inconsistent between cluster and online lists.
- **UNKNOWN**: Data unavailable, system name mismatch, or discovery failure.

#### Metrics
None.

### 3par_volumes

<a id="check-3par-volumes"></a>

*Volume %s*

#### Overview
This check monitors HPE 3PAR storage volume utilization, state, and capacity efficiency metrics for each non-system volume. It matters because timely detection of high usage, provisioning issues, or degraded volume states prevents storage exhaustion and ensures data availability.

#### What it monitors
- Volume used capacity percentage (`fs_used_percent`)
- Provisioning size (`fs_provisioning`)
- Volume state (OK/WARN/CRIT/UNKNOWN)
- Deduplication ratio
- Compaction ratio
- Provisioning type (e.g., TPVV, TDVV)
- Volume WWN identifier

#### How it works
Data is fetched by executing `cat /opt/yolo-man/agent/local/3par_volumes`. During discovery (`_discover=true`), it enumerates non-system volumes and returns per-volume services with default thresholds. For monitoring, it matches a specific volume by name, computes usage percentage, and applies user-defined thresholds (default: warning at 80%, critical at 90%). The higher-priority volume state (OK/WARN/CRIT) overrides the usage-based state if worse.

#### Parameters
None.

#### States
- **OK**: Volume state is OK and usage is within thresholds.
- **WARN**: Usage exceeds warning threshold or volume state is WARN.
- **CRIT**: Usage exceeds critical threshold, usage drops below low thresholds, or volume state is CRIT.
- **UNKNOWN**: No data available, or volume name not found.

#### Metrics
- `fs_used_percent` — percentage of volume capacity used (%)
- `fs_provisioning` — raw reserved space in bytes (bytes)

### aix_lvm

<a id="check-aix-lvm"></a>

*Logical Volume %s*

#### Overview
Monitors the health and activation status of AIX Logical Volumes (LVs), ensuring critical volumes are open and mirrored LVs are properly synchronized and aligned.

#### What it monitors
- Logical volume activation state (e.g., open/closed)
- Mirroring synchronization state (`syncd` vs other states)
- Physical volume (PP) distribution alignment for mirrored volumes

#### How it works
Gathers LVM data by running `lsrep`; falls back to `lsvg -l rootvg` if `lsrep` fails. In discovery mode, it enumerates all logical volumes and reports them as items. In check mode, it parses the target `vg/lv` item, validates its state, and raises warnings if not opened (unless `boot`), critical if not synchronized (`mirror != "syncd"`), and warning if mirror PP distribution is misaligned.

#### Parameters
None.

#### States
- **OK**: LV is open (unless `boot` type), and `mirror == "syncd"` with aligned PPs.
- **WARN**: LV not open (non-boot) or PP misalignment; but `mirror == "syncd"`.
- **CRIT**: Mirror state not `syncd` (e.g., stale PPs).
- **UNKNOWN**: Invalid item format or volume not found.

#### Metrics
None.

### aix_multipath

<a id="check-aix-multipath"></a>

*Multipath %s*

#### Overview
Monitors AIX multipath storage devices to ensure required paths to disks are available and enabled, preventing potential I/O failures due to path degradation.

#### What it monitors
- Availability status of disk devices (via `lsdev -Cc disk`)
- Number of paths per multipath disk
- Whether each path is Enabled or not

#### How it works
Discovers multipath devices during discovery mode by listing available `hdisk*` devices and counting their paths. In check mode, it inspects the specified disk, counts total and non-enabled paths, compares against expected paths (if configured), and reports OK/WARN/CRIT based on non-enabled path percentage (≥50% → CRIT, otherwise → WARN) and path count mismatch.

#### Parameters
None.

#### States
- **OK**: All paths are enabled and match expected path count.
- **WARN**: Some paths are not enabled (<50%) or path count differs from expected.
- **CRIT**: ≥50% of paths are not enabled.
- **UNKNOWN**: Specified multipath device not found.

#### Metrics
None.

### arbor_pravail_disk_usage

<a id="check-arbor-pravail-disk-usage"></a>

*Disk Usage %s*

#### Overview
Monitors disk usage on Arbor Peakflow SP/TMS/Praavail devices via SNMP to alert when disk utilization exceeds thresholds, helping prevent performance issues or outages.

#### What it monitors
- Disk usage percentage on the monitored device

#### How it works
On discovery, it creates a single service item for `/` with default thresholds (80% warn, 90% crit). In check mode, it queries three device-specific SNMP OIDs sequentially until one succeeds, retrieves the disk usage value, and compares it against thresholds. The first successful OID response is used regardless of device type.

#### Parameters
None.

#### States
- **OK**: Disk usage is below warning threshold.
- **WARN**: Disk usage is at or above warning threshold but below critical threshold.
- **CRIT**: Disk usage is at or above critical threshold.
- **UNKNOWN**: SNMP query fails for all OIDs.

#### Metrics
- `disk_utilization` — disk usage as a fraction (e.g., 0.45 for 45%), unitless.

### arc_raid_status

<a id="check-arc-raid-status"></a>

*Raid Array #%s*

#### Overview
Monitors the status of Areca RAID arrays on Linux systems by reading `/proc/driver/areca/raid_status`. It detects configuration issues or degradation (e.g., rebuilding, degraded arrays) to alert before data loss or failure.

#### What it monitors
- RAID array state (e.g., Normal, Checking, Rebuilding, Degrade, Incompleted)
- Number of disks per array (tracked for changes)

#### How it works
Executes `cat /proc/driver/areca/raid_status` and parses its output. In discovery mode, it extracts array IDs, disk counts, and prepares items. For checks, it matches the specified `item`, evaluates the last field (`raid_state`) to set state (OK/WARN/CRIT), and flags disk count changes.

#### Parameters
None.

#### States
- **OK**: Array state is `Normal` or `Checking`.
- **WARN**: Array state is `Rebuilding`.
- **CRIT**: Array state is `Degrade`, `Incompleted`, or any unrecognized state.
- **UNKNOWN**: Specified array `item` not found in output.

#### Metrics
None.

### atto_fibrebridge_fcport

<a id="check-atto-fibrebridge-fcport"></a>

*FC Port %s*

#### Overview
Monitors Fibre Channel (FC) port traffic on Atto FibreBridge devices by reporting transmit (TX) and receive (RX) word rates. Critical for detecting performance degradation or link failures in SAN environments.

#### What it monitors
- FC port name and status
- Transmit word rate (words/second)
- Receive word rate (words/second)

#### How it works
The check reads the `<<<atto_fibrebridge_fcport>>>` section from the yolo-man agent output at `/var/lib/yolo-man-agent/agent_output`. In discovery mode, it enumerates all valid ports (those with numeric TX/RX fields). In check mode, it retrieves values for a specific port item, compares against optional thresholds (`fc_tx_words`, `fc_rx_words`), and returns OK/WARN/CRIT/UNKNOWN based on violation of thresholds or missing data.

#### Parameters
- `fc_tx_words` (list or None) — optional (warn, crit) thresholds for transmit word rate; defaults to None (no thresholds).
- `fc_rx_words` (list or None) — optional (warn, crit) thresholds for receive word rate; defaults to None (no thresholds).

#### States
- **OK**: Both TX and RX rates are below their respective warning thresholds (or no thresholds set).
- **WARN**: Either TX or RX rate meets or exceeds its warning threshold but not the critical threshold.
- **CRIT**: Either TX or RX rate meets or exceeds its critical threshold.
- **UNKNOWN**: Port not found in agent output.

#### Metrics
- `fc_tx_words` — transmit word rate in words per second
- `fc_rx_words` — receive word rate in words per second

### bdt_tape_info

<a id="check-bdt-tape-info"></a>

*Tape Library Info*

#### Overview
Monitors the status and details of a tape library device by reading agent-collected information, ensuring the tape library is recognized and reporting its basic identification data.

#### What it monitors
- Tape library name
- Description (model or description field)
- Vendor (manufacturer)
- Firmware/software version

#### How it works
The check reads a pre-collected JSON file (`/var/lib/check_mk/agent_output/bdt_tape_info.json`) containing the output of the `bdt_tape_info` agent section. On discovery (`_discover` parameter), it reports one discovered service (empty item). Otherwise, it parses the first row of the JSON array and constructs a summary string from up to four fields. Returns UNKNOWN if the file is missing, malformed, or too short; otherwise OK with a summary string.

#### Parameters
None.

#### States
- **OK**: Valid data present and successfully parsed.
- **UNKNOWN**: Agent section file missing, empty, or malformed (insufficient fields).
- **WARN/CRIT**: Never returned by this check.

#### Metrics
None.

### bdt_tape_status

<a id="check-bdt-tape-status"></a>

*Tape Library Status*

#### Overview
Monitors the operational status of a tape library (e.g., backup or archiving system) via SNMP OID `.1.3.6.1.4.1.20884.10893.2.101.2.1`. Critical for ensuring backup infrastructure reliability.

#### What it monitors
- Tape library status (e.g., online, offline, error, unknown)
- Discovery yields a single service per host if the device’s SNMP OID matches.

#### How it works
In discovery mode, checks for the presence of the SNMP OID subtree to confirm compatibility and yields one service. In check mode, expects the agent to provide the current status value (single integer) via its standard section (not directly executable in Starlark; relies on yolo-man’s agent infrastructure). Status thresholds define the verdict (implementation details not fully specified due to agent integration constraints in Starlark, but normally OK/WARN/CRIT based on defined thresholds).

#### Parameters
None.

#### States
- OK: Tape library is functioning normally (status code indicates healthy).
- WARN: Tape library is in a degraded state (e.g., offline but recoverable).
- CRIT: Tape library is in a critical/faulted state.
- UNKNOWN: Device not responding, status indeterminate, or agent section absent.

#### Metrics
None.

### bdtms_tape_status

<a id="check-bdtms-tape-status"></a>

*Tape Library Status*

#### Overview
Monitors the health status of a BDTMS tape library via SNMP, providing early warning of device failures that could disrupt backup operations.

#### What it monitors
- Tape library health status (unknown, ok, warning, critical)
- SNMP enterprise OID `.1.3.6.1.4.1.20884.2.3` (health_id)

#### How it works
Queries the tape library’s health status using `snmpget` to fetch the `health_id` OID. Parses the returned INTEGER value (1–4) into status strings, then maps them to yolo-man states (UNKNOWN, OK, WARN, CRIT). Supports single-service mode (item `""`) and discovery (returns one service).

#### Parameters
None.

#### States
- **OK**: health_id = 2 (ok)
- **WARN**: health_id = 3 (warning)
- **CRIT**: health_id = 4 (critical)
- **UNKNOWN**: SNMP query fails, health_id missing, or health_id not in {1,2,3,4}

#### Metrics
None.

### cadvisor_df

<a id="check-cadvisor-df"></a>

*Filesystem*

#### Overview
This check monitors filesystem usage and inode utilization on containerized workloads by reading metrics from cAdvisor, providing visibility into disk space exhaustion and inode depletion risks.

#### What it monitors
- Total and used filesystem space (in bytes, converted to MB)
- Used and free percentages
- Total, free, and used inodes
- Inode utilization percentage

#### How it works
Reads JSON data from `/var/lib/check_mk_agent/spool/cadvisor_df`. In discovery mode, it emits one service item per filesystem entry. In check mode, it extracts `df_size`, `df_used`, `inodes_total`, and `inodes_free` values, computes usage percentages, and compares against warn/crit thresholds for both high usage (default 80%/90%) and low free space (optional low-water thresholds). Returns state based on these comparisons.

#### Parameters
None.

#### States
- **OK**: Used % < warn and > crit thresholds, and free % > warn_low and > crit_low thresholds (if set).
- **WARN**: Used % ≥ warn or ≤ warn_low (free % low), and not yet ≥ crit.
- **CRIT**: Used % ≥ crit or ≤ crit_low (free % critically low).
- **UNKNOWN**: Missing or invalid cAdvisor spool file, or unparsable JSON.

#### Metrics
- `size` — total filesystem size in MB
- `used` — used space in KB
- `free` — free space in MB
- `used_percent` — percentage of used space
- `free_percent` — percentage of free space
- `inodes_total` — total inodes
- `inodes_free` — free inodes
- `inodes_used` — used inodes
- `inodes_used_percent` — inodes usage percentage

### ceph_df

<a id="check-ceph-df"></a>

*Ceph Pool %s*

#### Overview
Monitors Ceph storage pool utilization by checking the percentage of used space, alerting if usage exceeds critical thresholds or drops too low (indicating potential underutilization or misconfiguration).

#### What it monitors
- Ceph pool name
- Pool total size (MiB)
- Pool used space (MiB)
- Pool available space (MiB)
- Pool usage percentage (%)

#### How it works
Fetches pool statistics via `ceph df --format json`, parses the JSON output, and locates the specified pool by name (via the `item` parameter). Calculates usage percentage and compares it against fixed thresholds: 80% WARN / 90% CRIT (upper), 20% WARN / 10% CRIT (lower). Discovery is disabled.

#### Parameters
None.

#### States
- **OK**: Usage between 10% and 80%
- **WARN**: Usage ≤20% or ≥80%
- **CRIT**: Usage ≤10% or ≥90%
- **UNKNOWN**: `ceph df` fails or pool name not found

#### Metrics
- `size` — total pool size in MiB
- `used` — used space in MiB
- `avail` — available space in MiB
- `used_percent` — usage percentage (%)

### ceph_status

<a id="check-ceph-status"></a>

*Ceph Status*

#### Overview
Monitors the overall health status of a Ceph cluster by executing `ceph status --format json` and translating the `health.status` field into monitoring states (OK/WARN/CRIT/UNKNOWN).

#### What it monitors
- Ceph cluster health status (`health.status`)
- Ceph election epoch (as a metric)
- Error messages from `health.checks` when the status is not OK

#### How it works
Executes `ceph status --format json`, parses the JSON response, and maps `health.status` (e.g., `HEALTH_OK`, `HEALTH_WARN`) to yolo-man states. If the status is not OK, it extracts and includes relevant error messages from `health.checks`. Discovery mode is disabled (no service enumeration).

#### Parameters
None.

#### States
- **OK**: `health.status == "HEALTH_OK"`
- **WARN**: `health.status == "HEALTH_WARN"`
- **CRIT**: `health.status` is `"HEALTH_CRIT"` or `"HEALTH_ERR"`
- **UNKNOWN**: command fails, status field missing, or unrecognized status

#### Metrics
- `election_epoch` — Ceph election epoch (integer, unitless)

### ceph_status_osds

<a id="check-ceph-status-osds"></a>

*Ceph OSDs*

#### Overview
Monitors the health and availability of Ceph OSDs (Object Storage Daemons) by analyzing the output of `ceph status --format json`. Critical for ensuring data durability and cluster availability in Ceph storage systems.

#### What it monitors
- Total number of OSDs (`num_osds`)
- Number and percentage of OSDs that are out (`num_out_osds`)
- Number and percentage of OSDs that are down (`num_down_osds`)
- Number of remapped PGs (`num_remapped_pgs`)
- Full/nearfull OSD map flags

#### How it works
Executes `ceph status --format json` to fetch the cluster status, parses the `osdmap` section, and evaluates OSD health thresholds. Uses configurable thresholds for OSDs out/down percentages (default: WARN at 5%, CRIT at 7%). Reports aggregated state based on full/nearfull flags and out/down percentages. Discovery is disabled.

#### Parameters
None.

#### States
- **OK**: No OSDs out/down beyond thresholds, no full/nearfull flags set.
- **WARN**: OSDs out/down exceed 5% threshold, or nearfull flag set (and not yet CRIT).
- **CRIT**: OSDs out/down exceed 7% threshold, or full flag set.
- **UNKNOWN**: Cannot retrieve or parse `ceph status`, or no OSDs reported.

#### Metrics
- `osds_total` — total number of OSDs, unit: count
- `remapped_pgs` — number of remapped placement groups, unit: count
- `osds_out_percent` — percentage of OSDs that are out, unit: percent
- `osds_down_percent` — percentage of OSDs that are down, unit: percent

### ceph_status_pgs

<a id="check-ceph-status-pgs"></a>

*Ceph PGs*

#### Overview
This check monitors the health and status of Placement Groups (PGs) in a Ceph storage cluster by evaluating the current state distribution of PGs, which is critical for assessing cluster stability and data availability.

#### What it monitors
- Total number of PGs (`num_pgs`)
- Counts of PGs grouped by their current state (e.g., `active`, `degraded`, `down`, `incomplete`, `stale`, etc.)

#### How it works
Executes `ceph status -f json-pretty` to retrieve cluster status in JSON. Parses the `pgmap` section to extract `num_pgs` and `pgs_by_state`. Each PG state is mapped to a yolo-man-compatible state (OK/WARN/CRIT/UNKNOWN) using a predefined mapping. The worst state among all PG groups determines the overall check state. No discovery is performed.

#### Parameters
None.

#### States
- **OK**: All PGs are in healthy states (e.g., `active`, `clean`, `peered`) with no degraded/down/stale/incomplete/inconsistent groups.
- **WARN**: PGs exist in states like `backfill_wait`, `backfilling`, `degraded`, or `replay`.
- **CRIT**: Any PGs are `down`, `incomplete`, `inconsistent`, `peered` (when not part of a healthy cluster), or `stale`.
- **UNKNOWN**: Unknown PG states not in the mapping, or failure to fetch `ceph status`.

#### Metrics
None.

### cephdf

<a id="check-cephdf"></a>

*Ceph Pool %s*

#### Overview
Monitors Ceph storage pool and storage class usage by tracking percentage of used space, object counts, and I/O metrics to ensure optimal performance and prevent capacity exhaustion.

#### What it monitors
- Pool and class storage utilization (used, available, total size in MB)
- Object counts per pool
- Read/write IOPS (input/output operations per second)
- Read/write throughput in bytes per second

#### How it works
Runs `ceph df --format json` to fetch cluster-wide storage statistics. In discovery mode, it enumerates all pools and classes as items. In check mode, it isolates the specified pool or class, computes usage percentages and I/O metrics, and compares `used_percent` against warn/crit thresholds (default 80%/90%) to determine state.

#### Parameters
None.

#### States
- **OK**: `used_percent` below warning threshold
- **WARN**: `used_percent` meets or exceeds warning threshold but below critical
- **CRIT**: `used_percent` meets or exceeds critical threshold
- **UNKNOWN**: Specified item not found in `ceph df` output

#### Metrics
- `used_percent` — percentage of storage used (unit: percent)
- `num_objects` — number of objects in the pool (unit: count)
- `disk_read_ios` — read IOPS (unit: count/s)
- `disk_write_ios` — write IOPS (unit: count/s)
- `disk_read_throughput` — read throughput in bytes/s
- `disk_write_throughput` — write throughput in bytes/s

### cephosd

<a id="check-cephosd"></a>

*Ceph OSD %s*

#### Overview
Monitors Ceph OSD (Object Storage Daemon) health and utilization, ensuring storage capacity and performance remain within acceptable thresholds to prevent cluster degradation or data loss.

#### What it monitors
- OSD disk space utilization (used %, used MB, available MB)
- Number of placement groups (PGs) assigned to the OSD
- OSD operational status (e.g., up, down)
- Apply latency and commit latency (in seconds)

#### How it works
Discovers OSDs via `ceph osd df --format json` when `_discover` is set, returning per-OSD items with default thresholds. For a specific OSD, it queries both `ceph osd df` (for capacity/PGs/status) and `ceph osd perf` (for latency metrics), then compares `used_percent` against user-defined upper/lower warning/critical levels to determine state (OK/WARN/CRIT/UNKNOWN).

#### Parameters
None.

#### States
- **OK**: Used % within normal bounds (above lower thresholds, below upper thresholds).
- **WARN**: Used % exceeds upper warning threshold or falls below lower warning threshold (but not critical).
- **CRIT**: Used % exceeds upper critical threshold or falls below lower critical threshold.
- **UNKNOWN**: Discovery fails, OSD not found, or `ceph` commands return non-zero exit code.

#### Metrics
- `used_percent` — OSD disk usage percentage (%).
- `num_pgs` — Number of placement groups on the OSD (count).
- `apply_latency` — OSD apply latency (seconds).
- `commit_latency` — OSD commit latency (seconds).

### cephosdbluefs_db

<a id="check-cephosdbluefs-db"></a>

*Ceph OSD %s DB*

#### Overview
Monitors BlueFS database space usage for individual Ceph OSDs. This is critical because BlueFS manages metadata storage (e.g., WAL, DB) for Ceph OSDs, and exhaustion can lead to OSD failures and degraded cluster availability.

#### What it monitors
- BlueFS database (`db`) total size and used space per OSD
- Derived metrics: used percentage, available space

#### How it works
In discovery mode, it runs `ceph daemon osd perf dump`, parses BlueFS stats for each OSD, and discovers one service per OSD. In check mode, it fetches the same data, locates the requested OSD, calculates space usage (MB and %), and applies user-defined thresholds (default 80%/90%) via `df.df_check_filesystem_single`-style logic to determine OK/WARN/CRIT.

#### Parameters
`levels` (tuple, (80.0, 90.0)) — warning and critical thresholds as percentages of used space.

#### States
- OK: used % < warning threshold
- WARN: used % ≥ warning and < critical threshold
- CRIT: used % ≥ critical threshold
- UNKNOWN: OSD not found or `ceph` command fails

#### Metrics
`used_percent` — percentage of BlueFS DB space used
`used_mb` — used space in MiB
`available_mb` — remaining space in MiB
`total_mb` — total BlueFS DB capacity in MiB

### cephosdbluefs_slow

<a id="check-cephosdbluefs-slow"></a>

*Ceph OSD %s Slow*

#### Overview
Monitors the utilization of the slow device (e.g., HDD or slow SSD) used by Ceph OSDs for BlueFS metadata logging. High usage can impact performance or cause OSD failures.

#### What it monitors
- Total and used capacity (in MB) of the slow device per OSD.
- Percentage of slow device capacity used.

#### How it works
Reads `/var/lib/check_mk_agent/spool/cephosdbluefs` to obtain BlueFS statistics per OSD. In discovery mode, it creates items for OSDs with `slow_total_mb > 0`. In check mode, it computes used percentage against warn/crit thresholds (default: 80%/90%) and returns OK/WARN/CRIT/UNKNOWN based on thresholds or missing data.

#### Parameters
None.

#### States
- **OK**: Slow device usage below warn threshold.
- **WARN**: Usage at or above warn threshold (default 80%).
- **CRIT**: Usage at or above crit threshold (default 90%).
- **UNKNOWN**: Agent unavailable, no slow device for the OSD, or `slow_total_mb == 0`.

#### Metrics
- `disk_used_percent` — percentage of slow device capacity used.

### cephosdbluefs_wal

<a id="check-cephosdbluefs-wal"></a>

*Ceph OSD %s WAL*

#### Overview
Monitors the usage of the BlueFS WAL (Write-Ahead Log) device for individual Ceph OSDs, providing critical insight into storage health and performance since WAL exhaustion can cause OSD failures or performance degradation.

#### What it monitors
- Total capacity of the WAL device (in MiB/GB)
- Used capacity of the WAL device (in MiB/GB)
- Available capacity of the WAL device (in MiB/GB)
- WAL usage as a percentage of total capacity

#### How it works
Reads JSON output from `/var/lib/yolo-man-agent/agent_output/cephosdbluefs` using `cat`. In discovery mode, it enumerates all OSDs with non-zero WAL total size. In check mode, it computes the used_percent metric and compares it against configurable warning/critical thresholds (default 80%/90%) to determine state.

#### Parameters
None.

#### States
- OK: WAL usage is below the warning threshold (default <80%)
- WARN: WAL usage is at or above the warning threshold but below critical (80% ≤ usage <90%)
- CRIT: WAL usage meets or exceeds the critical threshold (≥90%)
- UNKNOWN: WAL device for the specified OSD is not found in the agent output

#### Metrics
- `used_percent` — percentage of WAL device capacity used (unit: %)

### cisco_ucs_lun

<a id="check-cisco-ucs-lun"></a>

*LUN*

#### Overview
Monitors the status, size, and operational mode of a LUN (Logical Unit Number) on a Cisco UCS system via SNMP, ensuring storage availability and identifying hardware or configuration issues.

#### What it monitors
- LUN operational status (e.g., operable, inoperable, degraded)
- LUN type/mode (e.g., mirror, stripe, simple)
- LUN size (in MB)

#### How it works
Performs SNMP v2c walks against three specific Cisco UCS LUN-related OIDs on localhost with the `public` community. Parses the output to extract `lunOperability`, `lunType`, and `lunSize`. Uses hardcoded mapping tables to translate numeric status and type codes into human-readable strings and health states. Discovery yields a single service with empty item identifier.

#### Parameters
None.

#### States
- **OK**: LUN is operable (`operability=1`) and mode is valid (`type` maps to OK/WARN/CRIT=0/1/2, but only 0 maps to OK).
- **WARN**: LUN operability is `poweredOff`, `performanceProblem`, `accessibilityProblem`, `disabled`, etc., OR LUN type is simple (`1`) or non-critical modes (`3, 9`).
- **CRIT**: LUN is inoperable (`2`), degraded (`3`), or has critical status codes (e.g., `powerProblem`, `thermalProblem`, `equipmentProblem`), OR LUN type is `unspecified` (`0`) or invalid.
- **UNKNOWN**: SNMP fails, missing data, or unrecognized status/type codes.

#### Metrics
None.

## Network

<a id="check-network"></a>

| Check | Summary |
| --- | --- |
| [arbor_peakflow_sp_flows](#check-arbor-peakflow-sp-flows) | Flow Count |
| [arbor_peakflow_tms_disk_usage](#check-arbor-peakflow-tms-disk-usage) | Disk Usage %s |
| [arbor_peakflow_tms_updates](#check-arbor-peakflow-tms-updates) | Config Update %s |
| [arbor_pravail_drop_rate](#check-arbor-pravail-drop-rate) | %s drop rate |
| [aruba_aps](#check-aruba-aps) | Access Points |
| [aruba_clients](#check-aruba-clients) | WLAN Clients |
| [avaya_88xx_cpu](#check-avaya-88xx-cpu) | CPU utilization |
| [bintec_brrp_status](#check-bintec-brrp-status) | BRRP Status %s |
| [bintec_info](#check-bintec-info) | Bintec Info |
| [bluecat_dhcp](#check-bluecat-dhcp) | DHCP |
| [bluecat_dns_queries](#check-bluecat-dns-queries) | DNS Queries |
| [bluecat_ntp](#check-bluecat-ntp) | NTP |
| [bluecat_threads](#check-bluecat-threads) | Number of threads |
| [bluenet2_powerrail_humidity](#check-bluenet2-powerrail-humidity) | Humidity %s |
| [bonding](#check-bonding) | Bonding Interface %s |
| [bvip_link](#check-bvip-link) | Network Link |
| [by_ssh](#check-by-ssh) |  |
| [checkpoint_connections](#check-checkpoint-connections) | Connections |
| [checkpoint_packets](#check-checkpoint-packets) | Packet Statistics |
| [checkpoint_vsx_connections](#check-checkpoint-vsx-connections) | VS %s Connections |
| [ciena_port_power](#check-ciena-port-power) | Port %s XCVR Power |
| [ciena_routing_instance](#check-ciena-routing-instance) | Routing instance %s |
| [cisco_cpu_multiitem](#check-cisco-cpu-multiitem) | CPU utilization %s |
| [cisco_hsrp](#check-cisco-hsrp) | HSRP Group %s |
| [cisco_mem](#check-cisco-mem) | Cisco memory checks |
| [cisco_meraki_org_appliance_vpns](#check-cisco-meraki-org-appliance-vpns) | VPN peer %s |
| [cisco_sma_files_and_sockets](#check-cisco-sma-files-and-sockets) | Files and sockets |
| [cisco_srst_call_legs](#check-cisco-srst-call-legs) | SRST Call Legs |
| [cisco_stack](#check-cisco-stack) | Switch stack status %s |
| [cisco_stackpower](#check-cisco-stackpower) | Stackpower Interface %s |
| [cisco_vss](#check-cisco-vss) | VSS Status |
| [cisco_wlc](#check-cisco-wlc) | Cisco WLC sections and checks |

### arbor_peakflow_sp_flows

<a id="check-arbor-peakflow-sp-flows"></a>

*Flow Count*

#### Overview
Monitors the current number of active flows on an Arbor PeakFlow SP device, providing visibility into traffic volume and potential anomalies.

#### What it monitors
- Current flow count (number of active network flows) on the monitored device

#### How it works
Uses SNMP to query the device via `snmpwalk` for OID `.1.3.6.1.4.1.9694.1.4.2.1.12.0`. Parses the integer result from the output. During discovery, it identifies a single service with item `""` and metric `flows`. The check always returns OK with the raw flow count since no thresholds are configured.

#### Parameters
None.

#### States
- **OK**: Flow count successfully retrieved and reported.
- **UNKNOWN**: SNMP query failed or flow count could not be parsed.

#### Metrics
- `flows` — number of active network flows, unit: count

### arbor_peakflow_tms_disk_usage

<a id="check-arbor-peakflow-tms-disk-usage"></a>

*Disk Usage %s*

#### Overview
This check monitors disk utilization on Arbor PeakFlow TMS devices via SNMP. It matters because high disk usage can degrade performance or cause service outages on these network security appliances.

#### What it monitors
- Disk utilization percentage for the root filesystem (`/`) on the device.

#### How it works
- In discovery mode, it yields one service for `/` with default warning (80%) and critical (90%) thresholds.
- In check mode, it attempts to retrieve disk usage data via SNMP OID `.1.3.6.1.4.1.9694.1.5.2.6.0`.
- Due to Starlark runtime limitations (no native SNMP support), it cannot gather real-time data and instead returns `UNKNOWN`.

#### Parameters
None.

#### States
- **OK**: Not reachable in current implementation (would require valid SNMP data).
- **WARN**: Disk usage exceeds 80% (theoretical).
- **CRIT**: Disk usage exceeds 90% (theoretical).
- **UNKNOWN**: SNMP data unavailable in this runtime environment.

#### Metrics
- `disk_utilization` — disk usage percentage (unit: `%`).

### arbor_peakflow_tms_updates

<a id="check-arbor-peakflow-tms-updates"></a>

*Config Update %s*

#### Overview
Monitors update versions of device and mitigation firmware on Arbor PeakFlow TMS (Traffic Management System) devices via SNMP. Ensures the system is running expected firmware versions for security and functionality.

#### What it monitors
- Device firmware version (OID `.1.3.6.1.4.1.9694.1.5.5.1.2.0`)
- Mitigation firmware version (OID `.1.3.6.1.4.1.9694.1.5.5.2.1.0`)

#### How it works
Uses `snmpwalk` to fetch two specific OIDs from the local SNMP agent (`127.0.0.1`, community `public`). In discovery mode, it identifies up to two service items ("Device", "Mitigation") based on available data. In check mode, it retrieves the current version string for the specified item and reports it in the check summary. The check always returns OK if the item exists.

#### Parameters
None.

#### States
- **OK**: Item (Device or Mitigation) is present; summary line contains the version string.
- **UNKNOWN**: Item not found in discovered data (e.g., SNMP returned no matching OID).
- **WARN/CRIT**: Never returned by this check.

#### Metrics
None.

### arbor_pravail_drop_rate

<a id="check-arbor-pravail-drop-rate"></a>

*%s drop rate*

#### Overview
Monitors the Arbor PRavail drop rate—specifically the number of packets dropped (overruns) per second on the network interface—as reported by the Arbor Networks device via SNMP.

#### What it monitors
- Packet drop rate (overrun count per second) on the monitored interface.

#### How it works
Discovers one service item named `"Overrun"`. For that item, it performs an SNMP GET query (OID `.1.3.6.1.4.1.9694.1.6.2.39.0`) to retrieve the current overrun count. The output is parsed to extract an integer value. State is determined using upper/lower warning/critical thresholds if provided; otherwise, it defaults to OK.

#### Parameters
- `levels` (tuple or None) — upper warning/critical thresholds (warn, crit) for drop rate.
- `levels_lower` (tuple or None) — lower warning/critical thresholds (warn, crit) for drop rate.

#### States
- **OK**: Drop rate is within thresholds (or no thresholds set).
- **WARN**: Drop rate exceeds upper threshold or falls below lower threshold.
- **CRIT**: Drop rate exceeds upper critical threshold or falls below lower critical threshold.
- **UNKNOWN**: SNMP query fails, item is unknown, or parsing fails.

#### Metrics
- `if_in_pkts` — integer value representing packet drops (overruns) per second.

### aruba_aps

<a id="check-aruba-aps"></a>

*Access Points*

#### Overview
This check monitors the number of connected Access Points (APs) to an Aruba controller via SNMP, ensuring visibility into wireless infrastructure health and capacity.

#### What it monitors
- Number of currently connected wireless Access Points (APs)

#### How it works
Performs a single SNMP GET request using `snmpget` to query OID `.1.3.6.1.4.1.14823.2.2.1.1.3.1`, which reports the count of connected APs. If discovery mode is active (`_discover`), it returns one service item with empty name and `connections` metric. Otherwise, it evaluates the raw numeric value; invalid or non-numeric responses yield UNKNOWN. No thresholds are applied—status always returns OK if the value is valid.

#### Parameters
None.

#### States
- OK: Valid SNMP response with a non-negative integer count of connected APs.
- UNKNOWN: SNMP query fails, or response is non-numeric/invalid.

#### Metrics
- `connections` — number of connected Access Points, unit: count.

### aruba_clients

<a id="check-aruba-clients"></a>

*WLAN Clients*

#### Overview
Monitors the number of wireless clients connected to an Aruba WLAN controller via SNMP. This is critical for capacity planning and detecting outages or unauthorized access.

#### What it monitors
- Number of active wireless client connections to the Aruba controller.

#### How it works
Uses SNMPv2c to query the OID `.1.3.6.1.4.1.14823.2.2.1.1.3.2` (Aruba `arubaStaTotalCount`). On discovery (`_discover` flag), it walks the OID to verify availability. In normal mode, it performs an `snmpget` and parses the numeric result. Verdicts: `OK` on valid integer client count, `UNKNOWN` on SNMP failure, malformed output, or non-numeric value.

#### Parameters
None.

#### States
- `OK`: Valid client count retrieved successfully.
- `UNKNOWN`: SNMP command failed, output format invalid, or client count not a valid integer.
- `WARN`/`CRIT`: Not used by this check.

#### Metrics
- `connections` — Number of connected wireless clients (unit: count).

### avaya_88xx_cpu

<a id="check-avaya-88xx-cpu"></a>

*CPU utilization*

#### Overview
This check monitors CPU utilization of Avaya 88xx series network devices via SNMP, providing early warning of performance degradation or resource exhaustion.

#### What it monitors
- CPU utilization percentage (single aggregate value for the device)

#### How it works
The check first verifies the host is an Avaya device by querying the SNMP OID `.1.3.6.1.2.1.1.2.0`. If confirmed, it retrieves the CPU utilization from `.1.3.6.1.4.1.2272.1.1.20` using `snmpget`. Discovery (`_discover: true`) returns a single item with default thresholds `util: (90.0, 95.0)` and metric `util`. The verdict is determined by comparing the integer utilization value against configured warning (default 90%) and critical (default 95%) thresholds.

#### Parameters
None.

#### States
- **OK**: CPU utilization below warning threshold (< 90%)
- **WARN**: Utilization at or above warning, but below critical (90% ≤ util < 95%)
- **CRIT**: Utilization at or above critical threshold (≥ 95%)
- **UNKNOWN**: SNMP query fails, device is not Avaya, or parsing fails

#### Metrics
- `util` — CPU utilization percentage (%)

### bintec_brrp_status

<a id="check-bintec-brrp-status"></a>

*BRRP Status %s*

#### Overview
Monitors the status of Bintec BRRP (Bintec Redundancy Routing Protocol) instances on network devices to ensure high-availability routing redundancy is functioning correctly.

#### What it monitors
- BRRP instance status (initialize, backup, master) for each discovered BRRP group

#### How it works
Performs an SNMP walk on OID `1.3.6.1.4.1.272.4.40.1.1.4` to retrieve BRRP status strings. During discovery, it extracts BRRP IDs from the OID path and reports each instance. For a specific item (BRRP ID), it checks the status: `1` → WARN (initialize), `2` or `3` → OK (backup/master). Returns UNKNOWN if the instance is missing or the status value is unexpected.

#### Parameters
None.

#### States
- **OK**: Status is backup (`2`) or master (`3`)
- **WARN**: Status is initialize (`1`)
- **UNKNOWN**: SNMP query fails, instance not found, or status value is unrecognized

#### Metrics
None.

### bintec_info

<a id="check-bintec-info"></a>

*Bintec Info*

#### Overview
This check monitors Bintec network devices via SNMP, retrieving and reporting device identification (software version and serial number) to confirm the device is reachable and responding correctly.

#### What it monitors
- Bintec device software version (from OID `.1.3.6.1.4.1.272.4.1.26.0`)
- Bintec device serial number (from OID `.1.3.6.1.4.1.272.4.1.31.0`)

#### How it works
Uses `snmpget` to query two specific Bintec OIDs on localhost with SNMPv2c (`-v2c -cpublic`). Parses the output to extract string values. If either value is missing after the query, returns UNKNOWN; otherwise returns OK with summary details. Discovery yields a single service with empty item.

#### Parameters
None.

#### States
- **OK**: Both software version and serial number retrieved successfully.
- **UNKNOWN**: SNMP query fails or one/both values are missing; no data retrieved.
- **WARN/CRIT**: Not applicable—check does not implement warning or critical thresholds.

#### Metrics
None.

### bluecat_dhcp

<a id="check-bluecat-dhcp"></a>

*DHCP*

#### Overview
Monitors the operational state and lease throughput of a BlueCat DHCP service via SNMP. Critical for ensuring DHCP availability in enterprise networks where BlueCat is used for DNS/DHCP management.

#### What it monitors
- DHCP service operational state (running, not running, starting, stopping, fault)
- DHCP lease success rate (leases per second)

#### How it works
Queries SNMP OIDs `.1.3.6.1.4.1.13315.3.1.1.2.1.1` (operState) and `.1.3.6.1.4.1.13315.3.1.1.2.1.3` (leaseStatsSuccess) using `snmpwalk`. Discovery yields one service if operState ≠ 2 (not running). In check mode, maps operState to OK/WARN/CRIT using configurable thresholds; default: WARN for states 2–4, CRIT for 5.

#### Parameters
None.

#### States
- **OK**: operState = 1 (running normally)
- **WARN**: operState ∈ {2, 3, 4} (not running, starting, stopping)
- **CRIT**: operState = 5 (fault)
- **UNKNOWN**: SNMP query fails or operState OID missing

#### Metrics
- `leases` — DHCP leases assigned per second (unit: 1/s)

### bluecat_dns_queries

<a id="check-bluecat-dns-queries"></a>

*DNS Queries*

#### Overview
Monitors DNS query statistics on a Bluecat DNS server via SNMP, providing visibility into query success rates, errors, and recursive lookups to help diagnose DNS performance or resolution issues.

#### What it monitors
- DNS query responses categorized by outcome: Success, Referral, NXRSet, NXDomain, Recursion, Failure
- Raw counter values for each query type, collected as SNMP Counter32 values.

#### How it works
Uses `snmpget` to poll six specific Bluecat DNS query OIDs under `.1.3.6.1.4.1.13315.3.1.2.2.2.1.{1-6}` on localhost with SNMP v2c and community `public`. Parses the output to extract integer values. In discovery mode (`_discover` true), it returns one service item with the six metric names. Otherwise, it collects current counters, builds a metrics dict, and reports OK state unconditionally (no thresholds configured).

#### Parameters
None.

#### States
OK — when counters are successfully retrieved and parsed. UNKNOWN — only if SNMP retrieval or parsing fails (via `fail()` call); otherwise, state remains OK.

#### Metrics
- `Success` — count of successful DNS queries (unit: count)
- `Referral` — count of referral responses (unit: count)
- `NXRSet` — count of negative responses with RSET (unit: count)
- `NXDomain` — count of NXDOMAIN responses (unit: count)
- `Recursion` — count of recursive query responses (unit: count)
- `Failure` — count of DNS query failures (unit: count)

### bluecat_ntp

<a id="check-bluecat-ntp"></a>

*NTP*

#### Overview
Monitors NTP (Network Time Protocol) status and synchronization health on a host via SNMP, ensuring time accuracy critical for security, logging, and coordination.

#### What it monitors
- NTP process operational state (operState)
- Leap second status (sysLeap)
- Stratum level (stratum)

#### How it works
Uses `snmpwalk` to query BlueCat-specific NTP OIDs (operState, sysLeap, stratum). During discovery, it checks for valid SNMP data and non-NULL state; if valid, it returns a single item with default thresholds. In check mode, it evaluates state: OK/WARN/CRIT/UNKNOWN based on operState, leap state, and stratum against user-defined or default thresholds. Fails with UNKNOWN on SNMP errors or missing data.

#### Parameters
None.

#### States
- OK: NTP running normally, leap=0, stratum below warning thresholds
- WARN: operState in [2,3,4], leap=1 or 10, or stratum ≥ warning level
- CRIT: operState=5, leap=11, or stratum ≥ critical level
- UNKNOWN: operState=0 (NULL), SNMP query fails, or parsing fails

#### Metrics
None.

### bluecat_threads

<a id="check-bluecat-threads"></a>

*Number of threads*

#### Overview
Monitors the number of threads in the BlueCat DNS/DHCP service via SNMP to detect potential performance degradation or resource exhaustion.

#### What it monitors
- Thread count of the BlueCat DNS/DHCP service

#### How it works
Queries the SNMP OID `.1.3.6.1.4.1.13315.100.200.1.1.2.1` using `snmpget`. Parses the integer value from the `INTEGER: value` response. Compares the thread count against optional thresholds (`levels`); if no levels are set, defaults to warning at 2000 and critical at 4000 threads. Returns OK/WARN/CRIT/UNKNOWN based on thresholds and SNMP query success.

#### Parameters
`levels` (tuple, ("levels", (2000, 4000))) — warning and critical thresholds for thread count; set to `"no_levels"` to disable thresholds.

#### States
- OK: Thread count is below warning threshold.
- WARN: Thread count meets or exceeds warning threshold but not critical.
- CRIT: Thread count meets or exceeds critical threshold.
- UNKNOWN: SNMP query fails, output is malformed, or parsing error occurs.

#### Metrics
`threads` — number of active threads in the BlueCat service; unit is threads.

### bluenet2_powerrail_humidity

<a id="check-bluenet2-powerrail-humidity"></a>

*Humidity %s*

#### Overview
This check monitors humidity levels for BlueNet2 power rail devices via SNMP, but due to runtime limitations in the Starlark agent, it currently cannot gather SNMP data and always reports UNKNOWN.

#### What it monitors
- Humidity percentage from BlueNet2 power rail sensors (via SNMP OID `1.3.6.1.4.1.31770.2.2.8.4.1.5`).

#### How it works
Discovery mode attempts to enumerate humidity sensors using SNMP but fails due to lack of SNMP support in the Starlark runtime, returning an empty list. In check mode, it tries to fetch humidity data for a specified item using SNMP `snmpget`, but fails and returns UNKNOWN with a message indicating SNMP is unsupported in the runtime.

#### Parameters
None.

#### States
- OK: Not used (SNMP data retrieval not functional).
- WARN: Not used (no thresholds applied).
- CRIT: Not used.
- UNKNOWN: Returned when item is missing, or SNMP query fails (always in current runtime).

#### Metrics
None.

### bonding

<a id="check-bonding"></a>

*Bonding Interface %s*

#### Overview
Monitors Linux network bonding (link aggregation) interfaces to ensure proper configuration, status, and failover behavior for high-availability network setups.

#### What it monitors
- Bonding interface status (up/down/degraded)
- Bonding mode (e.g., active-backup, 802.3ad)
- Active/primary slave interface
- Individual slave interface states, hardware addresses, link failures, and aggregator IDs
- Aggregator ID consistency in 802.3ad mode
- Number of configured slave interfaces

#### How it works
Reads `/proc/net/bonding/<item>` on discovery and runtime. On discovery (`_discover` mode), enumerates bonding interfaces in `/proc/net/bonding` and builds per-interface services. For each monitored item, parses bonding details, checks aggregator mismatches (802.3ad), validates mode against config (`bonding_mode_states`), compares actual vs expected active interface (`expect_active`), and verifies interface count (`expected_interfaces`). Reports OK/WARN/CRIT based on these checks.

#### Parameters
`bonding_mode_states` (dict, optional) — maps mode keys (`mode_0`, `mode_1`, etc.) to severity (0=OK, 1=WARN, 2=CRIT) when used.
`expect_active` (str, default `"ignore"`) — how to validate active interface: `"primary"`, `"lowest"`, or `"ignore"`.
`expected_interfaces` (dict, optional) — with `expected_number` (int) and optional `state` (0/1/2) for mismatch.

#### States
- **OK**: Bond status is `up`, all checks pass.
- **WARN**: Bond status `degraded`, aggregator mismatch, unexpected mode, wrong active interface, interface count mismatch, or slave failure.
- **CRIT**: Bond status not `up`/`degraded` (e.g., `unknown`), or explicit CRIT from `expected_interfaces.state`.
- **UNKNOWN**: Bond interface file not found.

#### Metrics
None.

### bvip_link

<a id="check-bvip-link"></a>

*Network Link*

#### Overview
Monitors the status of a Broadcom video IP (BVI) network link via SNMP, indicating whether the connection is active, at what speed/duplex, or if it's in an alert state.

#### What it monitors
- Link status and operational mode (e.g., 10/100/1000 Mbps, half/full duplex, Wi-Fi, or no link)
- SNMP-based link state from the device’s MIB (OID `.1.3.6.1.4.1.3967.1.5.1.8.1`)

#### How it works
On discovery (`_discover`), it runs `snmpwalk` to check for any link entries and reports a single discovered service. Otherwise, it performs an `snmpget` for the link status value, maps it to human-readable descriptions, and determines state (OK/WARN/CRIT/UNKNOWN) based on configurable state lists. Fallbacks handle SNMP failures or missing data.

#### Parameters
`ok_states` (list, `[0, 4, 5]`) — SNMP status codes considered OK (No Link, 100 Mbps Full, 1 Gbps Full).
`warn_states` (list, `[7]`) — codes triggering WARN (Wi-Fi).
`crit_states` (list, `[1, 2, 3]`) — codes triggering CRIT (10/100 Mbps, half/full duplex).
None.

#### States
OK: link status code is 0, 4, or 5.
WARN: status code is 7 (Wi-Fi).
CRIT: status code is 1, 2, or 3 (10/100 Mbps modes).
UNKNOWN: SNMP query fails, no data returned, or status code is unrecognized.

#### Metrics
None.

### by_ssh

<a id="check-by-ssh"></a>

#### Overview
The `by_ssh` check is a server-side active monitoring mechanism that triggers SSH commands to remote hosts for data collection, but it does not gather any metrics or state directly on the local host.

#### What it monitors
Nothing on the local host; it relies on remote SSH execution (handled server-side by yolo-man) to monitor remote systems.

#### How it works
When invoked with `_discover=true`, it returns no services to discover. In check mode for an item, it immediately returns `UNKNOWN` with a message indicating that no on-host data is available, because the actual SSH command execution happens server-side and remotely—not on the local host where this Starlark module runs.

#### Parameters
None.

#### States
- **OK**: Never reported—no local state can be determined.
- **WARN/CRIT**: Never reported—no local thresholds apply.
- **UNKNOWN**: Always reported (with explanation) in check mode, as no on-host data is gathered.
- **UNKNOWN**: Also reported during discovery (0 services).

#### Metrics
None.

### checkpoint_connections

<a id="check-checkpoint-connections"></a>

*Connections*

#### Overview
Monitors the number of active firewall connections on a Check Point device via SNMP, ensuring the system does not exceed predefined thresholds that could indicate performance degradation or resource exhaustion.

#### What it monitors
- Current number of active firewall connections (`fwNumConn` OID `.1.3.6.1.4.1.2620.1.1.25.3`)

#### How it works
The check runs `snmpget` to fetch the `fwNumConn` integer value from localhost using SNMPv2c with community string `public`. It parses the response to extract the connection count, then compares it against warn/crit thresholds (default: 40,000 / 50,000). Single-service discovery returns one item with empty `item` key and default thresholds.

#### Parameters
- `levels` (list, `[40000, 50000]`) — warn and crit thresholds (upper bounds for connections).

#### States
- **OK**: connections < warn threshold
- **WARN**: warn ≤ connections < crit threshold
- **CRIT**: connections ≥ crit threshold
- **UNKNOWN**: SNMP command fails or response cannot be parsed

#### Metrics
- `connections` — current number of active connections (unit: count)

### checkpoint_packets

<a id="check-checkpoint-packets"></a>

*Packet Statistics*

#### Overview
Monitors packet statistics for a Check Point firewall via SNMP, tracking accepted, rejected, dropped, logged, and ESP-encrypted/decrypted packets to detect anomalies or failures in firewall processing.

#### What it monitors
- Accepted packets
- Rejected packets
- Dropped packets
- Logged packets
- ESP-encrypted packets
- ESP-decrypted packets

#### How it works
Uses `snmpwalk` to fetch two SNMP MIB subtrees: `.1.3.6.1.4.1.2620.1.1.x` (x=4–7) for basic packet counters and `.1.3.6.1.4.1.2620.1.2.5.4.x` (x=5,6) for IPsec ESP counters. Parses `INTEGER`/`Counter32` values from output. In discovery mode, produces a single service with item `""` and listed metrics. In check mode, compares rates (approximated from counter values) against configurable thresholds (default: warn at 100k, crit at 200k packets/s) and sets state to CRIT/WARN/OK.

#### Parameters
None.

#### States
- **OK**: All packet counters below warning thresholds.
- **WARN**: Any counter ≥ warning threshold but < critical threshold.
- **CRIT**: Any counter ≥ critical threshold.
- **UNKNOWN**: No SNMP data found (section empty).

#### Metrics
- `accepted` — packets accepted by firewall (pkts/s)
- `rejected` — packets rejected (pkts/s)
- `dropped` — packets dropped (pkts/s)
- `logged` — packets logged (pkts/s)
- `espencrypted` — ESP-encrypted packets (pkts/s)
- `espdecrypted` — ESP-decrypted packets (pkts/s)

### checkpoint_vsx_connections

<a id="check-checkpoint-vsx-connections"></a>

*VS %s Connections*

#### Overview
Monitors the number of active connections per Virtual System (VS) instance on a Check Point firewall using SNMP, helping detect resource exhaustion or unusual traffic patterns.

#### What it monitors
- Active connection count (`conn_num`) for each VS instance
- Connection table size (`conn_table_size`) per VS instance (used to compute utilization percentage)

#### How it works
During discovery, it runs `snmpwalk` on three OIDs to enumerate VS instances and collect `conn_num`, `conn_table_size`, and `conn_num` again (OID suffixes). For each discovered VS, it creates an item like `VS 1`. For individual checks, it uses `snmpget` on specific OIDs to fetch current `conn_num` and `conn_table_size`. It calculates connection percentage and compares against thresholds (default 90%/95%) to decide OK/WARN/CRIT.

#### Parameters
`levels_perc` (list or dict, `("fixed", (90.0, 95.0))`) — upper thresholds for connection utilization percentage (WARN, CRIT).

#### States
- **OK**: Connection count and utilization below thresholds; or count only if table size unknown.
- **WARN**: Utilization ≥ WARN threshold (e.g., ≥90%).
- **CRIT**: Utilization ≥ CRIT threshold (e.g., ≥95%).
- **UNKNOWN**: Invalid item format, missing data, or SNMP query failure.

#### Metrics
- `connections` — number of active connections, unit: count.
- `connections_percent` — utilization of connection table, unit: percent (only if table size known and >0).

### ciena_port_power

<a id="check-ciena-port-power"></a>

*Port %s XCVR Power*

#### Overview
Monitors the input and output optical signal power of transceivers on Ciena port devices via SNMP, alerting when power levels exceed safe operational thresholds—critical for maintaining signal integrity and preventing link failures.

#### What it monitors
- Input (receive) signal power in dBm
- Output (transmit) signal power in dBm
- Per-port power thresholds (high/low limits for both rx and tx)

#### How it works
Discovers ports by polling two possible SNMP OIDs (`.1.3.6.1.4.1.6141.2.60.4.1.1.1.1` or `.1.3.6.1.4.1.1271.2.1.9.1.1.1.1`). For each port, fetches raw power values (in micro-watts) via `snmpget`. Converts micro-watt values to dBm using a custom log10 approximation, compares against dynamic limits (derived from high/low threshold OIDs), and sets state OK/WARN/CRIT. No discovery parameters required.

#### Parameters
None.

#### States
- **OK**: Both rx and tx powers within safe upper/lower bounds.
- **WARN**: Either power level exceeds warn (non-crit) thresholds.
- **CRIT**: Either power level exceeds crit thresholds (upper or lower).
- **UNKNOWN**: Port not found or SNMP queries fail.

#### Metrics
- `input_signal_power_dbm` — Receive optical power in dBm
- `output_signal_power_dbm` — Transmit optical power in dBm

### ciena_routing_instance

<a id="check-ciena-routing-instance"></a>

*Routing instance %s*

#### Overview
Monitors Ciena routing instance traffic (transmit/receive bytes per second) via SNMP to ensure expected network performance and detect anomalies.

#### What it monitors
- Routing instance names (discovered via SNMP)
- Transmitted bytes per second (`TxBytesPerSec`)
- Received bytes per second (`RxBytesPerSec`)

#### How it works
Uses `snmpwalk` to query Ciena-specific OIDs for routing instance names and traffic metrics. In discovery mode, it enumerates instances and builds item lists for per-instance checks. In check mode, it locates the specified instance and reports its traffic metrics; fails if instance is missing.

#### Parameters
None.

#### States
- **OK**: Instance found with valid TX/RX metrics; message shows human-readable throughput.
- **UNKNOWN**: Instance not found or missing TX/RX data.
- **WARN/CRIT**: Not implemented (always OK or UNKNOWN).

#### Metrics
- `if_out_octets` — transmitted bytes per second
- `if_in_octets` — received bytes per second

### cisco_cpu_multiitem

<a id="check-cisco-cpu-multiitem"></a>

*CPU utilization %s*

#### Overview
This check monitors CPU utilization on Cisco network devices via SNMP, providing both per-CPU and aggregate metrics to detect performance degradation or overload.

#### What it monitors
- Per-CPU utilization percentages (e.g., for individual line cards or core processors)
- Overall average CPU utilization across all discovered CPUs
- CPU descriptions derived from the entity MIB (e.g., "0", "1", "Fabric")

#### How it works
In discovery mode, it walks Cisco’s `CISCO-PROCESS-MIB` (.1.3.6.1.4.1.9.9.109.1.1.1.1) and `ENTITY-MIB` (.1.3.6.1.2.1.47.1.1.1.1), maps physical indices to descriptive names, filters non-CPU entities (fan/sensor), and optionally includes an "average" item. In check mode, it repeats the walks for the specified item and compares utilization against configurable thresholds (default warn=80%, crit=90%).

#### Parameters
None.

#### States
- **OK**: CPU utilization below the warning threshold.
- **WARN**: Utilization ≥ warning threshold but < critical threshold.
- **CRIT**: Utilization ≥ critical threshold.
- **UNKNOWN**: Item not found (e.g., missing/disabled CPU).

#### Metrics
- `util` — CPU utilization as a percentage (unit: %).

### cisco_hsrp

<a id="check-cisco-hsrp"></a>

*HSRP Group %s*

#### Overview
Monitors the state of Cisco HSRP (Hot Standby Router Protocol) groups to ensure redundancy is functioning as expected, which is critical for maintaining network availability during router failures.

#### What it monitors
- HSRP group state (e.g., initial, learn, listen, speak, standby, active)
- Virtual IP (VIP) addresses assigned to each group
- Whether the group is in a high-availability (standby or active) state during discovery

#### How it works
Uses SNMP (`snmpwalk`) to query the HSRP MIB `.1.3.6.1.4.1.9.9.106.1.2.1.1`. In discovery mode, it inventories only groups in state 5 (standby) or 6 (active), generating per-item services named `VIP-groupID`. In check mode, it compares the current state of a specified group against expected state; OK/WARN/CRIT/UNKNOWN is assigned based on state validity and match.

#### Parameters
None.

#### States
- **OK**: Expected state matches actual state, and both are in {3, 5, 6} (listen/standby/active).
- **WARN**: Expected state is good, but actual state differs (e.g., failover occurred from active to standby).
- **CRIT**: Actual state is not in {3, 5, 6} (non-operational).
- **UNKNOWN**: SNMP fails or the group is not found.

#### Metrics
None.

### cisco_mem

<a id="check-cisco-mem"></a>

*Cisco memory checks*

#### Overview
This check monitors memory utilization on Cisco network devices, ensuring sufficient free memory to maintain stable operation and prevent performance degradation or crashes due to resource exhaustion.

#### What it monitors
- Memory pool usage for named pools (e.g., "Processor", "IO", "System")
- Absolute used and free memory values per pool
- Calculated memory usage percentage per pool

#### How it works
In discovery mode, the check runs the `cisco_mem` command, parses JSON output, and discovers memory pools (excluding "Driver text" and pools with zero usage or free memory), assigning default warning/critical thresholds (80%/90%). In check mode, it retrieves the specific pool’s data, computes usage percentage, and compares it against configured thresholds to determine OK/WARN/CRIT/UNKNOWN states.

#### Parameters
None.

#### States
- **OK**: Memory usage < warning threshold (default < 80%).
- **WARN**: Memory usage ≥ warning and < critical threshold (80% ≤ usage < 90%).
- **CRIT**: Memory usage ≥ critical threshold (≥ 90%).
- **UNKNOWN**: Pool not found or total memory is zero.

#### Metrics
- `mem_used_percent` — memory usage percentage for the monitored pool, unit: `%`.

### cisco_meraki_org_appliance_vpns

<a id="check-cisco-meraki-org-appliance-vpns"></a>

*VPN peer %s*

#### Overview
Monitors the reachability status of Cisco Meraki and third-party VPN peers configured on an appliance organization. Ensures VPN connectivity is active, which is critical for secure remote or branch office access.

#### What it monitors
- Reachability status (reachable/unreachable/unknown) of individual VPN peers
- Peer type (Meraki or Third party)
- Network name (for Meraki peers) or public IP (for third-party peers)

#### How it works
During discovery (`_discover` mode), the check reads the agent spool file, extracts `merakiVpnPeers` and `thirdPartyVpnPeers`, and creates per-peer services using `networkName` or `name` as the item. In normal mode, it fetches the same agent data, locates the specified peer by item, and determines state: OK if `reachability` is "reachable", otherwise WARN (default) or CRIT based on `status_not_reachable` parameter.

#### Parameters
- `status_not_reachable` (int, 1) — if set to 2, marks unreachable peers as CRIT instead of WARN.

#### States
- OK: `reachability` is "reachable"
- WARN: `reachability` is not "reachable" and `status_not_reachable` is 1
- CRIT: `reachability` is not "reachable" and `status_not_reachable` is 2
- UNKNOWN: peer not found, missing agent data, or no item specified

#### Metrics
None.

### cisco_sma_files_and_sockets

<a id="check-cisco-sma-files-and-sockets"></a>

*Files and sockets*

#### Overview
Monitors the number of open files and sockets on a Cisco SMA appliance via SNMP to detect resource exhaustion risks.

#### What it monitors
- Number of open files
- Number of open sockets

#### How it works
The check is designed to run in discovery and check mode, but the Starlark runtime lacks native SNMP support. In discovery mode, it emits one item (`""`) with default thresholds. In check mode, it attempts to retrieve SNMP data but fails due to the absence of an SNMP-capable `ctx.*` builtin, returning UNKNOWN. No agent section parsing mechanism is available in the current Starlark contract, so data retrieval is impossible.

#### Parameters
None.

#### States
- **OK**: Not implemented (requires SNMP access).
- **WARN/CRIT**: Not implemented (requires SNMP access).
- **UNKNOWN**: Returned when SNMP data cannot be fetched due to runtime limitations.

#### Metrics
- `cisco_sma_files_and_sockets` — count of open files and sockets (emitted only if data were available).
None.

### cisco_srst_call_legs

<a id="check-cisco-srst-call-legs"></a>

*SRST Call Legs*

#### Overview
This check monitors the number of call legs routed through a Cisco SRST (Survivable Remote Site Telephony) device since it became active, providing insight into telephony traffic during network outages.

#### What it monitors
- Number of active call legs (calls) handled by the Cisco SRST device

#### How it works
It uses `snmpget` to query the Cisco-specific OID `.1.3.6.1.4.1.9.9.441.1.3.3.0` (INTEGER type) on localhost. If discovery is requested, it emits a single item with the service name `call_legs`. Otherwise, it parses the SNMP response, extracts the integer value, and reports it. The state is OK if the value is successfully retrieved; otherwise, UNKNOWN on SNMP errors or format mismatches. No thresholds are defined—only raw counts are reported.

#### Parameters
None.

#### States
- OK: SNMP query succeeds and value is a valid non-negative integer.
- UNKNOWN: SNMP command fails, output format is unexpected, or value is not an integer.
- WARN/CRIT: Not used.

#### Metrics
- `call_legs` — total number of call legs routed through the SRST device since activation; unit is `count`.

### cisco_stack

<a id="check-cisco-stack"></a>

*Switch stack status %s*

#### Overview
Monitors the operational status of individual switches in a Cisco stack by querying SNMP to determine their role (master, member, etc.) and state (ready, mismatch, etc.), ensuring stack integrity and detecting configuration or hardware issues.

#### What it monitors
- Switch role (master, member, standby, notMember)
- Switch state (waiting, progressing, added, ready, mismatch variants, invalid, removed)
- Per-switch status derived from Cisco StackWise SNMP MIB ( enterprises.9.9.500.1.2.1.1 )

#### How it works
In discovery mode, it performs two SNMP walks (for role and state OIDs), merges results by switch number, and returns discovered switches as per-item services. In check mode, it fetches live data for a specific switch number (via `item`), maps role/state OIDs to human-readable values, and applies state-based thresholds to determine OK/WARN/CRIT/UNKNOWN.

#### Parameters
None.

#### States
- OK: Switch state has threshold 0 (e.g., ready, added, waiting).
- WARN: Threshold 1 (mismatches like sdmMismatch, verMismatch, featureMismatch).
- CRIT: Threshold 2 (invalid, removed).
- UNKNOWN: Switch number missing, non-numeric `item`, or SNMP failure.

#### Metrics
None.

### cisco_stackpower

<a id="check-cisco-stackpower"></a>

*Stackpower Interface %s*

#### Overview
Monitors the operational and link status of Cisco StackPower interface ports via SNMP to detect disabled or down ports that could affect power distribution in stacked switches.

#### What it monitors
- Port operational status (enabled/disabled)
- Port link status (connected/operational vs. down/not connected)
- Port name and device identifier for item discovery and reporting

#### How it works
In discovery mode, it performs an SNMP walk on the Cisco StackPower MIB (`.1.3.6.1.4.1.9.9.500.1.3.2.1`) to enumerate enabled ports and creates per-port services named `<device_id> <port_name>`. In check mode, it performs an SNMP walk again, parses the relevant OIDs (`.2` for oper_status, `.5` for link_status, `.7` for port_name), matches the item, and evaluates status: CRIT if port disabled or link down, OK otherwise.

#### Parameters
None.

#### States
- **OK**: Port is enabled (oper_status=1) and link is connected/operational (link_status=1)
- **CRIT**: Port is disabled (oper_status=2) or link is down/not connected (link_status=2)
- **UNKNOWN**: Item not found in SNMP data or item format is invalid

#### Metrics
None.

### cisco_vss

<a id="check-cisco-vss"></a>

*VSS Status*

#### Overview
Monitors the status of Cisco Virtual Switching System (VSS) configurations by checking chassis roles and Virtual Switch Link (VSL) connectivity to ensure high availability.

#### What it monitors
- Chassis roles (standalone, active, standby) of VSS members
- VSL connection operational status (up/down)
- Configured vs. operational port counts per VSL

#### How it works
Uses SNMP walk to retrieve chassis and VSL data from Cisco devices via SNMPv2c with community “public”. In discovery mode, it checks if any chassis has role active (2) or standby (3) and yields one service if so. In check mode, it parses chassis and VSL OIDs to determine state: standalone chassis or down VSLs trigger CRIT; mismatched port counts also trigger CRIT.

#### Parameters
None.

#### States
- OK: All chassis are active/standby, all VSLs are up, and port counts match
- CRIT: Any chassis is standalone (1), any VSL is down, or configured ≠ operational port count
- UNKNOWN: No VSS chassis found (discovery mode only); otherwise no UNKNOWN state is explicitly set

#### Metrics
None.

### cisco_wlc

<a id="check-cisco-wlc"></a>

*Cisco WLC sections and checks*

#### Overview
This check monitors Cisco Wireless LAN Controller (WLC) access points via SNMP to verify their operational status, ensuring wireless infrastructure health and connectivity.

#### What it monitors
- Presence and existence of specific access points (APs) by name
- Operational state of each AP (e.g., online, critical, warning)

#### How it works
In discovery mode (`_discover`), it runs `snmpwalk` against `.1.3.6.1.4.1.14179.2.2.1.1.3` to enumerate all AP names. In check mode, it performs two `snmpget` calls—one for the AP name (to confirm existence) and one for its state (`.1.3.6.1.4.1.14179.2.2.1.1.6`). State codes `1`, `2`, and `3` map to OK, CRIT, and WARN respectively. AP not found yields CRIT.

#### Parameters
None.

#### States
- OK: AP exists and state is "1" (online)
- WARN: AP exists and state is "3" (warning)
- CRIT: AP does not exist, or state is "2" (critical), or SNMP query fails
- UNKNOWN: AP exists but state code is unrecognized

#### Metrics
None.

## Applications

<a id="check-applications"></a>

| Check | Summary |
| --- | --- |
| [acme_agent_sessions](#check-acme-agent-sessions) | Agent sessions %s |
| [acme_realm](#check-acme-realm) | Realm %s |
| [acme_sbc](#check-acme-sbc) | Status |
| [acme_sbc_settings](#check-acme-sbc-settings) | Settings |
| [acme_sbc_snmp](#check-acme-sbc-snmp) | ACME SBC health |
| [aironet_clients](#check-aironet-clients) | Average client signal %s |
| [aironet_errors](#check-aironet-errors) | MAC CRC errors radio %s |
| [aix_hacmp_resources](#check-aix-hacmp-resources) | HACMP RG %s |
| [aix_hacmp_services](#check-aix-hacmp-services) | HACMP Service %s |
| [alertmanager_groups](#check-alertmanager-groups) | Alertmanager Check |
| [alertmanager_rules](#check-alertmanager-rules) | Alertmanager Check |
| [alertmanager_summary](#check-alertmanager-summary) | Alertmanager Check |
| [apache_status](#check-apache-status) | Apache %s Status |
| [appdynamics_memory](#check-appdynamics-memory) | AppDynamics Memory %s |
| [appdynamics_sessions](#check-appdynamics-sessions) | AppDynamics Sessions %s |
| [appdynamics_web_container](#check-appdynamics-web-container) | AppDynamics Web Container %s |
| [arbor_memory](#check-arbor-memory) | Memory |
| [artec_documents](#check-artec-documents) | Documents |
| [audiocodes_calls](#check-audiocodes-calls) | SBC calls |
| [audiocodes_overall_operational_state](#check-audiocodes-overall-operational-state) | Operational state |
| [audiocodes_sip_calls](#check-audiocodes-sip-calls) | SIP calls |
| [bi_aggregation](#check-bi-aggregation) | Aggr %s |
| [bi_aggregation_connection](#check-bi-aggregation-connection) | BI Datasource Connection |
| [bluecat_command_server](#check-bluecat-command-server) | Command Server |
| [bluecat_dns](#check-bluecat-dns) | DNS |
| [bluecat_ha](#check-bluecat-ha) | HA State |
| [bvip_video_alerts](#check-bvip-video-alerts) | Video Alerts %s |
| [cadvisor_memory](#check-cadvisor-memory) | Memory |
| [cbl_airlaser_status](#check-cbl-airlaser-status) | CBL Airlaser Status |
| [check_plugin](#check-check-plugin) | Universal check bridge — auto-detects Nagios / Checkmk output |
| [checkpoint_tunnels](#check-checkpoint-tunnels) | Tunnel %s |
| [checkpoint_vsx](#check-checkpoint-vsx) | VS %s Info |
| [checkpoint_vsx_status](#check-checkpoint-vsx-status) | VS %s Status |
| [ciena_cfm](#check-ciena-cfm) | CFM-Service %s |
| [ciena_tunnel](#check-ciena-tunnel) | Tunnel %s |
| [cisco_cpu_memory](#check-cisco-cpu-memory) | CPU Memory utilization %s |
| [cisco_meraki_org_api_response_codes](#check-cisco-meraki-org-api-response-codes) | API %s |
| [cisco_meraki_org_appliance_performance](#check-cisco-meraki-org-appliance-performance) | Appliance performance |
| [cisco_meraki_org_licenses_overview](#check-cisco-meraki-org-licenses-overview) | Licenses %s |
| [cisco_meraki_org_wireless_device_statuses_bands](#check-cisco-meraki-org-wireless-device-statuses-bands) | Radio %s |
| [cisco_meraki_org_wireless_device_statuses_ssids](#check-cisco-meraki-org-wireless-device-statuses-ssids) | SSID %s |
| [cisco_meraki_org_wireless_ethernet_statuses](#check-cisco-meraki-org-wireless-ethernet-statuses) | Interface %s |
| [cisco_redundancy](#check-cisco-redundancy) | Redundancy Framework Status |
| [cisco_sma_dns_requests](#check-cisco-sma-dns-requests) | DNS Requests |
| [cisco_sma_mail_transfer_memory](#check-cisco-sma-mail-transfer-memory) | Mail transfer memory |
| [cisco_sma_mail_transfer_threads](#check-cisco-sma-mail-transfer-threads) | Mail transfer threads |
| [cisco_sma_message_queue](#check-cisco-sma-message-queue) | Queue |
| [cisco_srst_phones](#check-cisco-srst-phones) | SRST Phones |
| [cisco_temperature_dom](#check-cisco-temperature-dom) | DOM %s |
| [citrix_controller](#check-citrix-controller) | Citrix Controller State |
| [citrix_controller_licensing](#check-citrix-controller-licensing) | Citrix Controller Licensing |
| [citrix_controller_registered](#check-citrix-controller-registered) | Citrix Desktops Registered |
| [citrix_controller_services](#check-citrix-controller-services) | Citrix Active Site Services |
| [citrix_controller_sessions](#check-citrix-controller-sessions) | Citrix Total Sessions |
| [cmctc_lcp_position](#check-cmctc-lcp-position) | Position %s |
| [cmctc_lcp_regulator](#check-cmctc-lcp-regulator) | Regulator %s |
| [cmctc_lcp_user](#check-cmctc-lcp-user) | User Sensor %s |
| [cmctc_output](#check-cmctc-output) | %s |
| [cmctc_state](#check-cmctc-state) | TC unit state |
| [cmk_inv](#check-cmk-inv) |  |
| [cmk_site_statistics](#check-cmk-site-statistics) | Site %s statistics |

### acme_agent_sessions

<a id="check-acme-agent-sessions"></a>

*Agent sessions %s*

#### Overview
Monitors the operational state of ACME agent sessions via SNMP, ensuring sessions are properly provisioned and active for reliable agent communication.

#### What it monitors
- Agent session state (e.g., disabled, in service, out of service, timeout, constraint violation) for a specific session index.

#### How it works
Discovers agent sessions by walking SNMP OID `.1.3.6.1.4.1.9148.3.2.1.2.2.1` and extracting session indices (from `.22` sub-OIDs). For a discovered or specified item, it performs an `snmpget` to read the session state OID. It maps the numeric/quoted state string to OK/WARN/CRIT/UNKNOWN based on predefined semantics (e.g., `3` = in service → OK, `4`/`5`/`6` → WARN, `1`/`0`/`2` → OK, unknown → UNKNOWN).

#### Parameters
None.

#### States
- **OK**: session state is 0 (disabled), 2 (standby), or 3 (in service).
- **WARN**: state is 4 (constraints violation), 5 (in service timed out), or 6 (oos provisioned response).
- **CRIT**: never explicitly assigned by this check (no state maps to CRIT level >1 in `map_states`).
- **UNKNOWN**: SNMP query fails, returns No Such Object/Instance, or output is unparseable.

#### Metrics
None.

### acme_realm

<a id="check-acme-realm"></a>

*Realm %s*

#### Overview
This check monitors the status and traffic of ACME Protocol realms (used in ACME servers for TLS certificate issuance) via SNMP. It ensures realms are operational and tracks inbound/outbound request volumes to detect anomalies or degradation.

#### What it monitors
- Realm existence and operational state (e.g., in service, constraints violation, call load reduction)
- Inbound and outbound request counts per realm
- Discovery of available realms via SNMP walk

#### How it works
Performs an SNMP walk on OID `.1.3.6.1.4.1.9148.3.2.1.2.4.1` to fetch realm data. In discovery mode (`_discover=True`), it parses responses to list realms with metrics `inbound`/`outbound`. For a specific realm (`item`), it extracts the state, maps numeric states to status levels (OK/WARN/CRIT), and returns metrics. Returns `UNKNOWN` if the realm is not found.

#### Parameters
None.

#### States
- **OK**: Realm is "in service" (state=3) or other non-critical states (e.g., constraints violation, state=4)
- **CRIT**: Realm in "call load reduction" (state=7)
- **UNKNOWN**: Realm not found in SNMP data
- **UNKNOWN**: Discovery fails or malformed SNMP output

#### Metrics
- `inbound` — number of inbound requests (unit: count)
- `outbound` — number of outbound requests (unit: count)

### acme_sbc

<a id="check-acme-sbc"></a>

*Status*

#### Overview
This check monitors the health status of an Acme Session Border Controller (SBC) by querying its internal health percentage. It matters because an SBC is critical for VoIP security and session management — low health indicates potential failures in call routing or security enforcement.

#### What it monitors
- SBC health percentage (numerical value from 0–100)
- SBC operational state (e.g., "Active", "Standby", "Unknown")

#### How it works
The check runs `show health` command via SSH/CLI. On discovery mode, it auto-discovers one default service (no item). It parses the output to extract `Health` and `State` values. If `Health` = 100 → OK, otherwise → CRIT. A non-zero exit code from `show health` yields UNKNOWN.

#### Parameters
None.

#### States
- **OK**: `Health` = 100
- **CRIT**: `Health` < 100
- **UNKNOWN**: `show health` command fails (non-zero return code)

#### Metrics
None.

### acme_sbc_settings

<a id="check-acme-sbc-settings"></a>

*Settings*

#### Overview
This check verifies the configuration settings of an ACME SBC (Session Border Controller) by comparing current settings against saved/policy values, ensuring critical synchronization and redundancy parameters remain as expected.

#### What it monitors
- Synchronization status of various protocols (Media, SIP, BGF, MGCP, H248, Config, IPSEC, Iked, etc.)
- Redundancy protocol state (Active/Standby) and health percentage
- Active peer address and peer health metrics

#### How it works
The check runs a simulated agent output probe (via `echo`) and parses the `<<<acme_sbc>>>` section manually. In discovery mode, it yields one service with current settings as parameters. In check mode, it compares current settings against saved parameters; any mismatch triggers CRIT, otherwise OK.

#### Parameters
None.

#### States
- **OK**: All saved settings match current values.
- **CRIT**: Any saved setting differs from current value (or is missing).
- **UNKNOWN**: Not applicable—no failure paths to UNKNOWN in the logic.

#### Metrics
None.

### acme_sbc_snmp

<a id="check-acme-sbc-snmp"></a>

*ACME SBC health*

#### Overview
Monitors the health status of an ACME Session Border Controller (SBC) via SNMP, providing both a health score percentage and a redundancy/status state to detect degradation or failure.

#### What it monitors
- Health score (integer percentage) from `apSysHealthScore` (OID .1.3.6.1.4.1.9148.3.2.1.1.3)
- Redundancy/status string from `apSysRedundancy` (OID .1.3.6.1.4.1.9148.3.2.1.1.4), mapped to descriptive states like active, standby, out of service, etc.

#### How it works
Executes `snmpget` for two specific OIDs against localhost using SNMP v2c and the public community. Parses the response to extract the health score (as integer) and status code (as string). Maps the status code to a state severity (OK/WARN/CRIT), then adjusts the final state using the health score against configurable thresholds (default warn=75%, crit=50%). Uses discovery to create a single service item with empty name.

#### Parameters
None.

#### States
- OK: Status is active/standby/pending states (severity 0/1) AND health score ≥ warn (75%).
- WARN: Status is warning-level (pending, initial) OR health score < warn (75%) but ≥ crit (50%).
- CRIT: Status is critical (out of service, unassigned) OR health score < crit (50%).
- UNKNOWN: SNMP query fails, response incomplete, or health score missing/invalid.

#### Metrics
- `health_state` — Current health score as percentage.

### aironet_clients

<a id="check-aironet-clients"></a>

*Average client signal %s*

#### Overview
This check monitors the average wireless client signal strength and quality on a Cisco Aironet access point via SNMP, providing insight into radio frequency health and client experience.

#### What it monitors
- Average signal strength (in dB)
- Average signal quality (in %)
- Number of currently associated clients

#### How it works
In discovery mode, it uses `snmpwalk` on OID `1.3.6.1.4.1.9.9.273.1.3.1.1` to enumerate client entries (each client contributes two OIDs: signal and quality), creating three discoverable items (`strength`, `quality`, `clients`). In check mode, it parses SNMP output for the specified item, computes the average, and compares against default thresholds: signal WARN/CRIT at -25/-20 dB; quality WARN/CRIT at 40/35 %. Absence of clients returns OK.

#### Parameters
None.

#### States
- **OK**: Average signal/quality within acceptable limits or no clients present.
- **WARN**: Average signal ≤ -25 dB or average quality ≤ 40 %.
- **CRIT**: Average signal ≤ -20 dB or average quality ≤ 35 %.
- **UNKNOWN**: SNMP command failure or parse error (rare, due to manual validation).

#### Metrics
- `strength` — average signal strength in dB
- `quality` — average signal quality in %
- `clients` — number of associated clients

### aironet_errors

<a id="check-aironet-errors"></a>

*MAC CRC errors radio %s*

#### Overview
This check monitors MAC CRC (Cyclic Redundancy Check) errors per radio on Cisco Aironet wireless access points, providing insight into wireless signal integrity and potential hardware or interference issues.

#### What it monitors
- MAC CRC error counter per radio interface, retrieved via SNMP from the device’s own MIB (.1.3.6.1.4.1.9.9.272.1.2.1.1.1).

#### How it works
Discovers radios by polling the full OID table for radio indices (per-item services), then polls the specific OID for each radio. The error counter is read as an absolute integer value and treated as an approximate *errors-per-second* rate. Fixed thresholds: WARN if ≥1.0, CRIT if ≥10.0.

#### Parameters
None.

#### States
- **OK**: errors < 1.0
- **WARN**: errors ≥ 1.0 and < 10.0
- **CRIT**: errors ≥ 10.0
- **UNKNOWN**: missing/discovery error, no item specified, or malformed SNMP response.

#### Metrics
- `errors` — current MAC CRC error count (unit: count), interpreted as approximate errors per second.

### aix_hacmp_resources

<a id="check-aix-hacmp-resources"></a>

*HACMP RG %s*

#### Overview
This check monitors the status of HACMP (High Availability Cluster Multi-Processing) resource groups on AIX systems. It ensures critical clustered services remain available, which is essential for high-availability environments.

#### What it monitors
- HACMP resource group states (e.g., ONLINE, OFFLINE, FAIL)
- Resource group name and associated nodes
- Failover and failback behavior (concurrent/non-concurrent mode)
- Cluster node health and role (active/passive)

#### How it works
The check parses the `aix_hacmp_resources` agent section (format: `group_name:state:node:mode:flags...`) from the yolo-man agent output. During discovery (`_discover=True`), it identifies individual resource groups to monitor as separate services. The state of each group determines the result: ONLINE groups yield OK; states like OFFLINE or FAIL trigger WARN/CRIT.

#### Parameters
None.

#### States
- **OK**: Resource group is ONLINE and healthy.
- **WARN/CRIT**: Resource group is OFFLINE, FAILING, or in an unexpected state.
- **UNKNOWN**: Data unavailable, agent section missing, or parsing failure.

#### Metrics
None.

### aix_hacmp_services

<a id="check-aix-hacmp-services"></a>

*HACMP Service %s*

#### Overview
This check monitors IBM HACMP (High Availability Cluster Multi-Processing) service groups on AIX systems, ensuring critical high-availability subsystems are running as expected. It validates cluster resource availability, which is vital for maintaining service continuity in enterprise environments.

#### What it monitors
- HACMP service groups (resource groups) and their associated subsystems (e.g., `clcomd`)
- State (active/inactive) of each subsystem within a service group

#### How it works
During discovery (`_discover` mode), it runs `lsrsrc -A IBM.ResourceGroup` (with fallback to `lsrsrc Resource`) to parse resource group and subsystem definitions, extracting group names and subsystem states. For individual checks, it runs the same command to inspect the specified group. It sets the state to CRIT if any subsystem is inactive; otherwise OK. State and per-subsystem metrics are computed and returned.

#### Parameters
None.

#### States
- **OK**: All subsystems in the group are active.
- **CRIT**: One or more subsystems are inactive.
- **UNKNOWN**: No data found for the specified service group (e.g., group does not exist or command fails silently).

#### Metrics
- `status_<subsystem_name>` — 0 if active, 1 if inactive (unit: count).

### alertmanager_groups

<a id="check-alertmanager-groups"></a>

*Alertmanager Check*

#### Overview
This check monitors Alertmanager, a service for managing alerts in Prometheus-based monitoring stacks. It validates alert states and groupings to ensure critical alerts are properly detected and reported, supporting both summary, per-group, and per-rule service discovery.

#### What it monitors
- Alertmanager alert states (`inactive`, `pending`, `firing`, `none`, `not_applicable`)
- Alert groupings and rule counts per group
- Alert severity and messages (for context)
- Custom alert remapping configurations (e.g., Watchdog rule remapping)

#### How it works
Reads the Alertmanager agent cache from `/var/lib/yolo-man-agent/cache/alertmanager`. In discovery mode, it creates services per group, per rule, and optionally a summary service based on configurable thresholds (`min_amount_rules`, `no_group_services`). In check mode, it evaluates alert states for the selected item (summary, group, or individual rule), applies alert remapping, and maps states to yolo-man OK/WARN/CRIT/UNKNOWN.

#### Parameters
None.

#### States
- **OK**: No active critical alerts; all rules `inactive`/`pending` or mapped to OK.
- **WARN**: Alerts present with severity mapped to `pending`/`inactive`, or some rules remapped to `WARN`.
- **CRIT**: One or more `firing` alerts not mapped to OK; Watchdog firing (remapped to CRIT).
- **UNKNOWN**: Cache unreadable, rule/group not found, or unmapped states (e.g., `none`, `not_applicable`).

#### Metrics
None.

### alertmanager_rules

<a id="check-alertmanager-rules"></a>

*Alertmanager Check*

#### Overview
This check monitors the state and severity of Alertmanager rules, providing visibility into Prometheus alerting rule execution and active alerts.

#### What it monitors
- State of individual Alertmanager rules: inactive, pending, firing, none
- Severity level associated with each rule (e.g., warning, critical, none)
- Alert group name and message (if present)

#### How it works
The check reads JSON data from `/opt/yolo-man/agent/output/alertmanager` or falls back to `/var/lib/yolo-man-agent/rawdata/alertmanager`. In discovery mode (`_discover`), it enumerates all rule names across groups as discoverable items. In check mode, it looks up the specified `item` (rule name), maps its raw state (`inactive`, `pending`, `firing`, etc.) to yolo-man states (OK, CRIT, UNKNOWN), applies special logic for the "Watchdog" rule, and reports status, details, and summary.

#### Parameters
None.

#### States
- **OK**: Rule is inactive or pending (unless rule is "Watchdog", where those states are CRIT); severity is non-critical but not flagged.
- **CRIT**: Rule is firing (unless rule is "Watchdog", where firing is OK); or rule is "Watchdog" in non-firing state.
- **UNKNOWN**: Rule state is `none` or `not_applicable`, rule not found, or no item specified.

#### Metrics
None.

### alertmanager_summary

<a id="check-alertmanager-summary"></a>

*Alertmanager Check*

#### Overview
This check monitors the Alertmanager service by evaluating the state of its alerting rules. It ensures timely detection of alert issues (e.g., pending or firing alerts) to support proactive incident response.

#### What it monitors
- Alertmanager alert rules grouped by name or rule category
- State of each rule: inactive, pending, firing, none, or unknown
- Summary state across all rules when no specific item is checked

#### How it works
The check queries the yolo-man agent (`yolo-man_agent`) to retrieve the `<<<alertmanager>>>` JSON section. In discovery mode (`_discover`), it parses rules and groups them per configured `group_services` behavior. During monitoring, it evaluates rule states using optional custom remappings; the worst non-OK state (pending→WARN, firing→CRIT) determines the check status. Item matching is attempted first as a group name, then as a specific rule name.

#### Parameters
- `group_services` (tuple, `("multiple_services", {"min_amount_rules": 3, "no_group_services": []})`) — controls grouping strategy and thresholds for per-group services.
- `summary_service` (bool, `True`) — whether to include a summary service for all rules.
- `alert_remapping` (list, `default_remapping`) — custom rule state mappings.

#### States
- **OK**: All rules are inactive or have `firing` mapped to 0 (OK) via remapping.
- **WARN**: At least one rule is in `pending` state and none are `firing`.
- **CRIT**: At least one rule is in `firing` state or mapped to 2.
- **UNKNOWN**: Alertmanager section missing, empty, or item not found.

#### Metrics
None.

### apache_status

<a id="check-apache-status"></a>

*Apache %s Status*

#### Overview
This check monitors Apache HTTP Server status by parsing the `check_mk_agent` output for the `apache_status` section, collecting per-instance metrics and state information to assess server health and performance.

#### What it monitors
- Apache instance uptime, idle and busy workers/servers
- Total and open slots (request handling capacity)
- Request statistics: total accesses, requests per second, bytes per request/second
- Connection metrics: total connections, async connection states (writing, keep-alive, closing)
- Scoreboard status distribution (e.g., waiting, reading, sending reply)

#### How it works
The check first runs `check_mk_agent` to fetch agent output. In discovery mode, it parses the `apache_status` section to enumerate Apache instances and their items. In check mode, it matches the specified `item` (e.g., `instance:port`, `address:port`) to extract metrics. It converts string values using a type map and computes `TotalSlots` as the sum of open, idle, and busy slots. Metrics and status messages are assembled from the parsed data.

#### Parameters
None.

#### States
- OK: All metrics successfully parsed and reported.
- UNKNOWN: No `apache_status` section found, or no data found for the specified instance.

#### Metrics
- `Uptime`, `IdleWorkers`, `BusyWorkers`, `TotalSlots`, `OpenSlots`, `Total_Accesses`, `CPULoad`, `Total_kBytes`, `ReqPerSec`, `BytesPerReq`, `BytesPerSec`, `ConnsTotal`, `ConnsAsyncWriting`, `ConnsAsyncKeepAlive`, `ConnsAsyncClosing`, `BusyServers`, `IdleServers`
- `State_Waiting`, `State_StartingUp`, `State_ReadingRequest`, `State_SendingReply`, `State_Keepalive`, `State_DNS`, `State_Closing`, `State_Logging`, `State_Finishing`, `State_IdleCleanup`, `OpenSlots` (from scoreboard)

### appdynamics_memory

<a id="check-appdynamics-memory"></a>

*AppDynamics Memory %s*

#### Overview
Monitors memory usage of AppDynamics agents by analyzing spooled memory data, providing status and metrics for heap and non-heap memory segments.

#### What it monitors
- Heap memory usage (used, committed, max available)
- Non-heap memory usage (used, committed, max available)
- Memory levels per item (e.g., "Controller|Heap", "AppAgent|Non-Heap")

#### How it works
Reads `/var/lib/check_mk_agent/spool/appdynamics_memory` for discovery (when `_discover=true`) or for checking a specific item. Matches items by concatenating the first two `|`-delimited fields. Parses memory values (in MB), converts to bytes, and compares usage against optional warn/crit thresholds (percentages or MB free). Thresholds are applied separately per heap/non-heap based on item suffix.

#### Parameters
None.

#### States
- **OK**: Usage is within warn/crit thresholds (or thresholds not set)
- **WARN**: Usage meets or exceeds warning threshold
- **CRIT**: Usage meets or exceeds critical threshold
- **UNKNOWN**: Specified item not found in spool file

#### Metrics
- `mem_heap` — heap memory used, in bytes
- `mem_nonheap` — non-heap memory used, in bytes
- `mem_heap_committed` — heap memory committed, in bytes
- `mem_nonheap_committed` — non-heap memory committed, in bytes

### appdynamics_sessions

<a id="check-appdynamics-sessions"></a>

*AppDynamics Sessions %s*

#### Overview
Monitors AppDynamics session metrics—specifically active and rejected sessions—to detect performance degradation or capacity issues in application performance monitoring infrastructure.

#### What it monitors
- Active (running) sessions
- Rejected sessions
- Maximum active sessions limit
- Session processing rate (sessions per second)

#### How it works
The check reads data from `/var/lib/yolo-man-agent/local/appdynamics_sessions`, which is populated by a local agent plugin. In discovery mode, it enumerates items by combining the first two `|`-separated fields. In check mode, it matches a specific item and extracts metrics. A rate is computed using a stored counter value from `/var/lib/yolo-man-agent/virtual/` and the check interval (300 seconds). Warnings/critical states are triggered based on configurable upper/lower thresholds on active sessions.

#### Parameters
`levels_upper` (tuple, None) — Fixed upper threshold tuple: `("fixed", value)`. `levels_lower` (tuple, None) — Fixed lower threshold tuple: `("fixed", value)`.

#### States
OK — Active sessions within bounds, no issues. WARN — Active sessions exceed lower threshold (if defined) or 80% of upper threshold. CRIT — Active sessions exceed upper threshold. UNKNOWN — Item not found or no data available.

#### Metrics
`running_sessions` — Number of currently active sessions. `rejected_sessions` — Number of rejected sessions. `sessions_rate` — Session processing rate in sessions/second.

### appdynamics_web_container

<a id="check-appdynamics-web-container"></a>

*AppDynamics Web Container %s*

#### Overview
Monitors AppDynamics web container metrics including thread usage, error rates, and request volumes to detect performance degradation or failures.

#### What it monitors
- Current threads in pool
- Busy threads
- Maximum threads
- Error count (converted to error rate per second)
- Request count (converted to request rate per second)

#### How it works
Fetches data from `/var/lib/check_mk_agent/spool/appdynamics_web_container` using `cat`. In discovery mode, it parses lines (split by `|`) to enumerate items and their metric names. In check mode, it looks up the specified item, extracts numeric metrics, applies optional thresholds on current threads (WARN/CRIT if thresholds exceeded), and reports state. If thresholds aren't configured, only OK is reported unless data is missing.

#### Parameters
None.

#### States
- **OK**: Data available, current threads within thresholds (or no thresholds set).
- **WARN**: Current threads ≥ warning threshold (if configured).
- **CRIT**: Current threads ≥ critical threshold (if configured).
- **UNKNOWN**: Agent data missing or item not found.

#### Metrics
- `current_threads` — number of threads
- `threads_percent` — percentage of max threads
- `busy_threads` — number of busy threads
- `error_rate` — errors per second (errors / 300)
- `request_rate` — requests per second (requests / 300)

### arbor_memory

<a id="check-arbor-memory"></a>

*Memory*

#### Overview
This check monitors memory and swap usage on Arbor Peakflow SP, TMS, and Pravail devices via SNMP. It ensures these network security appliances maintain healthy memory utilization to prevent performance degradation or service disruption.

#### What it monitors
- RAM usage as a percentage
- Swap usage as a percentage

#### How it works
In discovery mode, it yields one service with metrics `mem_used_percent` and `swap_used_percent`. In check mode, it runs `snmpwalk` against three device-specific OID bases to retrieve integer values for RAM and swap percentages. It stops at the first device where both values are successfully retrieved. It compares usage against configurable warning/critical thresholds (default 80%/90% for both RAM and swap) to determine state.

#### Parameters
None.

#### States
- **OK**: RAM and swap usage are below their respective warning thresholds
- **WARN**: RAM or swap usage meets or exceeds warning threshold but not critical
- **CRIT**: RAM or swap usage meets or exceeds critical threshold
- **UNKNOWN**: Memory data could not be retrieved via SNMP

#### Metrics
- `mem_used_percent` — RAM usage percentage
- `swap_used_percent` — Swap usage percentage

### artec_documents

<a id="check-artec-documents"></a>

*Documents*

#### Overview
This check monitors document counts processed by the Artec Documents application, providing visibility into document handling volume.

#### What it monitors
- Document counts for various document types (e.g., `InputCount`, `ProcessedCount`) reported by the Artec Documents agent.

#### How it works
The check reads JSON lines from `/var/lib/check_mk_agent/spool/artec_documents`. Each line is a JSON array `[doc_name, doc_val]`, where `doc_val` is parsed as an integer. It strips trailing “Count” from names, sums valid counts, and reports OK with details showing counts and a fixed rate of 0.00/s (no persistence for rate calculation). If the spool file is missing, empty, or lacks valid entries, it returns UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Valid document counts are found and parsed.
- **UNKNOWN**: Spool file missing, no data, or no valid integer counts.
- **WARN/CRIT**: Not used—check never raises warnings or criticals.

#### Metrics
- `name` (where `name` is the document type sans “Count”) — integer count of documents.

### audiocodes_calls

<a id="check-audiocodes-calls"></a>

*SBC calls*

#### Overview
Monitors call statistics for AudioCodes Session Border Controllers (SBCs), providing visibility into call handling, success rates, and abnormal terminations to ensure reliable VoIP services.

#### What it monitors
- Active calls in/out (current ongoing calls)
- Established calls in/out rates (calls successfully connected per time unit)
- Average call duration
- Answer seizure ratio (% of calls that are answered after seizure)
- Network effectiveness ratio (% of successful connections)
- Abnormal terminated calls in/out (unexpected call drops or failures)

#### How it works
Reads comma-separated values from `/var/lib/yolo-man-agent/cache/audiocodes_calls`. In discovery mode, it emits one service with all metrics listed. Otherwise, it parses nine integer fields, applies optional warning/critical thresholds to answer seizure and network effectiveness ratios, and updates state based on threshold violations. UNKNOWN if no data or malformed.

#### Parameters
None.

#### States
- OK: All metrics within expected bounds.
- WARN: Answer seizure ratio or network effectiveness ratio falls below warning thresholds.
- CRIT: Answer seizure ratio or network effectiveness ratio falls below critical thresholds.
- UNKNOWN: No data available or unexpected data format.

#### Metrics
- `audiocodes_average_call_duration` — call duration in seconds
- `audiocodes_active_calls_in` — active incoming calls (count)
- `audiocodes_active_calls_out` — active outgoing calls (count)
- `audiocodes_established_calls_in` — established incoming calls rate (count)
- `audiocodes_established_calls_out` — established outgoing calls rate (count)
- `audiocodes_answer_seizure_ratio` — ratio of answered calls (%)
- `audiocodes_network_effectiveness_ratio` — network success ratio (%)
- `audiocodes_abnormal_terminated_calls_in_total` — abnormal incoming terminations (count)
- `audiocodes_abnormal_terminated_calls_out_total` — abnormal outgoing terminations (count)

### audiocodes_overall_operational_state

<a id="check-audiocodes-overall-operational-state"></a>

*Operational state*

#### Overview
Monitors the overall operational state of AudioCodes devices by evaluating both a generic operational state and a gateway-specific severity, ensuring timely detection of device issues.

#### What it monitors
- Generic operational state (0=OK, 1=UNKNOWN, 2=WARN, 3=CRIT)
- Gateway severity level (0–5, mapped to alarm descriptions and OK/WARN/CRIT states)
- Associated error messages and error IDs from the device

#### How it works
Reads agent data from either a JSON file (`/var/lib/check-mk-agent/audit/audiocodes_overall_operational_state.json`) or a text spool file (`/var/lib/check-mk-agent/spool/audiocodes_overall_operational_state`). In discovery mode, yields one service with empty item. The final state is determined by prioritizing the worse of the two states (CRIT > WARN > UNKNOWN > OK). Details include error message and ID if present.

#### Parameters
None.

#### States
- **OK**: Both operational and gateway states are "OK".
- **WARN**: Either state is WARN or Minor/Warning.
- **CRIT**: Either state is CRIT or Major/Critical.
- **UNKNOWN**: Data unavailable, or both states map to UNKNOWN.

#### Metrics
None.

### audiocodes_sip_calls

<a id="check-audiocodes-sip-calls"></a>

*SIP calls*

#### Overview
Monitors SIP/H.323 call activity on AudioCodes VoIP gateways, tracking both telephone-to-IP (Tel2IP) and IP-to-telephone (IP2Tel) call flows to ensure proper VoIP functionality and detect call failures.

#### What it monitors
- Attempted, established, busy, no-answer, no-route, no-match, and failed SIP/H.323 calls (Tel2IP and IP2Tel)
- Fax attempts and successes
- Total call duration

#### How it works
Reads precollected JSON data from `/var/lib/yolo-man/agent/results/json/audiocodes_sip_calls`. In discovery mode, it confirms service presence if ≥10 data points exist in either `tel2ip` or `ip2tel`. In check mode, it parses the data, converts numeric values to metrics, and reports state OK if either section exists, otherwise UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Either `tel2ip` or `ip2tel` data is available (non-null).
- **UNKNOWN**: No SIP calls data file exists or both `tel2ip` and `ip2tel` are null/empty.
- **WARN/CRIT**: Not used (no thresholds defined).

#### Metrics
- `audiocodes_tel2ip_attempted_calls`, `established_calls`, `busy_calls`, `no_answer_calls`, `no_route_calls`, `no_match_calls`, `fail_calls`, `fax_attempted_calls`, `fax_success_calls`, `total_duration`
- `audiocodes_ip2tel_attempted_calls`, `established_calls`, `busy_calls`, `no_answer_calls`, `no_route_calls`, `no_match_calls`, `fail_calls`, `fax_attempted_calls`, `fax_success_calls`, `total_duration`
All metrics are counts (integers) or duration in seconds.

### bi_aggregation

<a id="check-bi-aggregation"></a>

*Aggr %s*

#### Overview
This check monitors the state and health of Business Intelligence (BI) aggregations discovered by the yolo-man agent. It ensures that BI aggregations—used to compute composite metrics from multiple services—are functioning as expected and alerts on issues affecting their computation or state.

#### What it monitors
- BI aggregation state (computed by the agent: OK, Warning, Critical, Unknown, Pending)
- Whether the aggregation is currently in scheduled downtime
- Whether the aggregation state is acknowledged
- Aggregation-specific error messages (including nested error trees)

#### How it works
The check first discovers all BI aggregations via `cmk -d bi_aggregation`, returning a list of items. For a specific item, it runs the same command, parses JSON output for the named aggregation, and maps its `state_computed_by_agent` value (0–3, -1) to OK/WARN/CRIT/UNKNOWN/PENDING states. It also processes hierarchical error info (if present) to extract and surface detailed error messages.

#### Parameters
None.

#### States
- **OK**: Aggregation state 0 or pending (mapped as OK).
- **WARN**: Aggregation state 1.
- **CRIT**: Aggregation state 2.
- **UNKNOWN**: Aggregation state 3 or aggregation name not found.

#### Metrics
None.

### bi_aggregation_connection

<a id="check-bi-aggregation-connection"></a>

*BI Datasource Connection*

#### Overview
Monitors the connectivity and data availability of BI (Business Intelligence) aggregations in yolo-man by checking for missing sites, aggregations, or generic errors reported by the agent.

#### What it monitors
- Missing monitoring sites (`missing_sites`)
- Missing aggregation data (`missing_aggr`)
- Generic data collection errors (`generic_errors`)

#### How it works
The check reads the yolo-man agent output file (`/var/lib/check_mk/agent_output`), parses the `bi_aggregation_connection` section (which contains JSON-like Python dict strings), and extracts error lists. It returns a single discovered service (no items). State is set to WARN if any of the three error lists contain items; otherwise OK.

#### Parameters
None.

#### States
- **OK**: No missing sites, missing aggregations, or generic errors.
- **WARN**: One or more items found in `missing_sites`, `missing_aggr`, or `generic_errors`.
- **UNKNOWN**: Not applicable; the check always returns OK or WARN if data is parsed.

#### Metrics
None.

### bluecat_command_server

<a id="check-bluecat-command-server"></a>

*Command Server*

#### Overview
This check monitors the operational state of the BlueCat Command Server via SNMP, ensuring it is running normally and alerting on failures or abnormal states.

#### What it monitors
- Operational state of the BlueCat Command Server (via SNMP OID `.1.3.6.1.4.1.13315.3.1.7.2.1.1`)

#### How it works
In discovery mode, it yields one service item with an empty name. In check mode, it executes `snmpget` to retrieve the `oper_state` integer value. It parses the output, maps numeric codes to human-readable states (e.g., `1` = running normally), and compares the value against configurable warning/critical thresholds. Defaults warn on states 2–4 (not running, starting, stopping), critical on state 5 (fault).

#### Parameters
None.

#### States
- **OK**: `oper_state` = 1 (running normally).
- **WARN**: `oper_state` in [2, 3, 4] (not running, currently starting, currently stopping).
- **CRIT**: `oper_state` = 5 (fault).
- **UNKNOWN**: SNMP command fails, unexpected output format, or invalid value.

#### Metrics
None.

### bluecat_dns

<a id="check-bluecat-dns"></a>

*DNS*

#### Overview
Monitors the operational state of the BlueCat DNS service using SNMP to detect failures or abnormal states.

#### What it monitors
- DNS service operational state (e.g., running, stopped, faulting)

#### How it works
The check performs an SNMP walk on OID `.1.3.6.1.4.1.13315.3.1.2.2.1.1` to retrieve the DNS service’s operational state as an integer. In discovery mode, it creates a single service item with no sub-items. In check mode, it parses the first INTEGER value returned, maps it to a state description, and compares it against configurable warning/critical thresholds (default: warning on states 2–4, critical on 5). Returns OK/WARN/CRIT/UNKNOWN based on the result.

#### Parameters
None.

#### States
- **OK**: State is `1` (running normally) and not in warning/critical lists.
- **WARN**: State is `2` (not running), `3` (starting), or `4` (stopping).
- **CRIT**: State is `5` (fault).
- **UNKNOWN**: SNMP query fails or the oper_state value cannot be parsed.

#### Metrics
None.

### bluecat_ha

<a id="check-bluecat-ha"></a>

*HA State*

#### Overview
Monitors the High Availability (HA) operational state of a BlueCat Gateway device via SNMP, ensuring the HA configuration remains in a healthy, expected state (e.g., active/passive) rather than failing into fault or stopping modes.

#### What it monitors
- HA operational state of the BlueCat Gateway (e.g., standalone, active, passive, fault, stopping, etc.)

#### How it works
Uses `snmpget` to query OID `.1.3.6.1.4.1.13315.3.1.5.2.1.1`, extracting the integer HA state value. In discovery mode, it yields a service only if the state is *not* standalone (1), with configurable warning/critical state lists. In check mode, it maps the state integer to a human-readable name and compares against thresholds (default warning: 5,6,7; critical: 8,4) to determine OK/WARN/CRIT/UNKNOWN.

#### Parameters
None.

#### States
- **OK**: HA state is not in warning or critical lists (e.g., active, passive, standalone).
- **WARN**: HA state is in the warning list (5,6,7 by default: stopping, becoming active, becoming passive).
- **CRIT**: HA state is in the critical list (8,4 by default: fault, stopped).
- **UNKNOWN**: SNMP query fails or output cannot be parsed.

#### Metrics
None.

### bvip_video_alerts

<a id="check-bvip-video-alerts"></a>

*Video Alerts %s*

#### Overview
This check monitors video alert states of devices (e.g., BlackVue IP cameras) via SNMP, reporting critical status when any configured alert is triggered, ensuring timely detection of surveillance anomalies.

#### What it monitors
- Video alert states for discrete items (e.g., motion detection zones, line-crossing triggers) reported by the device.
- Each item corresponds to a named alert condition configured on the device.

#### How it works
On discovery, it walks two SNMP OIDs: `.1.3.6.1.4.1.3967.1.1.3.1` (item names) and `.1.3.6.1.4.1.3967.1.3.1.1` (alert values), pairing items by index. For a specific monitored item, it checks the alert value: `"0"` = OK, any other value = CRIT (alarm). Returns UNKNOWN if the item name is not found.

#### Parameters
None.

#### States
- **OK**: Alert value for the item is `"0"` (no alarm).
- **CRIT**: Alert value is non-zero (`"1"`, `"2"`, etc.), indicating an active alarm.
- **UNKNOWN**: Item name provided does not match any discovered alert item.
- **UNKNOWN** may also occur on SNMP failure (e.g., unreachable host, wrong community).

#### Metrics
None.

### cadvisor_memory

<a id="check-cadvisor-memory"></a>

*Memory*

#### Overview
Monitors container or pod memory usage via cAdvisor data, providing visibility into resource consumption in containerized environments.

#### What it monitors
- Memory used by container or pod (`memory_usage_container` or `memory_usage_pod`)
- Memory cache (`memory_cache`)
- Swap usage (`memory_swap`)
- Memory limit (if defined), or falls back to total machine memory

#### How it works
Reads JSON data from `/var/lib/check_mk_agent/spool/cadvisor_memory`. In discovery mode, it emits a single service item with metrics `mem_used`, `mem_lnx_cached`, `swap_used`. In check mode, it computes usage percentage against the relevant memory total (limit or machine) and reports OK/WARN/CRIT based on thresholds (not defined in source—defaults to OK unless data is missing).

#### Parameters
None.

#### States
- **OK**: Memory data available and successfully parsed; usage reported.
- **UNKNOWN**: Missing or invalid cAdvisor memory data, or missing required fields (`memory_usage_container`/`memory_usage_pod`).

#### Metrics
- `mem_used` — current memory usage in bytes
- `mem_lnx_cached` — memory cache usage in bytes
- `swap_used` — swap usage in bytes

### cbl_airlaser_status

<a id="check-cbl-airlaser-status"></a>

*CBL Airlaser Status*

#### Overview
Monitors the operational status of a CBL Airlaser device via SNMP self-test results, ensuring it is functioning correctly in normal, testing, warning, or failure states.

#### What it monitors
- Overall airlaser self-test status (normal, testing, warning, or component failure)

#### How it works
In discovery mode, it emits a single service with default thresholds for temperature metrics (not used in check mode). In check mode, it runs `snmpget` on OID `.1.3.6.1.4.1.2800.2.1.3.0`, parses the response, and maps values `1`–`4` to OK, WARN, WARN, and CRIT states, respectively. Unknown or unparseable values yield UNKNOWN.

#### Parameters
None.

#### States
- **OK**: `1` — normal operation
- **WARN**: `2` — testing mode, or `3` — warning condition
- **CRIT**: `4` — component self-test failure
- **UNKNOWN**: SNMP error, non-numeric response, or value outside `1`–`4`

#### Metrics
None.

### check_plugin

<a id="check-check-plugin"></a>

*Universal check bridge — auto-detects Nagios / Checkmk output*

#### Overview
The `check_plugin` acts as a universal bridge for external monitoring checks, automatically detecting and normalizing output from Nagios plugins, yolo-man local checks, or agent sections into a consistent verdict format.

#### What it monitors
- Exit code and stdout of arbitrary external check commands.
- Format-specific structures: Nagios summary/perfdata, yolo-man local-service lines, or yolo-man agent sections.

#### How it works
Runs the configured command via `ctx.run`, detects output format (nagios/local/agent) using regex heuristics, then parses accordingly. For `local` format, it discovers and selects services by `item`. Verdict is derived from exit code (nagios), parsed status token (local), or always OK (agent). Discovery is supported via `_discover` mode.

#### Parameters
- `command` (list, required) — argv of the external check to run.
- `force_format` (str, optional, default: `""`) — overrides auto-detection with `"nagios"`, `"local"`, or `"agent"`.
- `item` (str, optional, default: `""`) — for local checks, selects which service line to evaluate.

#### States
OK: nagios exit 0, local status `0`/`P`, or agent section output.
WARN: nagios exit 1 or local status `1`.
CRIT: nagios exit 2 or local status `2`.
UNKNOWN: nagios exit 3, local status `3`, item not found, invalid command, or format ambiguity.

#### Metrics
- `sections` (int, agent format only) — count of detected agent sections.
- Other metrics extracted from perfdata (Nagios/local): `label` → numeric value (e.g., load, usage %).

### checkpoint_tunnels

<a id="check-checkpoint-tunnels"></a>

*Tunnel %s*

#### Overview
Monitors the status of Check Point VPN tunnels via SNMP, ensuring critical security connections remain active and alerting on failures or degradation.

#### What it monitors
- Presence and status of Check Point IPsec VPN tunnel peers (by IP address)
- Tunnel state: Active, Idle, Destroy, Init, Phase1, Down

#### How it works
In discovery mode, performs an SNMP walk on `.1.3.6.1.4.1.2620.500.9002.1.2` to enumerate tunnel peers (extracted from STRING values). In check mode, walks `.1.3.6.1.4.1.2620.500.9002.1` to find a specific tunnel’s status (INTEGER), maps it to a named state, and compares against thresholds in `params` (default: Active/Idle=OK, Destroy/Init=WARN, Phase1/Down=CRIT). Returns OK/WARN/CRIT/UNKNOWN based on threshold match.

#### Parameters
None.

#### States
- **OK**: Tunnel state is Active or Idle
- **WARN**: Tunnel state is Destroy or Init
- **CRIT**: Tunnel state is Phase1 or Down
- **UNKNOWN**: SNMP fails, tunnel not found, or unrecognized status code

#### Metrics
None.

### checkpoint_vsx

<a id="check-checkpoint-vsx"></a>

*VS %s Info*

#### Overview
Monitors Check Point VSX (Virtual System Extension) instances via SNMP, providing status and configuration details for each virtual system on a Check Point firewall.

#### What it monitors
- VS instance ID, name, type, IP address
- Assigned policy and policy type
- SIC (Secure Internal Communication) status
- HA (High Availability) status

#### How it works
Uses `snmpwalk` with community `public` to query Check Point VSX MIB tables. In discovery mode, it enumerates all VS instances by parsing the `vsId` OID (`.1.3.6.1.4.1.2620.1.16.22.1.1.1`). In check mode, it retrieves full VS details for a specific instance (matched by item name or ID) and returns OK if found, UNKNOWN if not.

#### Parameters
None.

#### States
- OK: VS instance is found.
- UNKNOWN: VS instance not found, or SNMP walk fails.
- (No WARN or CRIT states are implemented.)

#### Metrics
None.

### checkpoint_vsx_status

<a id="check-checkpoint-vsx-status"></a>

*VS %s Status*

#### Overview
Monitors the operational status of Check Point Virtual Systems (VS) on a VSX-enabled device by querying SNMP data. It ensures VS instances are healthy, properly configured, and synchronized—critical for high availability and security policy enforcement.

#### What it monitors
- VS name, ID, type, and IP address
- HA (High Availability) status (e.g., Active/Standby)
- SIC (Secure Internal Communication) status (e.g., “trust established”)
- Policy name and type (e.g., Active/Initial)

#### How it works
In discovery mode, the check runs `snmpwalk` on multiple OIDs to enumerate VS instances and their properties, then builds per-VS items for monitoring. In check mode, it retrieves status-only OIDs for a specific VS instance (identified by `item`) and determines state: CRIT if HA status is not Active/Standby, SIC status is not “trust established”, or policy type is neither Active nor Initial; otherwise OK.

#### Parameters
None.

#### States
- **OK**: HA status is Active/Standby, SIC status is “trust established”, and policy type is Active or Initial.
- **CRIT**: One or more of the above conditions fail.
- **UNKNOWN**: SNMP probe fails or `item` is not found.

#### Metrics
None.

### ciena_cfm

<a id="check-ciena-cfm"></a>

*CFM-Service %s*

#### Overview
Monitors the operational state of Ciena CFM (Connectivity Fault Management) services via SNMP, ensuring services are enabled as expected.

#### What it monitors
- CFM service names and their operational states (enabled/disabled) on Ciena devices.
- Compares current state against a previously discovered state during discovery mode.

#### How it works
In discovery mode, it runs two `snmpwalk` commands to fetch service names (OID `.1.3.6.1.4.1.1271.2.1.4.1.2.1.1.6`) and states (OID `.1.3.6.1.4.1.1271.2.1.4.1.2.1.1.5`). It parses STRING and INTEGER values to build a list of services. In check mode, for a specific item, it re-runs both `snmpwalk`s to locate the item by name and compare its current numeric state (1=enabled, 2=disabled) with the discovered state. CRIT if mismatched, OK if matched.

#### Parameters
None.

#### States
- **OK**: Current service state matches the discovered state.
- **CRIT**: Current state differs from discovered state (e.g., enabled vs. disabled).
- **UNKNOWN**: Service not found or no state returned.

#### Metrics
None.

### ciena_tunnel

<a id="check-ciena-tunnel"></a>

*Tunnel %s*

#### Overview
Monitors the operational status of Ciena 5171/5142 IP tunnel interfaces via SNMP, ensuring critical tunnel connections remain enabled as expected.

#### What it monitors
- Tunnel interface names and their operational state (enabled/disabled) on Ciena devices.

#### How it works
Uses `snmpwalk` to query two SNMP MIB subtrees (`.1.3.6.1.4.1.1271.2.1.18.1.2.2.1` for 5171, `.1.3.6.1.4.1.1271.2.1.18.1.2.6.1` for 5142), extracting tunnel names (OID suffix `.2`) and operational states (`.7` or `.4`). In discovery mode, it enumerates all tunnels and stores each with its initial state as `discovered_oper_state`. In check mode, it locates the requested tunnel and compares its current state to the expected state: OK if matched, CRIT if mismatched, UNKNOWN if the tunnel is not found.

#### Parameters
None.

#### States
- OK: Tunnel is present and its current state matches the expected (typically `enabled`) state.
- CRIT: Tunnel is present but its state differs from the expected state (e.g., disabled when expected enabled).
- UNKNOWN: Tunnel not found in SNMP output.

#### Metrics
None.

### cisco_cpu_memory

<a id="check-cisco-cpu-memory"></a>

*CPU Memory utilization %s*

#### Overview
This check monitors CPU memory utilization on Cisco devices via SNMP, providing insights into memory pressure that can affect device stability and performance.

#### What it monitors
- Memory used, free, and reserved (in absolute units)
- Memory usage percentage
- Per-CPU or per-memory-unit utilization (discovered items)

#### How it works
The check uses two SNMP walks: one for memory statistics (`1.3.6.1.4.1.9.9.109.1.1.1.1`) and one for physical index descriptions (`1.3.6.1.2.1.47.1.1.1.1.7`). In discovery mode, it builds a map of indices to CPU/memory names (stripping “cpu ” prefix). In check mode, it matches the given item (by name or index), computes total/used/reserved memory, and determines state based on optional warning/critical thresholds (bytes or percentage). Thresholds default to percentage if specified as numbers; absolute thresholds in MB are also supported.

#### Parameters
- `item` (string or numeric string, required) — specifies which memory unit to check (e.g., "RSP0", "0").
- `levels` (tuple of (warn, crit), optional) — thresholds either as percentage (default) or absolute MB if warn is int.

#### States
- **OK**: Memory usage within thresholds.
- **WARN**: Usage exceeds warning threshold.
- **CRIT**: Usage exceeds critical threshold.
- **UNKNOWN**: Item not found, zero total memory, or SNMP failure.

#### Metrics
- `mem_used` — bytes of memory currently used
- `mem_total` — total memory available (used + free)
- `mem_reserved` — reserved memory bytes
- `mem_used_percent` — percentage of (used + reserved) / total

### cisco_meraki_org_api_response_codes

<a id="check-cisco-meraki-org-api-response-codes"></a>

*API %s*

#### Overview
This check monitors the API availability and HTTP response code distribution for Cisco Meraki organizations by parsing agent-collected data. It ensures Meraki API access is enabled and alerts on response code patterns that may indicate operational issues.

#### What it monitors
- Whether Meraki API access is enabled per organization
- HTTP response code counts categorized by class (2xx, 3xx, 4xx, 5xx)
- Organization name and ID for identification

#### How it works
On discovery, it reads `/var/lib/yolo-man-agent/parsed/cisco_meraki_org_api_response_codes`, extracts organization identifiers, and creates services per organization. In check mode, it fetches the same parsed section, validates the requested item, determines state (OK/WARN/CRIT) based on `api_enabled`, and aggregates HTTP response codes. Default CRIT state for disabled API can be overridden via parameter.

#### Parameters
`state_api_not_enabled` (int, 2) — defines the state (0=OK, 1=WARN, 2=CRIT) when API access is disabled.

#### States
- OK: API is enabled.
- CRIT: API is disabled and `state_api_not_enabled` = 2 (default).
- WARN: API is disabled and `state_api_not_enabled` = 1.
- UNKNOWN: Section unavailable, item not found, or no item specified.

#### Metrics
`api_code_2xx` — count of HTTP 2xx (success) responses
`api_code_3xx` — count of HTTP 3xx (redirection) responses
`api_code_4xx` — count of HTTP 4xx (client error) responses
`api_code_5xx` — count of HTTP 5xx (server error) responses

### cisco_meraki_org_appliance_performance

<a id="check-cisco-meraki-org-appliance-performance"></a>

*Appliance performance*

#### Overview
Monitors the performance score of a Cisco Meraki MX appliance, reflecting overall system utilization and health. A high score indicates reduced performance capacity, making this check critical for proactive issue detection.

#### What it monitors
- Appliance performance score (`perfScore`) as a percentage (0–100), where higher values indicate lower performance/headroom.

#### How it works
The check reads agent data from the spool file `/var/lib/check_mk_agent/spool/cisco_meraki_org_appliance_performance`, parses the JSON payload, and extracts `perfScore`. Discovery creates a single service with default warning/critical thresholds of 60/80. State is determined by comparing `utilization` against configurable upper thresholds.

#### Parameters
None.

#### States
- **OK**: `perfScore` < warning threshold (default < 60).
- **WARN**: `perfScore` ≥ warning threshold (default ≥ 60) but < critical (default < 80).
- **CRIT**: `perfScore` ≥ critical threshold (default ≥ 80).
- **UNKNOWN**: Missing or invalid agent data, or parse errors.

#### Metrics
- `utilization` — current performance score percentage (%).

### cisco_meraki_org_licenses_overview

<a id="check-cisco-meraki-org-licenses-overview"></a>

*Licenses %s*

#### Overview
This check monitors the license status and expiration for Cisco Meraki organizations, providing visibility into license health and device coverage.

#### What it monitors
- Organization license status (OK or non-OK)
- Number of licensed devices per device type (e.g., gateways, security appliances, switches)
- Time remaining until license expiration

#### How it works
The check reads a JSON file from `/var/lib/check_mk_agent/spool/cisco_meraki_org_licenses_overview`. During discovery (`_discover` mode), it extracts organization names and IDs to create per-organization services. For a specific service, it parses the JSON to find the matching organization, evaluates status, computes remaining license time (seconds), and compares against optional levels to set the state (OK/WARN/CRIT/UNKNOWN). Device-type counts are categorized and appended to details.

#### Parameters
None.

#### States
- **OK**: License status is "OK" and expiration time is above warning/critical thresholds (if configured).
- **WARN**: License status is non-OK, or expiration time ≤ warning level.
- **CRIT**: License status is non-OK and `state_license_not_ok` is 2, or expiration time ≤ critical level, or licenses expired (negative remaining time).
- **UNKNOWN**: No data file, empty file, or organization not found.

#### Metrics
- `remaining_time` — seconds until license expiration.

### cisco_meraki_org_wireless_device_statuses_bands

<a id="check-cisco-meraki-org-wireless-device-statuses-bands"></a>

*Radio %s*

#### Overview
Monitors wireless radio band configurations (channel, channel width, signal power, broadcasting status) for Cisco Meraki wireless devices by querying the agent’s `cisco_meraki_org_wireless_device_statuses` section.

#### What it monitors
- Radio band name (e.g., `2.4 GHz`, `5 GHz`, `6 GHz`)
- Channel number
- Channel width (in Hz)
- Signal power (in dBm)
- Broadcasting status (yes/no)

#### How it works
During discovery, it runs `cmk --dump-agent ... --section cisco_meraki_org_wireless_device_statuses`, parses the JSON payload, extracts unique `band` values from `basicServiceSets`, and creates per-band per-item services. In check mode, it retrieves the same agent data, finds the SSID matching the item (band), and reports channel, channel width, signal power, and broadcasting status.

#### Parameters
None.

#### States
- **OK**: Band is found and data is valid.
- **UNKNOWN**: Agent section unavailable, data parsing fails, band not found, or no data.

#### Metrics
- `channel` — radio channel number (unitless)
- `channel_width` — channel bandwidth in Hz
- `signal_power` — transmit power in dBm

### cisco_meraki_org_wireless_device_statuses_ssids

<a id="check-cisco-meraki-org-wireless-device-statuses-ssids"></a>

*SSID %s*

#### Overview
This check monitors the status (enabled/disabled, visibility, and SSID number) of individual Wi-Fi SSIDs for Cisco Meraki wireless devices, ensuring network services are properly configured and accessible.

#### What it monitors
- Whether a specific SSID is enabled or disabled
- Whether the SSID is visible to clients
- The numeric SSID identifier (SSID number)

#### How it works
On discovery (`_discover=true`), it runs the Meraki wireless agent section, parses the `basicServiceSets` JSON list, and extracts all `ssidName` values as check items. For a single SSID check, it queries the same agent section, locates the requested SSID by name, and reports its state: `OK` if enabled, `WARN` (default) or `CRIT` (via parameter) if disabled. Fails with `UNKNOWN` if the SSID is not found or agent output is malformed.

#### Parameters
- `state_if_not_enabled` (int, 1) — the state to report when the SSID is disabled (default: WARN).

#### States
- OK: SSID is enabled
- WARN/CRIT: SSID is disabled (configurable via `state_if_not_enabled`)
- UNKNOWN: SSID not found in agent data or agent output structure is invalid

#### Metrics
None.

### cisco_meraki_org_wireless_ethernet_statuses

<a id="check-cisco-meraki-org-wireless-ethernet-statuses"></a>

*Interface %s*

#### Overview
This check monitors the status of wireless Ethernet interfaces on Cisco Meraki organizations, verifying link speed, duplex, and power configuration to detect misconfigurations or changes.

#### What it monitors
- Interface link speed (in bits/s)
- Duplex mode (half/full)
- Power mode (e.g., full, auto)
- AC power connection status
- PoE (Power over Ethernet) connection status
- PoE standard (e.g., 802.3at, 802.3af)

#### How it works
Data is gathered by running the `cmk --run-probe cisco_meraki_org_wireless_ethernet_statuses` command and parsing JSON output. In discovery mode, it enumerates ports and creates per-item services with their negotiated speeds. In check mode, it matches the requested item (port name), compares current metrics (speed, duplex, power) against thresholds, and assigns OK/WARN states based on configurable parameters.

#### Parameters
- `state_no_speed` (int, 1) — severity when speed cannot be determined.
- `state_not_full_duplex` (int, 1) — severity when duplex is not full.
- `state_not_on_fill_power` (int, 1) — severity when power mode is not full.
- `state_speed_change` (int, 1) — severity when speed differs from last check.
- `speed` (int or None, None) — prior speed from discovery, used to detect changes.

#### States
- OK: Speed, duplex (full), and power mode (full) meet expectations; speed unchanged from last check.
- WARN: Any threshold-matching condition is violated (speed unknown, not full duplex, non-full power mode, or speed changed).
- UNKNOWN: No matching port found or agent returns invalid/missing data.

#### Metrics
- `speed` — current link speed in bits/s.

### cisco_redundancy

<a id="check-cisco-redundancy"></a>

*Redundancy Framework Status*

#### Overview
Monitors Cisco redundancy framework status (e.g., RPR+ or Stateful Switchover) via SNMP to detect unexpected redundancy changes or failures.

#### What it monitors
- Unit and peer redundancy state (e.g., active, standby hot, disabled)
- Unit and peer IDs
- Duplex mode (SUB-Peer detected or not)
- Last switchover (swact) reason code

#### How it works
In discovery mode, it runs `snmpwalk` on six Cisco-specific OIDs to confirm redundancy data exists and the swact reason is supported (≠1). If valid, it emits one per-host service with captured initial states. In check mode, it re-fetches current states, compares them to initial states, and determines status: OK if unchanged, WARN or CRIT if a switchover occurred (depending on resulting states), or CRIT if peer state is “not known” (1). Discovery uses per-item services.

#### Parameters
None.

#### States
- OK: Redundancy states unchanged since discovery; swact reason reported.
- WARN: Switchover occurred, but both units now in acceptable states (active/standby hot/active).
- CRIT: Switchover occurred with units in non-ideal states (e.g., disabled), or peer state is “not known”.
- UNKNOWN: SNMP fetch fails or OIDs missing.

#### Metrics
None.

### cisco_sma_dns_requests

<a id="check-cisco-sma-dns-requests"></a>

*DNS Requests*

#### Overview
Monitors DNS request metrics (pending and outstanding) from a Cisco SMA appliance to detect DNS processing bottlenecks or failures. High values may indicate DNS resolution issues affecting email or security services.

#### What it monitors
- `pending_dns_requests`: Number of DNS requests waiting for resolution.
- `outstanding_dns_requests`: Number of active DNS requests in progress.

#### How it works
The check reads a two-line section (`_section_cisco_sma_dns_requests`) containing string representations of pending and outstanding counts. It validates both are numeric digits, converts to integers, and compares against optional upper thresholds (`pending_dns_levels`, `outstanding_dns_levels`). Discovery is enabled via `_discover`, emitting one service with both metrics. Verdict: CRIT if either metric exceeds its critical threshold, WARN if it exceeds warning threshold, otherwise OK. Returns UNKNOWN if data is missing, malformed, or incomplete.

#### Parameters
`pending_dns_levels` (tuple, ("no_levels", None)) — Warning/critical threshold tuple for pending requests.
`outstanding_dns_levels` (tuple, ("no_levels", None)) — Warning/critical threshold tuple for outstanding requests.

#### States
OK — both metrics within thresholds (or no levels set).
WARN — either metric exceeds its warning threshold.
CRIT — either metric exceeds its critical threshold.
UNKNOWN — missing, incomplete, or invalid section data.

#### Metrics
`pending_dns_requests` — count of pending DNS requests (unit: requests).
`outstanding_dns_requests` — count of active DNS requests (unit: requests).

### cisco_sma_mail_transfer_memory

<a id="check-cisco-sma-mail-transfer-memory"></a>

*Mail transfer memory*

#### Overview
This check monitors the memory state of the mail transfer agent on a Cisco Secure Mail Appliance (SMA) via SNMP, ensuring mail processing isn’t impaired by memory exhaustion.

#### What it monitors
- Mail transfer memory availability status on the SMA device (available, shortage, or full)

#### How it works
The check performs an SNMP GET query to OID `.1.3.6.1.4.1.15497.1.1.1.7` using the `public` community and SNMPv2c. It parses the returned integer status value, maps it to one of three states (1=available, 2=shortage, 3=full), and maps these to operational states (OK/WARN/CRIT) using configurable thresholds from parameters (default: 1→OK, 2→WARN, 3→CRIT). If discovery is requested, it auto-discovers a single service item.

#### Parameters
None.

#### States
- OK: Memory is available (status value 1)
- WARN: Memory shortage detected (status value 2), unless reconfigured to OK or CRIT
- CRIT: Memory full (status value 3), unless reconfigured to OK or WARN
- UNKNOWN: SNMP query fails, output is unparsable, or status value is unrecognized

#### Metrics
None.

### cisco_sma_mail_transfer_threads

<a id="check-cisco-sma-mail-transfer-threads"></a>

*Mail transfer threads*

#### Overview
Monitors the total number of mail transfer threads used by a Cisco Security Management Appliance (SMA) to handle email traffic, helping detect performance degradation or resource exhaustion.

#### What it monitors
- Total count of active mail transfer threads on the SMA.

#### How it works
Performs a single-item SNMP query (OID `.1.3.6.1.4.1.15497.1.1.1.20`) using `snmpget`. Parses the returned `INTEGER` value. Compares the value against configurable upper and lower thresholds (defaults: warning at 500, critical at 1000). Returns OK/WARN/CRIT/UNKNOWN based on threshold violations or SNMP failures.

#### Parameters
None.

#### States
- **OK**: Thread count is within acceptable bounds.
- **WARN**: Thread count exceeds upper warning threshold or falls below lower warning threshold.
- **CRIT**: Thread count exceeds upper critical threshold or falls below lower critical threshold.
- **UNKNOWN**: SNMP query failed, response malformed, or value not parseable as integer.

#### Metrics
- `cisco_sma_mail_transfer_threads` — total active mail transfer threads (count).

### cisco_sma_message_queue

<a id="check-cisco-sma-message-queue"></a>

*Queue*

#### Overview
This check monitors the message queue health of a Cisco Security Management Appliance (SMA) via SNMP, tracking utilization, queue length, and message age to detect performance degradation or resource exhaustion.

#### What it monitors
- Queue utilization percentage
- Current queue length (number of messages)
- Age of the oldest message in the queue (seconds)
- Availability status (memory state: available, shortage, full)

#### How it works
Uses `snmpget` to fetch four specific OIDs under `.1.3.6.1.4.1.15497.1.1.1`. During discovery, `snmpwalk` verifies the presence of the queue MIB. The check aggregates values and evaluates status based on configurable thresholds: availability status status mapping, and fixed or no-level thresholds for utilization, length, and age. The worst applicable state (CRIT > WARN > OK) is selected.

#### Parameters
None.

#### States
- **OK**: Queue metrics within acceptable thresholds and expected availability status.
- **WARN**: One or more metrics exceed warning thresholds or availability status indicates shortage/memory shortage.
- **CRIT**: Any metric exceeds critical thresholds, availability status indicates full memory, or unknown status mapped to CRIT.
- **UNKNOWN**: Missing data (incomplete SNMP response), invalid availability status code, or discovery fails.

#### Metrics
- `cisco_sma_queue_utilization` — Percentage of memory used by the queue (%)
- `cisco_sma_queue_length` — Total number of messages in the queue (messages)
- `cisco_sma_queue_oldest_message_age` — Time since the oldest message entered the queue (seconds)

### cisco_srst_phones

<a id="check-cisco-srst-phones"></a>

*SRST Phones*

#### Overview
This check monitors the number of Cisco SRST (Single Router Survivable Telephony) phones registered on a Cisco router via SNMP. It matters because SRST provides call processing continuity during WAN outages, and knowing the count helps verify telephony resilience.

#### What it monitors
- Number of registered Cisco SRST phones

#### How it works
In discovery mode, it yields one service item. In check mode, it runs `snmpget` against OID `.1.3.6.1.4.1.9.9.441.1.3.2.0` to fetch the integer count of registered phones. If SNMP fails, output is malformed, or the value is non-integer, it returns UNKNOWN; otherwise, it reports OK with the count.

#### Parameters
None.

#### States
- OK: SNMP query succeeds and yields a valid non-negative integer.
- UNKNOWN: SNMP query fails, output format is unexpected, or the parsed value is not an integer.

#### Metrics
- `registered_phones` — number of phones registered, unit: count.

### cisco_temperature_dom

<a id="check-cisco-temperature-dom"></a>

*DOM %s*

#### Overview
Monitors optical signal power levels in Cisco DOM (Digital Optical Monitoring) sensors, critical for detecting fiber optic transceiver issues such as degradation or failure.

#### What it monitors
- Input signal power (dBm) of DOM sensors
- Output signal power (dBm) of DOM sensors
- Sensor operational status (OK, warning, critical, unknown)

#### How it works
Discovers DOM sensors via `snmpwalk` on OID `.1.3.6.1.4.1.9.9.91.1.1.1.1.14` (type 14 = dBm) in discovery mode. For check mode, it retrieves the current signal power reading (divided by 10) and status via `snmpget`. Status mapping: 1→OK, 2→UNKNOWN, 3→CRIT/WARN (based on thresholds). Compares readings against optional power thresholds (`power_levels_upper`, `power_levels_lower`) to determine WARN/CRIT states.

#### Parameters
`power_levels_upper` (list of 2 floats, None) — [warning, critical] upper thresholds (dBm)
`power_levels_lower` (list of 2 floats, None) — [warning, critical] lower thresholds (dBm)

#### States
- **OK**: Reading within thresholds, status value 1
- **WARN**: Reading exceeds upper or below lower warning threshold, or status value 3
- **CRIT**: Reading exceeds upper or below lower critical threshold, or status value 2
- **UNKNOWN**: Sensor not found, status value 2 or invalid

#### Metrics
- `input_signal_power_dbm` — Measured input optical power in dBm
- `output_signal_power_dbm` — Measured output optical power in dBm
- `signal_power_dbm` — Generic signal power metric (fallback)

### citrix_controller

<a id="check-citrix-controller"></a>

*Citrix Controller State*

#### Overview
Monitors the state and health of a Citrix Controller, including controller operation, licensing, session counts, registered desktops, and active site services, ensuring the Citrix infrastructure is functioning correctly.

#### What it monitors
- Controller operational state (Active/Inactive/Error)
- Licensing server and grace period states
- Active and inactive user sessions
- Registered desktops count
- Active site services status

#### How it works
Fetches data via `cmk inventory --data-source citrix_controller`, which returns JSON. In discovery mode, it generates services for each monitored component (controller state, licensing, sessions, desktops, site services). In check mode, it evaluates each service separately based on the item name, applying state mappings and optional thresholds for sessions and desktops.

#### Parameters
None.

#### States
- OK: Controller active, licensing OK, sessions within thresholds, desktops present, site services active
- WARN: Licensing in grace period, sessions exceed warn thresholds, desktops below lower warn threshold
- CRIT: Controller error, licensing critical (expired, not installed), sessions exceed crit thresholds, desktops below crit thresholds
- UNKNOWN: Data missing, unsupported state, or unknown item

#### Metrics
- `total_sessions` — total active + inactive sessions
- `active_sessions` — currently active user sessions
- `inactive_sessions` — currently inactive user sessions
- `registered_desktops` — number of registered desktops

### citrix_controller_licensing

<a id="check-citrix-controller-licensing"></a>

*Citrix Controller Licensing*

#### Overview
Monitors the licensing status of a Citrix Controller to ensure proper license validation and server connectivity, preventing service disruptions due to licensing issues.

#### What it monitors
- Licensing Server State (e.g., connection status, license validity, compatibility)
- Licensing Grace State (e.g., active grace periods, expiration status)

#### How it works
The check runs `cmk-agent-ctl show-data citrix_controller` to fetch licensing data, parses key-value lines for `LicensingServerState` and `LicensingGraceState`, then maps each state string to an OK/WARN/CRIT level using predefined lookup tables. The highest severity among both states determines the overall check state. Discovery is supported for a single service (`item: ""`).

#### Parameters
None.

#### States
- **OK**: Both states are OK (e.g., server OK, grace not active).
- **WARN**: One state is WARN (e.g., server not connected, or grace in OOB/supplemental period).
- **CRIT**: Any CRIT state (e.g., license expired, server failed, grace period expired).
- **UNKNOWN**: Data retrieval fails or state strings are unrecognized.

#### Metrics
None.

### citrix_controller_registered

<a id="check-citrix-controller-registered"></a>

*Citrix Desktops Registered*

#### Overview
Monitors the number of registered Citrix Desktops to ensure the Citrix environment is operating with the expected number of active user sessions.

#### What it monitors
- Number of desktops currently registered with the Citrix controller.

#### How it works
The check retrieves data by invoking `cmk -d localhost` (with JSON or raw fallback). In discovery mode, it finds a single item (no per-item services). In check mode, it parses the `DesktopsRegistered` value from the Citrix section or raw output. State is determined by comparing the count against optional upper/lower warning/critical thresholds.

#### Parameters
None.

#### States
- **OK**: Desktop count is within normal range (no threshold violations).
- **WARN**: Count meets or exceeds an upper warning threshold, or falls below a lower warning threshold.
- **CRIT**: Count meets or exceeds an upper critical threshold, or falls below a lower critical threshold.
- **UNKNOWN**: Desktop count could not be determined (data missing or malformed).

#### Metrics
- `registered_desktops` — number of currently registered desktops (unit: count).

### citrix_controller_services

<a id="check-citrix-controller-services"></a>

*Citrix Active Site Services*

#### Overview
Monitors the Citrix Virtual Apps and Desktops controller’s active site services status to ensure the site is properly configured and operational.

#### What it monitors
- Presence and value of the `ActiveSiteServices` field in `/opt/citrix/agent/state`
- Whether the Citrix controller has an active site service configured (e.g., "Controller" or empty/unset)

#### How it works
The check reads `/opt/citrix/agent/state`, parses it line-by-line for the `ActiveSiteServices` key, and extracts its value. During discovery (`_discover=True`), it emits a single item with empty label if the field exists; otherwise, no items. In check mode, it returns OK with a message containing the service name if found, or "No services" if missing.

#### Parameters
None.

#### States
- **OK**: When `ActiveSiteServices` is present in the file (even if value is empty).
- **CRIT/UNKNOWN**: Not explicitly defined—always returns OK in current logic; no error path for missing key or parse failure.

#### Metrics
None.

### citrix_controller_sessions

<a id="check-citrix-controller-sessions"></a>

*Citrix Total Sessions*

#### Overview
Monitors Citrix XenApp/XenDesktop session counts (total, active, inactive) by reading data from the Citrix controller agent to ensure the infrastructure is operating within expected capacity.

#### What it monitors
- Total number of sessions (active + inactive)
- Number of active sessions
- Number of inactive sessions

#### How it works
Reads the Citrix controller data from `/var/lib/check_mk_agent/spool/citrix_controller` (or falls back to `check_mk_agent` output), parses `TotalFarmActiveSessions` and `TotalFarmInactiveSessions` lines. In discovery mode, it yields a single service item. In check mode (item `""`), compares session counts against optional thresholds (`total`, `active`, `inactive`), using only upper bounds (level[1]) for WARN/CRIT decisions.

#### Parameters
- `total` (list or tuple, None) — warning/critical thresholds for total sessions (upper bound only).
- `active` (list or tuple, None) — warning/critical thresholds for active sessions (upper bound only).
- `inactive` (list or tuple, None) — warning/critical thresholds for inactive sessions (upper bound only).

#### States
- OK: Session counts below all specified thresholds.
- WARN: Any session count meets or exceeds its specified warning threshold (but not critical).
- CRIT: Any session count meets or exceeds its specified critical threshold.
- UNKNOWN: No session data available, or an item other than `""` is provided.

#### Metrics
- `total_sessions` — total number of sessions (active + inactive), unit: sessions
- `active_sessions` — number of active sessions, unit: sessions
- `inactive_sessions` — number of inactive sessions, unit: sessions

### cmctc_lcp_position

<a id="check-cmctc-lcp-position"></a>

*Position %s*

#### Overview
Monitors the position of LCP (Liquid Cooling Panel) sensors in a Liebert CMC-T device via SNMP. Ensures cooling system components (e.g., valves, dampers) are operating within expected positional ranges to maintain proper thermal management.

#### What it monitors
- Position values of sensors identified as type "position" (OID type ID 32) from the cmcTcUnit1–4OutputTable
- Sensor status (e.g., ok, warning, error)
- Device-specified low/high limits for position
- Descriptive labels for each sensor

#### How it works
Discovers position sensors by querying SNMP OIDs `.1.3.6.1.4.1.2606.4.2.{3-6}.5.2.1.{1-8}` on localhost. In check mode, it matches the requested `item` to a discovered sensor, fetches its reading, limits, and status. Compares the reading against both device-defined limits and check parameters (if provided). The final state is the more severe of sensor-reported state or deviation from thresholds.

#### Parameters
None.

#### States
- OK: Sensor status is "ok"/"on"/"changed", and reading is within device limits and thresholds.
- WARN: Sensor status is "warning", or reading exceeds warning threshold (but not critical limit).
- CRIT: Sensor status is "too low"/"too high"/"error"/"off"/"lost", or reading breaches critical (high/low) limits.
- UNKNOWN: Item not found, or status unrecognized.

#### Metrics
`position` — current position value (unitless, as read from SNMP; interpreted as % based on sensor type).

### cmctc_lcp_regulator

<a id="check-cmctc-lcp-regulator"></a>

*Regulator %s*

#### Overview
Monitors CMC TPC LCP regulator sensors via SNMP, reporting their operational state and percentage values for critical infrastructure components like blowers or water/air flow regulators.

#### What it monitors
- Regulator percentage values (e.g., blower speed, water flow regulation)
- Sensor status (ok, warning, error, etc.)
- Associated description, reading, thresholds (warning/critical upper/lower bounds)

#### How it works
Fetches regulator sensor data via SNMP walks on OIDs under `.1.3.6.1.4.1.2606.4.2.{3-6}`. Discovers items matching `typeid=62` (regulator) and constructs items with optional prefixed name and tree.index. For a given item, reads reading, status, and thresholds; compares reading against warning/critical upper thresholds, and lower thresholds if specified; maps status code to state (ok/warn/crit/unknown) and returns combined summary.

#### Parameters
None.

#### States
- OK: Sensor status is "ok" (code 4/6), and reading is within (lower, upper) bounds.
- WARN: Sensor status is "changed" (code 3) or "warning" (code 7), or reading meets or exceeds warning threshold.
- CRIT: Sensor status indicates error/lost/too low/too high/off (codes 2,5,8,9,10), or reading exceeds critical thresholds.
- UNKNOWN: Sensor status is unknown/unavailable (codes 1), or item not found.

#### Metrics
- `regulator` — Current regulator setting or reading value, unit: %.

### cmctc_lcp_user

<a id="check-cmctc-lcp-user"></a>

*User Sensor %s*

#### Overview
This check monitors user sensors on CMC-T (Computerized Monitoring Controller) devices via SNMP, reporting sensor status and readings for user-defined analog inputs. It matters because user sensors often monitor critical environmental or operational conditions (e.g., door contacts, liquid levels) in data center infrastructure.

#### What it monitors
- Sensor type ID (must be 13 or 14 for user sensors)
- Sensor status (e.g., ok, warning, too high, error)
- Numeric reading (e.g., voltage, contact state)
- Sensor description

#### How it works
Discovery (`_discover=True`): Walks `.1.3.6.1.4.1.2606.4.2.{3-6}.5.2.1.2` to find sensors with typeid 13/14; creates per-item services. For a specific item (`item="T.IDX"`), it fetches 9 OIDs via `snmpget` including status, reading, thresholds, and description. Verdict is determined by status code mapping and optionally overridden by `warn`/`crit` thresholds if provided.

#### Parameters
None.

#### States
- **OK**: Status is “ok”, “on”, or reading below `warn`/`crit` thresholds.
- **WARN**: Status is “warning”, “too low”, or reading ≥ `warn` but < `crit`.
- **CRIT**: Status is “too high”, “error”, or reading ≥ `crit`.
- **UNKNOWN**: SNMP error, unexpected values, wrong sensor type, or missing item.

#### Metrics
- `user` — raw numeric sensor reading (unitless per source).

### cmctc_output

<a id="check-cmctc-output"></a>

*%s*

#### Overview
This check monitors CMC-T output devices (e.g., relays, locks, fans, sensors) via SNMP, supporting both discovery and per-item status checking for industrial control hardware.

#### What it monitors
- Status of CMC-T output modules (e.g., door locks, fan relays, power outputs)
- Sensor type-specific values (e.g., temperature, current, RPM, voltage)
- Command state (on/off/lock/unlock), configuration (remote control enabled/disabled), delay, and timeout action
- Output description and raw status string

#### How it works
On discovery (`_discover=True`), it runs `snmpwalk` on table OIDs `.1.3.6.1.4.1.2606.4.2.{3,4,5,6}.6.2.1` to enumerate items; each item is named `<sensor_type> <table>.<index>`. In normal mode, it repeats the same SNMP walk, matches the requested item, and maps status (e.g., `"ok"` → OK, `"lost"` → CRIT) and value to Checkmk state, metrics, and details.

#### Parameters
None.

#### States
- **OK**: Sensor status is `"ok"`, `"on"`, `"set off"`, or `"set on"`.
- **WARN**: Status is `"changed"`.
- **CRIT**: Status is `"lost"` or `"off"`.
- **UNKNOWN**: Status is `"not available"` or unmapped.

#### Metrics
- `temp` — Setpoint or measured temperature in °C
- `current` — Current monitoring or output in A
- `rpm` — Fan speed in RPM
- `flow` — Flow rate in l/min
- `voltage` — High/low voltage setpoint in V

### cmctc_state

<a id="check-cmctc-state"></a>

*TC unit state*

#### Overview
Monitors the operational state of a Terrestrial Controller (TC) unit in a DVB-S2 satellite system using SNMP, ensuring the TC is functioning correctly and units are properly connected.

#### What it monitors
- TC unit status (via OID `.1.3.6.1.4.1.2606.4.2.1.0`)
- Number of connected units (via OID `.1.3.6.1.4.1.2606.4.2.2.0`)

#### How it works
Executes `snmpwalk` against localhost using SNMP v2c with community string `public` to query two specific OIDs. Parses the response to extract status code and unit count. Status code `1` maps to `failed`, `2` to `ok`; any other value yields `unknown[N]`. Returns CRIT for non-ok states, OK only if `status == ok`. Single-service discovery is performed with empty item key.

#### Parameters
None.

#### States
- **OK**: TC status code is `2` (ok)
- **CRIT**: TC status code is `1` (failed) or any unrecognized value
- **UNKNOWN**: SNMP command returns no valid data (e.g., missing one or both OID values)

#### Metrics
None.

### cmk_inv

<a id="check-cmk-inv"></a>

#### Overview
This check runs Checkmk’s inventory command (`cmk --inv`) to detect configuration or hardware/software changes on a host. It is used to validate that inventory runs successfully and report when changes are detected that require review.

#### What it monitors
- Inventory execution success/failure (via `cmk` command exit code)
- Hardware changes (`--hw-changes`)
- Software changes (`--sw-changes`)
- Missing software components (`--sw-missing`)
- Network configuration changes (`--nw-changes`)

#### How it works
The check first performs discovery (single item `""`), then runs `cmk --use-indexed-plugins --inv-fail-status=... --hw-changes=... --sw-changes=... --sw-missing=... --nw-changes=... <hostname>`. It interprets the exit code: `0` → OK, `fail_status` → CRIT (changes found), any other non-zero → UNKNOWN.

#### Parameters
`fail_status` (int, 1) — exit code that triggers CRIT state; `hw_changes`, `sw_changes`, `sw_missing`, `nw_changes` (int, all default 0) — thresholds that trigger CRIT for respective change types.

#### States
- OK: Inventory completed with no changes or changes below thresholds (exit code 0).
- CRIT: Inventory found changes that exceed configured thresholds (exit code equals `fail_status`).
- UNKNOWN: Inventory command failed unexpectedly (non-zero exit code ≠ `fail_status`).

#### Metrics
`state` — numeric status (0=OK,1=WARN,2=CRIT,3=UNKNOWN).

### cmk_site_statistics

<a id="check-cmk-site-statistics"></a>

*Site %s statistics*

#### Overview
This check monitors the operational status and health of individual Checkmk sites by parsing their site statistics file. It matters because it provides visibility into the number of hosts and services in each site, enabling operators to detect outages, downtime, or abnormal service states across distributed monitoring infrastructures.

#### What it monitors
- Host states: UP, DOWN, UNREACHABLE, and IN DOWNTIME counts
- Service states: OK, IN DOWNTIME, ON DOWN HOSTS, WARNING, UNKNOWN, and CRITICAL counts

#### How it works
The check reads `/var/lib/check_mk/cmk_site_statistics`, parsing section blocks delimited by `[site_name]` headers. In discovery mode, it enumerates all sites found. In check mode, it validates the requested site exists and extracts host/service counters. It reports UNKNOWN if the site is missing or data is malformed; otherwise, it reports OK with detailed stats.

#### Parameters
None.

#### States
- **OK**: Site data is valid and parsed successfully.
- **UNKNOWN**: Site name not found or data format is invalid (e.g., insufficient fields in host/service stats lines).
- **WARN/CRIT**: Not applicable—this check only returns OK or UNKNOWN.

#### Metrics
- `cmk_hosts_up`, `cmk_hosts_down`, `cmk_hosts_unreachable`, `cmk_hosts_in_downtime` — host count per state
- `cmk_services_ok`, `cmk_services_in_downtime`, `cmk_services_on_down_hosts`, `cmk_services_warning`, `cmk_services_unknown`, `cmk_services_critical` — service count per state

## Database

<a id="check-database"></a>

| Check | Summary |
| --- | --- |
| [couchbase_buckets_cache](#check-couchbase-buckets-cache) | Couchbase Bucket %s Cache |
| [couchbase_buckets_fragmentation](#check-couchbase-buckets-fragmentation) | Couchbase Bucket %s Fragmentation |
| [couchbase_buckets_items](#check-couchbase-buckets-items) | Couchbase Bucket %s Items |
| [couchbase_buckets_mem](#check-couchbase-buckets-mem) | Couchbase Bucket %s Memory |
| [couchbase_buckets_operations](#check-couchbase-buckets-operations) | Couchbase Bucket %s Operations |
| [couchbase_buckets_operations_total](#check-couchbase-buckets-operations-total) | Couchbase Bucket Operations |
| [couchbase_buckets_vbuckets](#check-couchbase-buckets-vbuckets) | Couchbase Bucket %s active vBuckets |
| [couchbase_nodes_cache](#check-couchbase-nodes-cache) | Couchbase %s Cache |

### couchbase_buckets_cache

<a id="check-couchbase-buckets-cache"></a>

*Couchbase Bucket %s Cache*

#### Overview
Monitors the cache miss rate for individual Couchbase buckets to detect performance degradation due to inefficient cache usage.

#### What it monitors
- Per-bucket cache miss rate (`ep_cache_miss_rate`) reported by Couchbase via the checkmk agent.

#### How it works
The check reads cached JSON data from `/var/lib/cmk-agent/agent_output/couchbase_buckets_cache`. In discovery mode, it enumerates buckets that have `ep_cache_miss_rate` data. During normal checks, it evaluates the miss rate for the specified bucket using optional warn/crit thresholds (via `cache_misses` parameter); defaults to no thresholds, reporting OK unless thresholds are exceeded.

#### Parameters
`cache_misses` (dict or list of two numbers, None) — warning and critical thresholds (upper bounds) for cache miss rate.

#### States
- OK: Miss rate below warn threshold (or no thresholds set).
- WARN: Miss rate ≥ warn threshold (if set) and below crit threshold.
- CRIT: Miss rate ≥ crit threshold.
- UNKNOWN: No data available, bucket not found, or missing `ep_cache_miss_rate`.

#### Metrics
- `cache_misses_rate` — current cache miss rate, unit: per second (count/s).

### couchbase_buckets_fragmentation

<a id="check-couchbase-buckets-fragmentation"></a>

*Couchbase Bucket %s Fragmentation*

#### Overview
This check monitors fragmentation levels in Couchbase buckets, which indicates data reorganization inefficiency and can impact performance and storage utilization.

#### What it monitors
- `couch_docs_fragmentation`: percentage of document fragmentation.
- `couch_views_fragmentation`: percentage of view index fragmentation.

#### How it works
Retrieves cached JSON data from `/var/lib/cmk-agent/agent_controller/cache/couchbase_buckets_fragmentation`. During discovery (via `_discover`), it emits per-bucket services for buckets with fragmentation metrics. For a specific bucket (`item`), it evaluates fragmentation percentages against warn/crit thresholds (default 80/90 %), setting state to OK, WARN, or CRIT accordingly.

#### Parameters
None. Thresholds are configurable per metric via `params["docs"]` and `params["views"]`, accepting tuples (warn, crit) or single ints for warn with crit defaulting to 90.

#### States
- **OK**: both fragmentation levels below warn thresholds (or metrics absent).
- **WARN**: at least one level meets or exceeds its warn threshold but not crit.
- **CRIT**: at least one level meets or exceeds its crit threshold.
- **UNKNOWN**: specified bucket not found in cache.

#### Metrics
- `docs_fragmentation` — document fragmentation percentage (%).
- `views_fragmentation` — view index fragmentation percentage (%).

### couchbase_buckets_items

<a id="check-couchbase-buckets-items"></a>

*Couchbase Bucket %s Items*

#### Overview
This check monitors Couchbase bucket item counts and related queue metrics to ensure buckets are performing normally and not accumulating backlogs. It helps detect issues like item overflow, disk queue saturation, or inefficient data persistence.

#### What it monitors
- `curr_items_tot`: Total number of items stored in vBuckets for the bucket.
- `disk_write_queue`: Number of items pending write to disk.
- `ep_bg_fetched`: Count of items fetched from disk (background fetches).
- `ep_diskqueue_fill`: Rate at which the disk queue fills (items/sec).
- `ep_diskqueue_drain`: Rate at which the disk queue drains (items/sec).

#### How it works
Data is read from `/var/lib/checkmk-agent/cache/couchbase_buckets_items`, a JSON-per-line file. In discovery mode (`_discover=true`), it enumerates buckets and determines which metrics are available. In check mode, it selects the specified bucket and reports status/metrics based on present fields. The check returns OK unless no data or the bucket is missing (UNKNOWN). No thresholds are applied—only metric reporting and descriptive status.

#### Parameters
None.

#### States
- **OK**: Bucket found and data successfully parsed.
- **UNKNOWN**: No cache data available or bucket name not found.
- **WARN/CRIT**: Never raised by this check.

#### Metrics
- `items_count` — Total items in vBuckets (unit: count).
- `disk_write_ql` — Items pending disk write (unit: count).
- `fetched_items` — Items fetched from disk (unit: count).
- `disk_fill_rate` — Disk queue fill rate (unit: items/sec).
- `disk_drain_rate` — Disk queue drain rate (unit: items/sec).

### couchbase_buckets_mem

<a id="check-couchbase-buckets-mem"></a>

*Couchbase Bucket %s Memory*

#### Overview
Monitors memory usage of individual Couchbase buckets, tracking absolute and percentage-based memory consumption against configurable thresholds to prevent performance degradation or service disruption.

#### What it monitors
- Memory used by a specific Couchbase bucket (`mem_total - mem_free`)
- Low and high watermark values (`ep_mem_low_wat`, `ep_mem_high_wat`)
- Memory usage level (either absolute bytes or percentage)

#### How it works
Reads bucket memory data from `/var/lib/checkmk-agent/local/couchbase_buckets_mem`. During discovery, it parses JSON lines to build per-bucket services. For a given item (bucket name), it calculates used memory and compares against thresholds: if `levels` is absent or not numeric, uses percentage; otherwise uses absolute bytes. States are determined by critical/warning thresholds on usage.

#### Parameters
`item` (string, required) — Name of the bucket to monitor.
`levels` (list, optional) — Warning/critical thresholds: either `[warn_abs, crit_abs]` or `[warn_pct, crit_pct]`.

#### States
- **OK**: Usage within thresholds.
- **WARN**: Usage meets or exceeds warning threshold.
- **CRIT**: Usage meets or exceeds critical threshold.
- **UNKNOWN**: Bucket not found or memory data missing.

#### Metrics
- `memused_couchbase_bucket` — Memory used (as % if `levels` non-numeric or absent, else bytes).
- `mem_low_wat` — Low watermark (bytes).
- `mem_high_wat` — High watermark (bytes).

### couchbase_buckets_operations

<a id="check-couchbase-buckets-operations"></a>

*Couchbase Bucket %s Operations*

#### Overview
Monitors per-bucket operation rates (total ops, gets, sets, etc.) for Couchbase clusters by parsing a local file, enabling performance and load tracking per bucket or cluster-wide.

#### What it monitors
- Total operations per second (ops)
- Gets (cmd_get) per second
- Sets (cmd_set) per second
- Creates (ep_ops_create) per second
- Updates (ep_ops_update) per second
- Deletes (ep_num_ops_del_meta) per second
Also computes a cluster-wide total (item `""`) by summing all bucket ops.

#### How it works
Reads `/var/lib/checkmk/couchbase_buckets_operations` (JSON-per-line format) to populate a per-bucket section. During discovery, it creates one service per bucket plus a global total service. For each service, it extracts metrics and compares `ops` against optional `ops_warn`/`ops_crit` thresholds to determine state (OK/WARN/CRIT). If the item is not found, state is UNKNOWN.

#### Parameters
None.

#### States
- **OK**: All metrics present; `ops` below thresholds (if configured).
- **WARN**: `ops` ≥ `ops_warn` (if set) but < `ops_crit`.
- **CRIT**: `ops` ≥ `ops_crit` (if set).
- **UNKNOWN**: File unreadable (`rc != 0`) or requested item not found.

#### Metrics
- `op_s` — total operations per second
- `gets` — get operations per second
- `sets` — set operations per second
- `creates` — create operations per second
- `updates` — update operations per second
- `deletes` — delete operations per second

### couchbase_buckets_operations_total

<a id="check-couchbase-buckets-operations-total"></a>

*Couchbase Bucket Operations*

#### Overview
This check monitors the total operation throughput across all Couchbase buckets on a node, aggregating metrics like requests, sets, and deletions to provide a server-level view of database activity. It matters for capacity planning and detecting abnormal load or failures.

#### What it monitors
- Total operations per second (`ops`)
- `cmd_get` (GET request rate)
- `cmd_set` (SET/UPDATE request rate)
- `ep_ops_create` (new item creation rate)
- `ep_ops_update` (update operation rate)
- `ep_num_ops_del_meta` (metadata deletion rate)

#### How it works
Gathers data by running `cat /tmp/couchbase_buckets_operations`, parses JSON lines (one per bucket), and sums numeric fields into a total under key `None`. In discovery mode, it emits a single service for the aggregate total. In check mode, it evaluates `ops` against optional warn/crit thresholds and reports overall state based solely on `ops`.

#### Parameters
None.

#### States
- **OK**: `ops` is below warn/crit thresholds (or thresholds unset) and data is available.
- **WARN**: `ops` ≥ `ops.warn` threshold.
- **CRIT**: `ops` ≥ `ops.crit` threshold.
- **UNKNOWN**: No data available (e.g., missing file or no valid JSON).

#### Metrics
- `op_s` — total operations per second
- `cmd_get` — GET request rate per second
- `cmd_set` — SET request rate per second
- `ep_ops_create` — item creation rate per second
- `ep_ops_update` — update rate per second
- `ep_num_ops_del_meta` — metadata deletion rate per second

### couchbase_buckets_vbuckets

<a id="check-couchbase-buckets-vbuckets"></a>

*Couchbase Bucket %s active vBuckets*

#### Overview
Monitors the active vBucket health of individual Couchbase buckets, focusing on resident items ratio, item memory usage, and pending vBucket counts—key indicators of data distribution and rebalancing activity.

#### What it monitors
- `vb_active_resident_items_ratio`: Percentage of active vBuckets’ items resident in memory.
- `vb_active_itm_memory`: Memory used by active vBucket items.
- `vb_pending_num`: Number of pending vBuckets (during rebalancing or failover).

#### How it works
Reads cached JSON data from `/var/lib/cmk-agent/agent_ctrl/cached/couchbase_buckets_vbuckets`. For discovery (`_discover=true`), it extracts bucket names and available metrics. For single-item checks, it retrieves the specified bucket’s metrics, applies optional warning/critical thresholds per parameter, and sets the state (OK/WARN/CRIT/UNKNOWN) based on threshold violations. UNKNOWN if bucket not found.

#### Parameters
None.

#### States
- **OK**: All metrics within thresholds or thresholds not set.
- **WARN**: Any metric exceeds its warning threshold but not critical.
- **CRIT**: Any metric exceeds its critical threshold.
- **UNKNOWN**: Specified bucket not found in cached data.

#### Metrics
- `resident_items_ratio` — % of resident items in active vBuckets.
- `item_memory` — Memory (bytes) used by active vBucket items.
- `pending_vbuckets` — Count of pending vBuckets.

### couchbase_nodes_cache

<a id="check-couchbase-nodes-cache"></a>

*Couchbase %s Cache*

#### Overview
This check monitors Couchbase node-level cache performance by analyzing hit/miss statistics, helping ensure optimal memory efficiency and query response times.

#### What it monitors
- `get_hits`: number of cache hits (successful reads from cache)
- `ep_bg_fetched`: number of background fetches (cache misses requiring disk I/O)

#### How it works
The check reads cached data from `/var/lib/checkmk-agent/cache/couchbase_nodes_cache`. In discovery mode, it extracts node names and registers per-node services. For monitoring, it computes cache hit ratio and miss rate (misses per second), then compares against user-configurable thresholds for misses and hits to determine state.

#### Parameters
None.

#### States
- **OK**: Miss rate and hit ratio are within acceptable bounds.
- **WARN**: Miss rate ≥ warning threshold *or* hit ratio ≤ warning threshold.
- **CRIT**: Miss rate ≥ critical threshold *or* hit ratio ≤ critical threshold.
- **UNKNOWN**: Node not found, or `get_hits`/`ep_bg_fetched` data missing.

#### Metrics
- `cache_misses_rate` — background fetch count per second (unit: count/s)
- `cache_hit_ratio` — percentage of requests served by cache (unit: %)

## Virtualization & Cloud

<a id="check-virtualization-cloud"></a>

| Check | Summary |
| --- | --- |
| [citrix_hostsystem](#check-citrix-hostsystem) | Citrix Host Info |
| [citrix_hostsystem_vms](#check-citrix-hostsystem-vms) | Citrix VMs |

### citrix_hostsystem

<a id="check-citrix-hostsystem"></a>

*Citrix Host Info*

#### Overview
Monitors the Citrix XenServer/XCP-ng host’s pool membership by extracting the pool name from agent section data, ensuring the host is correctly associated with a Citrix resource pool.

#### What it monitors
- Presence and value of the `CitrixPoolName` field in the Citrix hostsystem agent section.

#### How it works
The check reads the `citrix_hostsystem` agent section from one of two expected file paths (`/var/lib/yolo-man/agent/sections/citrix_hostsystem` or `/tmp/citrix_hostsystem`). In discovery mode, it extracts VM names and pool name to signal services; in check mode, it parses only for the pool name. The check returns OK if a pool name is found, UNKNOWN otherwise. (Note: the VMs portion is handled by a separate `citrix_hostsystem_vms` check.)

#### Parameters
None.

#### States
- **OK**: `CitrixPoolName` is present and non-empty in the agent section.
- **UNKNOWN**: `CitrixPoolName` is missing or empty; agent section not found.
- CRIT/WARN: Not implemented — no warning or critical conditions.

#### Metrics
None.

### citrix_hostsystem_vms

<a id="check-citrix-hostsystem-vms"></a>

*Citrix VMs*

#### Overview
Monitors the number and names of virtual machines managed by a Citrix host system, ensuring VMs are present and reporting them as discovered services for further monitoring.

#### What it monitors
- Presence of the `citrix_hostsystem` agent section (via spool file).
- List of VM names (`VMName` entries).
- Citrix pool name (`CitrixPoolName`), used for context but not decision logic.

#### How it works
The check reads the raw Citrix agent spool file `/var/lib/check_mk_agent/spool/citrix_hostsystem`. It parses `VMName` and `CitrixPoolName` lines, collecting unique VM names. In discovery mode (triggered via `_discover` param), it produces one service item (pool-wide) if any VMs exist. In check mode, it reports OK if VMs are found, with details listing them; returns OK with "No VMs found" if none exist.

#### Parameters
None.

#### States
- **OK**: VMs found (with names in details) or no VMs but no error.
- **UNKNOWN**: Agent section missing or unreadable (`rc != 0`).
- No WARN or CRIT states are implemented.

#### Metrics
None.

## Environment & Power

<a id="check-environment-power"></a>

| Check | Summary |
| --- | --- |
| [akcp_exp_humidity](#check-akcp-exp-humidity) | Humidity %s |
| [akcp_exp_water](#check-akcp-exp-water) | Water %s |
| [apc_humidity](#check-apc-humidity) | Humidity %s |
| [apc_inrow_temp](#check-apc-inrow-temp) | Temperature %s |
| [apc_netbotz_fluid](#check-apc-netbotz-fluid) | Fluid Detector %s |
| [apc_netbotz_sensors](#check-apc-netbotz-sensors) | Temperature %s |
| [apc_netbotz_sensors_dewpoint](#check-apc-netbotz-sensors-dewpoint) | Dew point %s |
| [apc_netbotz_sensors_humidity](#check-apc-netbotz-sensors-humidity) | Humidity %s |
| [apc_netshelterpdu_outlet](#check-apc-netshelterpdu-outlet) | Power Outlet Port %s |
| [bluenet2_powerrail_temp](#check-bluenet2-powerrail-temp) | Temperature %s |
| [bluenet_meter](#check-bluenet-meter) | Powermeter %s |
| [carel_uniflair_cooling](#check-carel-uniflair-cooling) | Carel uniflair cooling |
| [checkpoint_powersupply](#check-checkpoint-powersupply) | Power Supply %s |
| [cmciii_leakage](#check-cmciii-leakage) | %s |
| [cmciii_status](#check-cmciii-status) | %s |
| [cmctc_lcp_access](#check-cmctc-lcp-access) | Access %s |
| [cmctc_lcp_blowergrade](#check-cmctc-lcp-blowergrade) | Blower Grade %s |

### akcp_exp_humidity

<a id="check-akcp-exp-humidity"></a>

*Humidity %s*

#### Overview
Monitors ambient humidity levels from online AKCP EXplore SNMP sensors to ensure environmental conditions remain within safe operating ranges, preventing damage to sensitive equipment.

#### What it monitors
- Humidity percentage from individual sensors
- Sensor status (OK, error, offline)
- Sensor online status

#### How it works
In discovery mode, it performs an SNMP walk on AKCP humidity OID `.1.3.6.1.4.1.3854.2.3.3.1`, collects sensor descriptions, humidity values, and online status, and returns discovered online sensors. In check mode, it locates a specific sensor by description and reads its humidity, status, and online bits. Critical states trigger on offline or error status; humidity thresholds (default: WARN ≥65%, CRIT ≥65%, low WARN ≤35%) determine status.

#### Parameters
`levels` (list of float, `[60.0, 65.0]`) — upper warning and critical thresholds.
`levels_lower` (list of float, `[30.0, 35.0]`) — lower warning and critical thresholds.

#### States
- OK: Sensor online, status OK, humidity between lower and upper thresholds.
- WARN: Humidity exceeds upper warning threshold (≥65% by default) or falls below lower warning (≤35% default).
- CRIT: Sensor offline, sensor error (status 1 or 7), or humidity exceeds upper critical threshold.
- UNKNOWN: Sensor description not found.

#### Metrics
`humidity` — current humidity percentage.

### akcp_exp_water

<a id="check-akcp-exp-water"></a>

*Water %s*

#### Overview
Monitors water leakage sensors connected via SNMP from AKCP Environmental Monitoring units, ensuring early detection of water leaks that could damage equipment or infrastructure.

#### What it monitors
- Water sensor presence and identification (description)
- Sensor operational status (normal, critical, error)
- Sensor online/offline state

#### How it works
Performs an SNMP walk on the AKCP water sensor OID `.1.3.6.1.4.1.3854.2.3.9.1`. During discovery (`_discover=true`), it extracts sensor descriptions and returns them as discovered items. For a single item check, it parses the full SNMP table to find the matching sensor by description and evaluates its status: offline sensors yield CRIT; status codes map to OK/WARN/CRIT states (e.g., "normal" = OK, "high critical" = CRIT). If the sensor isn’t found or SNMP fails, returns UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Sensor online and status is "normal" or "relay off".
- **WARN**: Sensor online but status indicates warning (e.g., low critical).
- **CRIT**: Sensor offline or status indicates critical error (e.g., high critical, relay on, sensor error).
- **UNKNOWN**: Sensor description not found, SNMP command failed, or status code is unrecognized.

#### Metrics
None.

### apc_humidity

<a id="check-apc-humidity"></a>

*Humidity %s*

#### Overview
Monitors ambient humidity levels from APC UPS devices via SNMP, ensuring they remain within safe operational ranges to prevent equipment damage or operational issues.

#### What it monitors
- Relative humidity percentage from APC UPS humidity sensors (OID `.1.3.6.1.4.1.318.1.1.10.4.2.3.1.6`).

#### How it works
Discovers humidity sensors by walking OID `.1.3.6.1.4.1.318.1.1.10.4.2.3.1.3` and extracts indices; for each valid integer value ≥0, it registers a per-index service. In check mode, it queries OID `.1.3.6.1.4.1.318.1.1.10.4.2.3.1.6`, matches the requested `item` index, and compares the humidity value against configurable upper/lower warning/critical thresholds (defaults: 60/65% upper, 40/35% lower).

#### Parameters
None.

#### States
- **OK**: Humidity between lower warning (40%) and upper warning (60%).
- **WARN**: Humidity ≤35% or ≥65%, but not reaching critical thresholds.
- **CRIT**: Humidity ≤35% (crit lower) or ≥65% (crit upper).
- **UNKNOWN**: Sensor index not found or SNMP query fails.

#### Metrics
- `humidity` — measured relative humidity in % (float).

### apc_inrow_temp

<a id="check-apc-inrow-temp"></a>

*Temperature %s*

#### Overview
Monitors temperature sensors on APC InRow cooling units to ensure proper climate control in data centers, preventing equipment overheating and downtime.

#### What it monitors
- Rack Inlet temperature
- Supply Air temperature
- Return Air temperature
- Entering Fluid temperature
- Leaving Fluid temperature

#### How it works
Uses `cmk -d localhost` to fetch JSON data from the agent. In discovery mode, it parses the `apc_inrow_temp` section, maps indices to named sensors, and creates per-item services with default thresholds [30.0, 35.0] (WARN, CRIT). In check mode, it retrieves the specific sensor’s value (divided by 10), compares it to user-defined or default thresholds, and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
- `levels` (list, `[30.0, 35.0]`) — upper warning and critical thresholds in °C.

#### States
- **OK**: temperature < warning threshold
- **WARN**: temperature ≥ warning and < critical threshold
- **CRIT**: temperature ≥ critical threshold
- **UNKNOWN**: sensor not found, agent data unavailable, or parse error

#### Metrics
- `temperature` — ambient or fluid temperature reading, in °C

### apc_netbotz_fluid

<a id="check-apc-netbotz-fluid"></a>

*Fluid Detector %s*

#### Overview
Monitors fluid (leak) detection sensors on APC NetBotz appliances via SNMP, ensuring timely detection of hazardous fluid leaks in data centers or server rooms.

#### What it monitors
- Fluid leak sensor states (leak detected, no leak, unknown, or other)
- Sensor identifiers: name, module index, and sensor index

#### How it works
The check performs an SNMP walk on OID `.1.3.6.1.4.1.318.1.1.10.4.7.6.1` to enumerate and read fluid sensor data. During discovery, it extracts sensor names and indices, reporting each as a separate service item. In check mode, it retrieves the state for a specific sensor: state `1` = leak (CRIT), `2` = no leak (OK), `3` = unknown (UNKNOWN), and anything else = UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Sensor reports state `2` ("No leak detected")
- **CRIT**: Sensor reports state `1` ("Leak detected")
- **UNKNOWN**: Sensor reports state `3`, invalid state, or not found; or SNMP walk fails
- **No UNKNOWN case is omitted** — the check only returns UNKNOWN when the sensor is missing or in unknown state.

#### Metrics
None.

### apc_netbotz_sensors

<a id="check-apc-netbotz-sensors"></a>

*Temperature %s*

#### Overview
Monitors temperature, humidity, and dewpoint sensors on APC NetBotz appliances via SNMP, alerting on threshold violations to prevent environmental damage to critical infrastructure.

#### What it monitors
- Temperature readings (°C) from environmental sensors
- Humidity readings (%)
- Dewpoint readings (°C)

#### How it works
The check runs the helper command `apc_netbotz_sensors_json` to fetch parsed JSON data from the NetBotz device. In discovery mode (`_discover=true`), it enumerates all sensors by type and returns service definitions with default thresholds. In check mode, it retrieves the specified sensor's reading and compares it against upper/lower warning/critical levels (defaults: temp 30/35°C upper, 25/20°C lower).

#### Parameters
None.

#### States
- **OK**: Reading within both upper and lower thresholds.
- **WARN**: Reading exceeds warning level (upper or lower).
- **CRIT**: Reading exceeds critical level (upper or lower).
- **UNKNOWN**: Sensor not found or no reading available.

#### Metrics
- `temp` — current temperature reading in °C
- `humidity` — current humidity reading in %
- `dewpoint` — current dewpoint reading in °C

### apc_netbotz_sensors_dewpoint

<a id="check-apc-netbotz-sensors-dewpoint"></a>

*Dew point %s*

#### Overview
Monitors dew point temperature from APC NetBotz environmental sensors, critical for preventing condensation and ensuring optimal server room conditions.

#### What it monitors
- Dew point temperature (°C) from each detected sensor
- Sensor presence, labeling, and plug status (only plugged sensors are monitored)

#### How it works
Uses SNMP walk on the APC NetBotz OID `.1.3.6.1.4.1.5528.100.4.1.3.1` to discover sensors during discovery mode, extracting labels, plug status, and dew point readings (scaled by 1/10). In check mode, it locates the requested sensor by label, fetches its dew point reading, and compares against upper/lower warning/critical thresholds. Discovery yields per-sensor services with default levels `(18.0, 25.0)` and `(-4.0, -6.0)`.

#### Parameters
None.

#### States
- **OK**: Dew point within normal bounds (between lower critical and upper critical thresholds).
- **WARN**: Dew point ≥ upper warning (e.g., 18°C) or ≤ lower warning (e.g., −4°C).
- **CRIT**: Dew point ≥ upper critical (e.g., 25°C) or ≤ lower critical (e.g., −6°C).
- **UNKNOWN**: Sensor not found or not reporting valid data.

#### Metrics
- `dewpoint` — dew point temperature in °C.

### apc_netbotz_sensors_humidity

<a id="check-apc-netbotz-sensors-humidity"></a>

*Humidity %s*

#### Overview
Monitors humidity levels from APC NetBotz environmental sensors to detect potentially hazardous conditions that could damage equipment or affect operational safety.

#### What it monitors
- Humidity percentage readings from each connected humidity sensor
- Sensor presence (via `plugged` status)
- Sensor labels and descriptive names

#### How it works
Performs an SNMP walk (v2c, community `public`) against APC NetBotz humidity sensor OIDs to gather label, reading, plugged status, and value. During discovery, it collects all active sensors (plugged=1, non-empty value) and auto-configures thresholds (60%/65% warn/crit upper, 35%/30% warn/crit lower). In check mode, it retrieves a specific sensor by `item`, calculates humidity as `value/10.0` (v2 format), and evaluates against threshold parameters.

#### Parameters
None.

#### States
- OK: Humidity within normal range (between lower warn and upper warn thresholds)
- WARN: Humidity exceeds upper warn (e.g., ≥60%) or falls below lower warn (e.g., ≤35%)
- CRIT: Humidity exceeds upper crit (≥65%) or falls below lower crit (≤30%)
- UNKNOWN: Sensor not found or SNMP walk fails

#### Metrics
- `humidity` — Current humidity percentage, unit: `%`

### apc_netshelterpdu_outlet

<a id="check-apc-netshelterpdu-outlet"></a>

*Power Outlet Port %s*

#### Overview
Monitors the status (on/off) of individual power outlets on APC NetShelter PDUs to detect unexpected power disruptions or misconfigurations.

#### What it monitors
- Power outlet status (on or off) for each physical outlet on the PDU
- Outlet name and index for identification

#### How it works
The check retrieves outlet data from the yolo-man agent’s `apc_netshelterpdu_outlet` section via `ctx.run`. In discovery mode, it identifies only outlets with status `"2"` (on) for monitoring. In normal mode, it matches the specified `item` (outlet index) to an outlet record, then evaluates its `status`: `"2"` → OK, `"1"` → WARN, anything else → UNKNOWN.

#### Parameters
None.

#### States
- OK: Outlet status is `"2"` (on).
- WARN: Outlet status is `"1"` (off).
- UNKNOWN: Outlet status is neither `"1"` nor `"2"`, or no matching outlet found.

#### Metrics
None.

### bluenet2_powerrail_temp

<a id="check-bluenet2-powerrail-temp"></a>

*Temperature %s*

#### Overview
Monitors the temperature of individual power rail sensors in a BlueNet2 system to detect overheating that could indicate hardware failure or cooling issues.

#### What it monitors
- Temperature readings (in °C) from named power rail temperature sensors.

#### How it works
Discovers sensors by reading `/var/lib/check_mk_agent/spool/bluenet2_powerrail.json` (or the `local` variant) when `_discover` is true; creates per-sensor services with default warning/critical levels of 30.0°C/35.0°C. For active checks, it reads the same file, extracts the named sensor’s reading and status, compares it against user-configurable levels, and returns OK/WARN/CRIT/UNKNOWN accordingly.

#### Parameters
None.

#### States
- OK: temperature is below warning threshold (≤30.0°C by default).
- WARN: temperature ≥ warning threshold but < critical threshold (30.0–34.9°C default).
- CRIT: temperature ≥ critical threshold (≥35.0°C default).
- UNKNOWN: sensor name not found in data.

#### Metrics
- `temp` — temperature value in °C.

### bluenet_meter

<a id="check-bluenet-meter"></a>

*Powermeter %s*

#### Overview
Monitors electrical powermeter data (voltage, current, active power, apparent power) from the BlueNet system. It ensures accurate real-time power consumption reporting for infrastructure health and load analysis.

#### What it monitors
- Voltage (RMS, in volts)
- Current (RMS, in amperes)
- Active power (watts)
- Apparent power (volt-amperes)

#### How it works
In discovery mode, reads `/var/lib/cmk-agent/bluenet_meter.json`, parses each row, and discovers meters where voltage ≠ 0. In check mode, retrieves the row matching the item (meter ID), extracts the four metrics, scales voltage and current by 1/1000, and returns OK with metric values. Returns UNKNOWN if no data or meter not found.

#### Parameters
None.

#### States
- **OK**: Meter found and metrics successfully extracted (voltage ≠ 0).
- **UNKNOWN**: No data file, meter ID not found, or parsing fails (e.g., invalid JSON, missing row). No WARN/CRIT states are implemented.

#### Metrics
- `voltage` — voltage RMS, in volts
- `current` — current RMS, in amperes
- `power` — active power, in watts
- `appower` — apparent power, in volt-amperes

### carel_uniflair_cooling

<a id="check-carel-uniflair-cooling"></a>

*Carel uniflair cooling*

#### Overview
Monitors the cooling system of a Carel Uniflair environmental control unit, ensuring proper operation to protect sensitive equipment from overheating.

#### What it monitors
- Humidity levels from the cooling unit
- (Based on discovery output, only humidity is exposed as a measurable metric)

#### How it works
The check supports item discovery, reporting a single service item (empty string) with humidity metrics. During normal operation, it attempts to fetch agent output (likely via SNMP or agent JSON section), but the Starlark code provided is heavily commented and does not execute any actual data collection or threshold logic. In practice, it would compare humidity readings against thresholds (not visible in the fragment) to determine status. Discovery uses `ctx.run(...)` calls intended to retrieve agent output, but due to the placeholder implementation, no real data is gathered in this snippet.

#### Parameters
None.

#### States
- OK: Humidity within acceptable range (not implemented in the provided source).
- WARN: Humidity exceeds warning threshold (not implemented in the provided source).
- CRIT: Humidity exceeds critical threshold (not implemented in the provided source).
- UNKNOWN: Agent data unavailable or parsing failed (not implemented in the provided source).

#### Metrics
- `humidity` — relative humidity measured as a percentage (%).

### checkpoint_powersupply

<a id="check-checkpoint-powersupply"></a>

*Power Supply %s*

#### Overview
Monitors the operational status of power supplies on a host via SNMP, using Check Point’s MIB (.1.3.6.1.4.1.2620). Ensures redundancy and availability by detecting failed or degraded PSUs.

#### What it monitors
- Power supply unit (PSU) presence and status (e.g., “ok”, “failed”, “absent”)
- Status mapping via SNMP string values (e.g., “Power Supply OK”, “Power Supply Failed”)

#### How it works
In discovery mode, it runs `snmpwalk` on `.1.3.6.1.4.1.2620.1.6.7.9.1.1` to enumerate PSUs by OID index and infer params (default: 0=up, 0=ok, 2=present, 1=no_redundancy). For each item, it performs a targeted `snmpwalk` on the item-specific OID, parses the first status string, maps it to a CMK state (OK/WARN/CRIT) using per-status thresholds in `params`, and defaults to CRIT if unmapped.

#### Parameters
None.

#### States
- **OK**: Status maps to `up`, `ok`, `present`, or a `params`-defined 0 state.
- **WARN**: Status maps to `no_redundancy` or any `params`-defined 1 state.
- **CRIT**: Status maps to unmapped status (default), `failed`, or any `params`-defined 2 state.
- **UNKNOWN**: SNMP query fails, returns empty/invalid data.

#### Metrics
None.

### cmciii_leakage

<a id="check-cmciii-leakage"></a>

*%s*

#### Overview
Monitors leakage sensors connected to the CMCIII (CRITICOMM III) environmental monitoring system, reporting sensor status (e.g., alarm, OK) to detect physical leaks (e.g., water, gas) in data centers or critical infrastructure.

#### What it monitors
- Status of individual leakage sensors (e.g., OK, alarm, probe open, not available)
- Sensor delay value (time before alarm triggers after detection)
- Sensor identification via item key or description-based name

#### How it works
In discovery mode, the check runs `cmk --agent --no-cache --output-format=json`, parses the `cmciii.leakage` JSON section, and creates per-sensor items. In check mode, it fetches the same agent output, looks up the sensor by `_item_key` or fallback `item`, evaluates the `"Status"` field, and returns CRIT if not "OK", else OK. No metrics are emitted.

#### Parameters
None.

#### States
- **OK**: Sensor status is `"OK"`.
- **CRIT**: Sensor status is anything other than `"OK"` (e.g., `"ALARM"`, `"probeOpen"`, `"notAvail"`).
- **UNKNOWN**: Agent fetch fails, `cmciii` or `leakage` section missing, or sensor not found.

#### Metrics
None.

### cmciii_status

<a id="check-cmciii-status"></a>

*%s*

#### Overview
This check monitors the status of CMCIII (Climate Monitoring Controller III) sensors, which are used for environmental monitoring in data centers and server rooms. It ensures critical environmental conditions (e.g., temperature, humidity, power) are reported as OK, providing early warning of environmental failures.

#### What it monitors
- Status of individual CMCIII status sensors (e.g., temperature probes, humidity sensors, door contacts, power failures)
- Sensor operational state (OK vs non-OK)

#### How it works
The check executes `cmk agentctl status` to retrieve JSON output containing CMCIII sensor data. In discovery mode (`_discover`), it enumerates all status sensors, optionally building descriptive item names from location, index, and description fields. In check mode, it retrieves the status of the specified sensor item; if not found or if the status is not "OK", it returns CRIT or UNKNOWN accordingly.

#### Parameters
None.

#### States
- **OK**: Sensor status is "OK".
- **CRIT**: Sensor status is anything other than "OK".
- **UNKNOWN**: No matching sensor found, or CMCIII status section missing from agent output.

#### Metrics
None.

### cmctc_lcp_access

<a id="check-cmctc-lcp-access"></a>

*Access %s*

#### Overview
Monitors access sensors from CMC-TC LCP environmental monitoring devices, reporting their operational status and numeric access readings. Critical for detecting unauthorized or anomalous access events in server rooms or data centers.

#### What it monitors
- Access sensor status (OK, WARN, CRIT, UNKNOWN)
- Numeric access value (integer reading)
- Sensor description (if available)

#### How it works
Gathers data from `/var/lib/check_mk_agent/spool/cmctc_lcp.json` (or fallback to `/tmp/cmctc_lcp.json`). In discovery mode, it scans entries where `typeid == "4"` under trees "3"–"6", creating per-item services using description + index or raw index. For checks, it retrieves the specific item’s status and value, maps status codes to states (e.g., `"4"` → OK), and reports state and reading.

#### Parameters
None.

#### States
- **OK**: Status code `"4"` or `"6"` (normal operation)
- **WARN**: Status codes `"3"` or `"7"`
- **CRIT**: Status codes `"2"`, `"5"`, `"8"`, `"9"`, or `"10"`
- **UNKNOWN**: Status `"1"` or if sensor/data not found

#### Metrics
- `access` — numeric access value from the sensor (integer, unitless)

### cmctc_lcp_blowergrade

<a id="check-cmctc-lcp-blowergrade"></a>

*Blower Grade %s*

#### Overview
This check monitors the blower grade percentage of CMC-TCP/LCP environmental monitoring units, which indicates the speed or performance level of cooling blowers in server rooms or data centers.

#### What it monitors
- Blower grade percentage (a normalized value representing blower speed or performance)
- Sensor status (e.g., ok, warning, too high/low, error)
- Sensor description and numeric reading

#### How it works
Uses SNMP to walk a set of OIDs related to CMC-TCP/LCP sensors. During discovery (`_discover` mode), it parses sensor data and identifies items of type "blowergrade" (typeid 61). For monitoring, it fetches the current values for the specified item, extracts the reading (float), thresholds (warn, high, low), and status code, then maps the status and thresholds to OK/WARN/CRIT states.

#### Parameters
None.

#### States
- OK: Sensor status is "ok" or "on" and reading is within thresholds.
- WARN: Sensor status is "warning" or reading exceeds warning threshold (but not critical).
- CRIT: Sensor status is "too low", "too high", "error", "lost", or reading exceeds upper/lower critical thresholds.
- UNKNOWN: Sensor not found, wrong type, or status is "not available", "changed", or unmapped.

#### Metrics
- `blowergrade` — current blower grade percentage (unitless, float).

## Security

<a id="check-security"></a>

| Check | Summary |
| --- | --- |
| [acme_certificates](#check-acme-certificates) | Certificate %s |
| [cert](#check-cert) |  |
| [checkpoint_firewall](#check-checkpoint-firewall) | Firewall Module |

### acme_certificates

<a id="check-acme-certificates"></a>

*Certificate %s*

#### Overview
Monitors expiration time of ACME certificates via SNMP, alerting when certificates are approaching or past their expiry thresholds to prevent service disruptions from expired TLS/SSL credentials.

#### What it monitors
- Certificate names, start dates, expiry dates, and issuers retrieved via SNMP from devices supporting the Altova/RedSeal ACME MIB (OID `.1.3.6.1.4.1.9148.3.9.1.10.1`).
- Time remaining until each certificate expires, in seconds.

#### How it works
In discovery mode, it walks the certificate name OID to enumerate items per certificate. In check mode, it queries four related OIDs to reconstruct full certificate data per item, parses the expiry timestamp manually (no `strptime`), computes remaining time against current system time (via `date +%s`), and compares to configurable warn/crit thresholds. Returns per-certificate states with human-readable expiry duration.

#### Parameters
None. Thresholds are hard-coded per item as `["fixed", 604800.0, 2592000.0]` (7 days warn, 30 days crit).

#### States
OK — certificate expires in more than 30 days; WARN — expires in 7–30 days; CRIT — expires in ≤7 days or already expired; UNKNOWN — certificate name not found or date parsing fails.

#### Metrics
certificate_expiration_time — seconds until certificate expiry (integer).

### cert

<a id="check-cert"></a>

#### Overview
Monitors the validity and expiration of TLS/SSL certificates on a target host and port by invoking the `check_cert` plugin. This is critical for preventing service outages and security vulnerabilities caused by expired certificates.

#### What it monitors
- TLS certificate validity period (days until expiration)
- Certificate response time (seconds)

#### How it works
Runs the `check_cert` binary (e.g., `/usr/lib/yolo-man/plugins/check_cert`) with `--hostname localhost --port 443 --not-after 30 7` (warn at ≤30 days, crit at ≤7 days). Discovery mode yields one service item (empty string). Output parsing extracts state (OK/WARN/CRIT/UNKNOWN) from the first line and metrics (`response_time`, `validity_days`) from the perfdata line.

#### Parameters
None.

#### States
- **OK**: Certificate valid for >30 days.
- **WARN**: Certificate expires in ≤30 but >7 days.
- **CRIT**: Certificate expires in ≤7 days or is invalid/expired.
- **UNKNOWN**: Plugin error, no output, or unparseable state.

#### Metrics
- `response_time` — SSL/TLS handshake latency in seconds.
- `validity_days` — days until certificate expiration.

### checkpoint_firewall

<a id="check-checkpoint-firewall"></a>

*Firewall Module*

#### Overview
Monitors the operational state of a Check Point firewall device via SNMP, ensuring the firewall software is properly installed and active on the host.

#### What it monitors
- Firewall installation state (`installed` vs other states)
- Firewall filter name and activation date
- Firmware version (major/minor)
- SNMP-based status indicators for Check Point appliances

#### How it works
In discovery mode, it probes OID `.1.3.6.1.4.1.2620.1.1.1` using `snmpget` to detect the presence of the firewall section. In check mode, it performs an `snmpwalk` on `.1.3.6.1.4.1.2620.1.1` to collect multiple OIDs, parses the output to extract state, filter info, and version, and reports `OK` only if the state is `installed`; all other states are `CRIT`.

#### Parameters
None.

#### States
- **OK**: Firewall state is `installed`
- **CRIT**: Firewall state is anything other than `installed`
- **UNKNOWN**: SNMP walk fails or required data fields are missing

#### Metrics
None.

## Other

<a id="check-other"></a>

| Check | Summary |
| --- | --- |
| [ad_replication](#check-ad-replication) | AD Replication %s |
| [aix_hacmp_nodes](#check-aix-hacmp-nodes) | HACMP Node %s |
| [akcp_exp_smoke](#check-akcp-exp-smoke) | Smoke %s |
| [apc_inrow_system_events](#check-apc-inrow-system-events) | System events |
| [apc_netbotz_drycontact](#check-apc-netbotz-drycontact) | DryContact %s |
| [arbor_peakflow_tms_host_fault](#check-arbor-peakflow-tms-host-fault) | Host Fault |
| [aruba_wlc_aps](#check-aruba-wlc-aps) | AP %s |
| [azure_status](#check-azure-status) | Azure Status %s |
| [ceph_status_mgrs](#check-ceph-status-mgrs) | Ceph MGRs |
| [checkmk_agent](#check-checkmk-agent) | Check_MK Agent |
| [checkmk_local](#check-checkmk-local) | Run a Checkmk local check script (multi-service) |
| [checkpoint_svn_status](#check-checkpoint-svn-status) | SVN Status |
| [cmciii_psm_plugs](#check-cmciii-psm-plugs) | %s |
| [cmctc_lcp_status](#check-cmctc-lcp-status) | Status %s |
| [nagios_plugin](#check-nagios-plugin) | Run any Nagios-compatible plugin / Checkmk local check |

### ad_replication

<a id="check-ad-replication"></a>

*AD Replication %s*

#### Overview
Monitors Active Directory replication health by tracking replication failures between domain controllers and sites, ensuring timely synchronization of directory data across the forest.

#### What it monitors
- Number of consecutive replication failures per replication partner (source site/domain controller).
- Timestamps of last successful and last failed replication attempts.
- Replication status codes and naming contexts (e.g., DomainDNSZones, Schema) involved.

#### How it works
Discovers replication pairs (`site/dc`) from agent data (`ad_replication` section) and creates per-item services. For each item, it parses `showrepl_INFO` lines, checks failure counts against thresholds (default: warn ≥15, crit ≥20), and compares failure/success timestamps—if the last failure occurred after the last success, it triggers CRIT. Discovery enumerates unique replication partners; check mode evaluates one specific partner.

#### Parameters
`failure_levels` (list of int, `[15, 20]`) — failure count thresholds for WARN and CRIT states.

#### States
OK — no failures detected and last failure not after last success.
WARN — failure count exceeds WARN threshold but not CRIT, or other non-fatal issues.
CRIT — failure count exceeds CRIT threshold, or last failure timestamp is after last success.
UNKNOWN — requested replication pair not found.

#### Metrics
None.

### aix_hacmp_nodes

<a id="check-aix-hacmp-nodes"></a>

*HACMP Node %s*

#### Overview
Monitors HACMP (High Availability Cluster Multi-Processing) cluster node configuration on AIX systems, ensuring nodes and their network interfaces are properly defined for high-availability operations.

#### What it monitors
- HACMP cluster node names discovered via `lsrdev -c cl`
- For a specific node: network interface names, attributes, and IP addresses associated with each network

#### How it works
Discovery mode (`_discover=1`) runs `lsrdev -c cl`, parses output to extract cluster node names, and creates per-node services. In check mode, it runs the same command, filters output for the specified `item` (node name), and extracts network interface details. Returns UNKNOWN if the node is not found; otherwise returns OK with interface details in the message.

#### Parameters
None.

#### States
- OK: Node exists; interface information retrieved successfully.
- UNKNOWN: Node name provided as `item` not found in `lsrdev -c cl` output.
- CRIT/WARN: Not applicable — the check never sets those states.

#### Metrics
None.

### akcp_exp_smoke

<a id="check-akcp-exp-smoke"></a>

*Smoke %s*

#### Overview
This check is intended to monitor smoke detection levels in AKCP environmental devices but cannot operate in the yolo-man runtime due to lack of SNMP or agent data access.

#### What it monitors
- Smoke detection levels (per device/item), though no actual data is gathered due to runtime limitations.

#### How it works
In discovery mode, it checks host facts (os_family, distribution, hostname, architecture) but returns an empty discovery list because SNMP is unsupported. In check mode, it expects an item but cannot retrieve SNMP or agent data via `ctx.*` (no such APIs exist in yolo-man), so it always returns UNKNOWN with an explanatory message.

#### Parameters
None.

#### States
- UNKNOWN: Always, due to SNMP/agent data unavailability in the yolo-man runtime.

#### Metrics
None.

### apc_inrow_system_events

<a id="check-apc-inrow-system-events"></a>

*System events*

#### Overview
This check monitors system events from APC InRow cooling units via SNMP, alerting on active events to ensure proper environmental control in data centers.

#### What it monitors
- Active system events reported by the APC InRow unit (e.g., alarms, warnings, maintenance notices)

#### How it works
It performs an SNMP walk on OID `1.3.6.1.4.1.318.1.1.13.3.1.2.1.3` to retrieve event descriptions. In discovery mode (`_discover: true`), it checks for any events and yields a single service item if present. In check mode, it parses the first event and maps a configurable `state` parameter (default 2) to an OK/WARN/CRIT/UNKNOWN state. If no events exist, it returns OK.

#### Parameters
- `state` (int, 2) — SNMP event severity level to treat as critical; values 0–3 map to OK, WARN, CRIT, UNKNOWN.

#### States
- **OK**: No events found.
- **WARN/CRIT/UNKNOWN**: One or more events exist; severity determined by `state` parameter mapping.
- **UNKNOWN**: Invalid `state` value or parsing failure.

#### Metrics
None.

### apc_netbotz_drycontact

<a id="check-apc-netbotz-drycontact"></a>

*DryContact %s*

#### Overview
This check monitors dry contact sensors on APC NetBotz devices, but due to Starlark runtime limitations, it cannot perform actual SNMP-based monitoring and defaults to reporting UNKNOWN.

#### What it monitors
- Dry contact sensor name, location, current state, normal state, and abnormal severity from APC NetBotz devices via SNMP.

#### How it works
In discovery mode (`_discover=True`), the check attempts to walk SNMP OIDs for dry contact properties but cannot due to lack of SNMP support, returning 0 discovered items. In check mode, it always returns UNKNOWN with an explanatory message because the Starlark runtime lacks SNMP and agent section access.

#### Parameters
None.

#### States
- **OK**: Never reported (no valid data path).
- **WARN**: Never reported.
- **CRIT**: Never reported.
- **UNKNOWN**: Reported for all items when not in discovery, and discovery always yields 0 items.

#### Metrics
None.

### arbor_peakflow_tms_host_fault

<a id="check-arbor-peakflow-tms-host-fault"></a>

*Host Fault*

#### Overview
This check monitors the host fault status of an Arbor Peakflow TMS device. A non-OK fault string indicates a potential hardware or firmware issue requiring attention.

#### What it monitors
- Host fault status string returned by the device (e.g., "No Fault" or an error description).

#### How it works
In discovery mode, it yields a single service with an empty item (single-service check). In check mode, it reads the host fault string from `/tmp/host_fault` (simulating agent output that would normally be collected via SNMP by the yolo-man agent). If the file is missing, it returns UNKNOWN. If the string is exactly "No Fault", the state is OK; otherwise, it is CRIT.

#### Parameters
None.

#### States
- **OK**: When the host fault string is "No Fault".
- **CRIT**: When the host fault string is anything other than "No Fault".
- **UNKNOWN**: When the host fault data file (`/tmp/host_fault`) is not available.

#### Metrics
None.

### aruba_wlc_aps

<a id="check-aruba-wlc-aps"></a>

*AP %s*

#### Overview
Monitors the operational status of Aruba Wireless LAN Controller (WLC) access points (APs) via SNMP, ensuring critical APs are online and provisioned.

#### What it monitors
- AP name, status (up/down), IP address, group, model, serial number, and system location
- Whether an AP is marked as unprovisioned

#### How it works
Uses `snmpwalk` to fetch AP inventory and status from Aruba WLC via SNMP v2c (community `public`). During discovery (`_discover` mode), it lists APs with status `"1"` (up) and not unprovisioned (`unprovisioned != "1"`). In check mode, it queries the specified AP item and maps status codes: `"1"` → OK, `"2"` → CRIT, else UNKNOWN. WARN is added if the AP is unprovisioned.

#### Parameters
None.

#### States
- **OK**: AP status is `"1"` (up) and provisioned
- **WARN**: AP is provisioned but marked unprovisioned (`unprovisioned == "1"`)
- **CRIT**: AP status is `"2"` (down)
- **UNKNOWN**: AP not found, snmpwalk fails, or status code is neither `"1"` nor `"2"`

#### Metrics
None.

### azure_status

<a id="check-azure-status"></a>

*Azure Status %s*

#### Overview
Monitors Azure service health by checking for active incidents in specific Azure regions, leveraging agent output data. It helps detect regional outages or degraded services that may impact workloads.

#### What it monitors
- Azure service health status for individual regions
- Active incidents (issues) including titles and descriptions
- Overall Azure service link/reference for context

#### How it works
Fetches Azure status data from `/var/lib/check_mk_agent/agent_output`, parses the `<<<azure_status>>>` section (JSON), and either discovers regions (in discovery mode) or evaluates a specific region’s issues (check mode). Returns OK if no issues, WARN if issues exist, and UNKNOWN if the region is not found or data is missing.

#### Parameters
None.

#### States
- **OK**: No issues for the region, optionally with a link to Azure status page.
- **WARN**: One or more active issues for the region.
- **UNKNOWN**: Region not found, or Azure status data is missing/invalid.

#### Metrics
None.

### ceph_status_mgrs

<a id="check-ceph-status-mgrs"></a>

*Ceph MGRs*

#### Overview
This check monitors the rate of change of the Ceph MGR (Manager) daemon epoch to detect anomalies in MGR activity or potential communication issues within the Ceph cluster.

#### What it monitors
- The Ceph MGR daemon epoch value from `mgrmap`
- The rate at which the epoch increases over time (epoch delta per unit time)

#### How it works
The check reads the Ceph status JSON from the yolo-man agent spool (`/var/lib/check_mk_agent/spool/ceph_status`), extracts the current epoch, and computes the average epoch change rate by comparing with the previous epoch and timestamp stored in a state file (`/var/lib/check_mk_agent/state/ceph_status_mgrs_epoch_rate.state`). The verdict (OK/WARN/CRIT) is based on user-configurable thresholds (default: warn at 1.0, crit at 2.0 epochs/min). If the rate exceeds the thresholds, it triggers an alert.

#### Parameters
`epoch` (tuple of floats, default `(1.0, 2.0, 5)`) — controls warning and critical thresholds (min rate and max rate) and the averaging interval in minutes (currently hardcoded as 5 min).

#### States
- **OK**: Epoch rate is below warning threshold.
- **WARN**: Epoch rate meets or exceeds warning threshold but below critical.
- **CRIT**: Epoch rate meets or exceeds critical threshold.
- **UNKNOWN**: Spool file missing, empty, or epoch data unavailable.

#### Metrics
- `epoch_rate` — average MGR epoch change rate, in epochs per minute.

### checkmk_agent

<a id="check-checkmk-agent"></a>

*Check_MK Agent*

#### Overview
This check monitors the health and configuration of the yolo-man agent running on a host by fetching and analyzing agent-provided data via the `cmk -d localhost` command.

#### What it monitors
- yolo-man agent version and compatibility with the site version
- Operating system information
- Allowed IP ranges for agent access
- Agent update errors
- Python plugin execution failures
- Agent encryption status
- Number of installed agent plugins and local checks

#### How it works
The check runs `cmk -d localhost` to retrieve agent data in JSON format. It parses the output to extract key sections: `check_mk`, `yolo-man_agent_plugins`, `cmk_agent_ctl_status`, `cmk_update_agent_status`, and `yolo-man_cached_plugins`. It evaluates various conditions (version mismatch, update errors, encryption panic, etc.) to determine the state: OK, WARN, or CRIT. Discovery mode returns a single empty-item service.

#### Parameters
None.

#### States
- **OK**: Agent data retrieved, version matches (or missing), no errors or warnings.
- **WARN**: Agent version mismatch, update error, Python plugin failure, or no allowed IPs configured (but `allowed_ips` check only appends details).
- **CRIT**: Encryption panic detected (encryption setup failed).
- **UNKNOWN**: Agent data retrieval fails (`cmk -d localhost` non-zero exit).

#### Metrics
None.

### checkmk_local

<a id="check-checkmk-local"></a>

*Run a Checkmk local check script (multi-service)*

#### Overview
Runs a yolo-man local check script that outputs one line per service with embedded status, item, performance data, and details; this allows custom monitoring logic via external scripts.

#### What it monitors
- Status code (OK/WARN/CRIT/UNKNOWN) returned per service line
- Item name (service identifier)
- Performance data (metrics like counters, thresholds)
- Free-text details message

#### How it works
Executes the configured `command` (argv list) as a non-mutating command. On discovery (`_discover`), it parses stdout into `<status> <item> <perfdata> <details>` lines and yields one item per line. In check mode, it matches the specified `item` (or empty for first/single-line scripts), extracts status, metrics, and details. Parsing handles quoted items, numeric metric extraction, and maps status tokens to yolo-man states.

#### Parameters
- `command` (list, required) — The local check script and arguments to execute.
- `item` (str, optional, default "") — Which discovered service line to evaluate; empty evaluates the first (or only) item.

#### States
- OK — Script output line starts with `0`
- WARN — Script output line starts with `1`
- CRIT — Script output line starts with `2`
- UNKNOWN — Script output line starts with `3`, `P`, or invalid/parsing failure; also if `item` not found or `command` invalid

#### Metrics
- `name` (value) — Extracted performance data metrics (e.g., `cpu_used=42.5` → metric `cpu_used` with value `42.5`)

### checkpoint_svn_status

<a id="check-checkpoint-svn-status"></a>

*SVN Status*

#### Overview
This check is intended to monitor the status of Check Point SecureVPN (SVN) on network devices, but due to limitations in the Starlark runtime (no SNMP access or agent section parsing), it cannot retrieve real data and defaults to UNKNOWN.

#### What it monitors
- Check Point SVN major and minor software versions
- SVN status code (e.g., error/non-error)
- SVN status description

#### How it works
In discovery mode, it attempts to yield a single service if SNMP section `checkpoint_svn_status` exists, but returns no services because the Starlark environment lacks access to SNMP data or agent JSON sections. In check mode, it tries to fetch data via `yolo-man-agent`, but since that is not guaranteed and no SNMP tools (e.g., `snmpget`) are available in `ctx.run`, it returns UNKNOWN with an explanatory message.

#### Parameters
None.

#### States
- **OK**: Not possible—no valid data path exists.
- **WARN**: Not possible.
- **CRIT**: Not possible.
- **UNKNOWN**: Returned when SNMP/agent data is unavailable (always, due to environment constraints).

#### Metrics
None.

### cmciii_psm_plugs

<a id="check-cmciii-psm-plugs"></a>

*%s*

#### Overview
This check monitors the operational status of Power Supply Module (PSM) plugs in a server or infrastructure managed by the CMCIII (Eaton) monitoring system. It ensures that power distribution units are functioning correctly, which is critical for system uptime and power redundancy.

#### What it monitors
- Status of individual PSM plugs (e.g., OK, fault, alarm)
- Each plug is uniquely identified by its ID, optionally augmented with location/index/description during discovery

#### How it works
On discovery, the check reads `/var/lib/yolo-man-agent/raw-values/cmciii`, parses JSON to extract `psm_plugs`, and creates one service per plug using configurable naming. At runtime, it verifies the `Status` field of the specific plug’s entry; `Status == "OK"` yields OK, any other value yields CRIT. Absence of agent output or item yields UNKNOWN.

#### Parameters
None.

#### States
- **OK**: Plug status is `"OK"`
- **CRIT**: Plug status is anything other than `"OK"` (e.g., `"Alarm"`, `"Fault"`)
- **UNKNOWN**: Agent file missing, JSON malformed, or item not found in `psm_plugs`

#### Metrics
None.

### cmctc_lcp_status

<a id="check-cmctc-lcp-status"></a>

*Status %s*

#### Overview
This check monitors the status of LCP (Local Control Panel) sensors on a CMC-T III device via SNMP, reporting whether individual status sensors (e.g., temperature, humidity, contact inputs) are healthy or indicate a problem.

#### What it monitors
- Individual sensor status values (e.g., OK, warning, critical, unknown) for LCP status-type sensors.
- Sensor descriptions and readings are implied but not directly emitted in this implementation.

#### How it works
The check attempts SNMP walks for four relevant OID trees (3–6) to enumerate and inspect status sensors. In discovery mode, it currently returns no items due to practical limitations in full SNMP table parsing in Starlark. In check mode, it requires an `item` parameter (sensor index); without it, it returns UNKNOWN. If the item is provided, it tries to retrieve and interpret the sensor status via SNMP, but the current logic lacks robust parsing and returns UNKNOWN if data is unavailable.

#### Parameters
`item` (string, required) — The sensor index to check (e.g., "1", "2"). Required for non-discovery execution.

#### States
- **OK**: Not implemented (no success path in current code).
- **WARN**: Not implemented.
- **CRIT**: Not implemented.
- **UNKNOWN**: Returned if discovery fails, no `item` provided, or sensor data cannot be retrieved/parsed.

#### Metrics
None.

### nagios_plugin

<a id="check-nagios-plugin"></a>

*Run any Nagios-compatible plugin / Checkmk local check*

#### Overview
This check acts as a universal wrapper that executes any Nagios-compatible plugin or Checkmk local check command and interprets its exit code and output to determine the monitoring state.

#### What it monitors
- The exit code and stdout/stderr output of the specified plugin command.
- Performance data embedded in the plugin's output (e.g., load values, disk usage percentages).
- Any metric values extracted from perfdata tokens (numeric values with optional units).

#### How it works
The check runs the configured `command` (argv list) on the host. It interprets Nagios exit codes: 0 → OK, 1 → WARN, 2 → CRIT, others → UNKNOWN. It splits the first line of stdout into status text and perfdata using the `|` separator, then parses perfdata tokens into numeric metrics. Discovery is static: only a single service is created with item `""`.

#### Parameters
`command` (list, required) — The full argv list specifying the plugin executable and its arguments.

#### States
- **OK**: Plugin exits with code 0.
- **WARN**: Plugin exits with code 1.
- **CRIT**: Plugin exits with code 2.
- **UNKNOWN**: Plugin exits with any other code, or no command is configured.

#### Metrics
- `label` (numeric value) — Extracted perfdata labels (e.g., `load1`, `usage`, `temp`) converted to numbers, with UOM and thresholds discarded.

## Uncategorized

<a id="check-uncategorized"></a>

| Check | Summary |
| --- | --- |
| [adva_fsp_if](#check-adva-fsp-if) | Interface %s |
| [akcp_sensor_temp](#check-akcp-sensor-temp) | Temperature %s |
| [alcatel_timetra_chassis](#check-alcatel-timetra-chassis) | Device %s |
| [allnet_ip_sensoric_tension](#check-allnet-ip-sensoric-tension) | Electric Tension %s |
| [apc_ats_status](#check-apc-ats-status) | ATS Status |
| [apc_mod_pdu_modules](#check-apc-mod-pdu-modules) | Module %s |
| [apc_symmetra_input](#check-apc-symmetra-input) | Phase %s |
| [arcserve_backup](#check-arcserve-backup) | Arcserve Backup %s |
| [arris_cmts_mem](#check-arris-cmts-mem) | Memory Module %s |
| [audiocodes_ipgroup](#check-audiocodes-ipgroup) | IP group %s |
| [audiocodes_system_events](#check-audiocodes-system-events) | System events |
| [bgp_peer](#check-bgp-peer) | This is how an Arista BGP SNMP message is constructed: |
| [bluecoat_sensors](#check-bluecoat-sensors) | %s |
| [bluecoat_sensors_temp](#check-bluecoat-sensors-temp) | Temperature %s |
| [bluenet_sensor](#check-bluenet-sensor) | Temperature %s |
| [brocade_fcport](#check-brocade-fcport) | Port %s |
| [brocade_mlx_module_cpu](#check-brocade-mlx-module-cpu) | CPU utilization Module %s |
| [brocade_optical](#check-brocade-optical) | Interface %s Optical |
| [brocade_sfp](#check-brocade-sfp) | SFP %s |
| [brocade_sfp_temp](#check-brocade-sfp-temp) | SFP Temperature %s |
| [brocade_tm](#check-brocade-tm) | TM %s |
| [bvip_fans](#check-bvip-fans) | Fan %s |
| [cadvisor_cpu](#check-cadvisor-cpu) | CPU utilization |
| [cadvisor_if](#check-cadvisor-if) | Interface %s |
| [carel_sensors](#check-carel-sensors) | Temperature %s |
| [casa_power](#check-casa-power) | Power %s |
| [cephdfclass](#check-cephdfclass) | Ceph Class %s |
| [cephstatus](#check-cephstatus) | Ceph %s |
| [checkpoint_ha_problems](#check-checkpoint-ha-problems) | HA Problem %s |
| [checkpoint_vsx_packets](#check-checkpoint-vsx-packets) | VS %s Packets |
| [checkpoint_vsx_traffic](#check-checkpoint-vsx-traffic) | VS %s Traffic |
| [chrony](#check-chrony) | NTP Time |
| [ciena_cpu_util_5171](#check-ciena-cpu-util-5171) | CPU utilization |
| [cifsmounts](#check-cifsmounts) | CIFS mount %s |
| [cisco_ace_rserver](#check-cisco-ace-rserver) | ACE RServer %s |
| [cisco_asa_conn](#check-cisco-asa-conn) | Connection %s |
| [cisco_meraki_org_appliance_uplinks](#check-cisco-meraki-org-appliance-uplinks) | Uplink %s |
| [cisco_meraki_org_device_status](#check-cisco-meraki-org-device-status) | Device Status |
| [cisco_meraki_org_sensor_battery](#check-cisco-meraki-org-sensor-battery) | Cisco Meraki Battery Percentage %s |
| [cisco_meraki_org_sensor_humidity](#check-cisco-meraki-org-sensor-humidity) | Cisco Meraki Humidity Relative Percentage %s |
| [cisco_meraki_org_sensor_temperature](#check-cisco-meraki-org-sensor-temperature) | Cisco Meraki Temperature %s |
| [cisco_meraki_org_switch_ports_statuses](#check-cisco-meraki-org-switch-ports-statuses) | Interface %s |
| [cisco_power](#check-cisco-power) | Power %s |
| [cisco_qos](#check-cisco-qos) | QoS %s |
| [cisco_secure](#check-cisco-secure) | Port Security |
| [cisco_sma_resource_conservation](#check-cisco-sma-resource-conservation) | Resource conservation |
| [cisco_temperature](#check-cisco-temperature) | Temperature %s |
| [cisco_ucs_hdd](#check-cisco-ucs-hdd) | HDD %s |
| [cisco_ucs_mem](#check-cisco-ucs-mem) | Memory %s |
| [cisco_vpn_tunnel](#check-cisco-vpn-tunnel) | VPN Tunnel %s |
| [citrix_licenses](#check-citrix-licenses) | Citrix Licenses %s |
| [citrix_serverload](#check-citrix-serverload) | Citrix Serverload |
| [citrix_sessions](#check-citrix-sessions) | Citrix Sessions |
| [citrix_state](#check-citrix-state) | Citrix Instance State |
| [citrix_state_controller](#check-citrix-state-controller) | Citrix Controller |
| [citrix_state_hosting_server](#check-citrix-state-hosting-server) | Citrix Hosting Server |
| [climaveneta_alarm](#check-climaveneta-alarm) | Alarm Status |
| [climaveneta_fan](#check-climaveneta-fan) | Fan %s |
| [climaveneta_temp](#check-climaveneta-temp) | Temperature %s |
| [cmc_temp](#check-cmc-temp) | Temperature Sensor %s |
| [cmciii](#check-cmciii) | State %s |
| [cmciii_access](#check-cmciii-access) | %s |
| [cmciii_can_current](#check-cmciii-can-current) | %s |
| [cmciii_humidity](#check-cmciii-humidity) | %s |
| [cmciii_lcp_water](#check-cmciii-lcp-water) | Temperature Water LCP %s |
| [cmciii_phase](#check-cmciii-phase) | Input %s |
| [cmciii_psm_current](#check-cmciii-psm-current) | Current %s |
| [cmctc_config](#check-cmctc-config) | TC configuration |
| [cmctc_lcp_flow](#check-cmctc-lcp-flow) | Waterflow %s |
| [cmctc_lcp_humidity](#check-cmctc-lcp-humidity) | Humidity %s |
| [cmctc_temp](#check-cmctc-temp) | Temperature %s |
| [corosync_latency](#check-corosync-latency) | Corosync Latency %s |
| [couchbase_buckets_vbuckets_replica](#check-couchbase-buckets-vbuckets-replica) | Couchbase Bucket %s replica vBuckets |
| [couchbase_nodes_info](#check-couchbase-nodes-info) | Couchbase %s Info |
| [couchbase_nodes_items](#check-couchbase-nodes-items) | Couchbase %s vBucket items |
| [couchbase_nodes_operations](#check-couchbase-nodes-operations) | Couchbase %s Operations |
| [couchbase_nodes_operations_total](#check-couchbase-nodes-operations-total) | Couchbase Total Operations |
| [couchbase_nodes_services](#check-couchbase-nodes-services) | Couchbase %s Services |
| [couchbase_nodes_size_couch_views](#check-couchbase-nodes-size-couch-views) | Couchbase %s Couch Views |
| [couchbase_nodes_size_docs](#check-couchbase-nodes-size-docs) | Couchbase %s Documents |
| [couchbase_nodes_size_spacial_views](#check-couchbase-nodes-size-spacial-views) | Couchbase %s Spacial Views |
| [couchbase_nodes_stats_cpu_util](#check-couchbase-nodes-stats-cpu-util) | Couchbase %s CPU utilization |
| [couchbase_nodes_stats_mem](#check-couchbase-nodes-stats-mem) | Couchbase %s Memory |
| [couchbase_nodes_uptime](#check-couchbase-nodes-uptime) | Couchbase %s Uptime |
| [cpsecure_sessions](#check-cpsecure-sessions) | Number of %s sessions |
| [cpu_loads](#check-cpu-loads) | CPU load |
| [cpu_threads](#check-cpu-threads) | Number of threads |
| [cpu_utilization_os](#check-cpu-utilization-os) | CPU utilization |
| [cups_queues](#check-cups-queues) | CUPS Queue %s |
| [datadog_events](#check-datadog-events) | The main purpose of this plug-in is to ensure the regular execution of the Datadog special agent in |
| [datadog_logs](#check-datadog-logs) | The main purpose of this plug-in is to ensure the regular execution of the Datadog special agent in |
| [datadog_monitors](#check-datadog-monitors) | Datadog Monitor %s |
| [datapower_fan](#check-datapower-fan) | Fan %s |
| [datapower_ldrive](#check-datapower-ldrive) | Logical Drive %s |
| [datapower_pdrive](#check-datapower-pdrive) | Physical Drive %s |
| [datapower_raid_bat](#check-datapower-raid-bat) | Raid Battery %s |
| [datapower_temp](#check-datapower-temp) | Temperature %s |
| [db2_backup](#check-db2-backup) | DB2 Backup %s |
| [db2_bp_hitratios](#check-db2-bp-hitratios) | DB2 BP-Hitratios %s |
| [db2_connections](#check-db2-connections) | DB2 Connections %s |
| [db2_counters](#check-db2-counters) | DB2 Counters %s |
| [db2_logsizes](#check-db2-logsizes) | DB2 Logsize %s |
| [db2_mem](#check-db2-mem) | Memory %s |
| [db2_sort_overflow](#check-db2-sort-overflow) | DB2 Sort Overflow %s |
| [db2_tablespaces](#check-db2-tablespaces) | DB2 Tablespace %s |
| [db2_version](#check-db2-version) | DB2 Instance %s |
| [decru_cpu](#check-decru-cpu) | CPU utilization |
| [decru_fans](#check-decru-fans) | FAN %s |
| [decru_perf](#check-decru-perf) | COUNTER %s |
| [decru_power](#check-decru-power) | POWER %s |
| [decru_temps](#check-decru-temps) | Temperature %s |
| [df](#check-df) | Filesystem %s |
| [df_netapp](#check-df-netapp) | Filesystem %s |
| [df_netscaler](#check-df-netscaler) | Filesystem %s |
| [df_zos](#check-df-zos) | Filesystem %s |
| [didactum_can_sensors_analog](#check-didactum-can-sensors-analog) | Temperature CAN %s |
| [didactum_can_sensors_analog_humidity](#check-didactum-can-sensors-analog-humidity) | Humidity CAN %s |
| [didactum_can_sensors_analog_voltage](#check-didactum-can-sensors-analog-voltage) | Phase CAN %s |
| [didactum_sensors_analog](#check-didactum-sensors-analog) | Temperature %s |
| [didactum_sensors_analog_humidity](#check-didactum-sensors-analog-humidity) | Humidity %s |
| [didactum_sensors_analog_voltage](#check-didactum-sensors-analog-voltage) | Phase %s |
| [didactum_sensors_discrete](#check-didactum-sensors-discrete) | Discrete sensor %s |
| [didactum_sensors_outlet](#check-didactum-sensors-outlet) | Relay %s |
| [disk_io_utilization](#check-disk-io-utilization) | Disk IO Utilization |
| [disk_smb](#check-disk-smb) |  |
| [diskstat](#check-diskstat) | Disk IO %s |
| [diskstat_io](#check-diskstat-io) | Disk IO %s |
| [diskstat_io_director](#check-diskstat-io-director) | Disk IO Director %s |
| [diskstat_io_volumes](#check-diskstat-io-volumes) | Disk IO Volumes %s |
| [dmi_sysinfo](#check-dmi-sysinfo) | DMI Sysinfo |
| [dmraid_ldisks](#check-dmraid-ldisks) | RAID LDisk %s |
| [dmraid_pdisks](#check-dmraid-pdisks) | RAID PDisk %s |
| [dns](#check-dns) |  |
| [docker_container_status](#check-docker-container-status) | Docker container status |
| [docker_container_status_health](#check-docker-container-status-health) | Docker container health |
| [docker_container_status_uptime](#check-docker-container-status-uptime) | Uptime |
| [docker_node_info](#check-docker-node-info) | Docker node info |
| [docker_node_info_containers](#check-docker-node-info-containers) | Docker containers |
| [docsis_channels_downstream](#check-docsis-channels-downstream) | Downstream Channel %s |
| [docsis_channels_upstream](#check-docsis-channels-upstream) | Upstream Channel %s |
| [docsis_cm_status](#check-docsis-cm-status) | Cable Modem %s Status |
| [domino_info](#check-domino-info) | Domino Info |
| [domino_mailqueues](#check-domino-mailqueues) | Domino Queue %s |
| [domino_tasks](#check-domino-tasks) | Domino Task %s |
| [domino_transactions](#check-domino-transactions) | Domino Server Transactions |
| [domino_users](#check-domino-users) | Domino Users |
| [dotnet_clrmemory](#check-dotnet-clrmemory) | DotNet Memory Management %s |
| [drbd](#check-drbd) | DRBD %s status |
| [drbd_disk](#check-drbd-disk) | DRBD %s disk |
| [drbd_net](#check-drbd-net) | DRBD %s net |
| [drbd_stats](#check-drbd-stats) | DRBD %s stats |
| [eltek_systemstatus](#check-eltek-systemstatus) | System Status |
| [emc_datadomain_disks](#check-emc-datadomain-disks) | Hard Disk %s |
| [emc_datadomain_fans](#check-emc-datadomain-fans) | FAN %s |
| [emc_datadomain_fs](#check-emc-datadomain-fs) | DD-Filesystem %s |
| [emc_datadomain_mtree](#check-emc-datadomain-mtree) | MTree %s |
| [emc_datadomain_nvbat](#check-emc-datadomain-nvbat) | NVRAM Battery %s |
| [emc_datadomain_power](#check-emc-datadomain-power) | Power Module %s |
| [emc_datadomain_temps](#check-emc-datadomain-temps) | Temperature %s |
| [emc_isilon_clusterhealth](#check-emc-isilon-clusterhealth) | Cluster Health |
| [emc_isilon_cpu](#check-emc-isilon-cpu) | Node CPU utilization |
| [emc_isilon_diskstatus](#check-emc-isilon-diskstatus) | Disk bay %s Status |
| [emc_isilon_fans](#check-emc-isilon-fans) | Fan %s |
| [emc_isilon_ifs](#check-emc-isilon-ifs) | Filesystem %s |
| [emc_isilon_iops](#check-emc-isilon-iops) | Disk %s IO |
| [emc_isilon_names](#check-emc-isilon-names) | Isilon Info |
| [emc_isilon_nodehealth](#check-emc-isilon-nodehealth) | Node Health |
| [emc_isilon_nodes](#check-emc-isilon-nodes) | Nodes |
| [emc_isilon_power](#check-emc-isilon-power) | Voltage %s |
| [emc_isilon_quota](#check-emc-isilon-quota) | Quota %s |
| [emc_isilon_temp](#check-emc-isilon-temp) | Temperature %s |
| [emc_isilon_temp_cpu](#check-emc-isilon-temp-cpu) | Temperature %s |
| [emc_vplex_cpu](#check-emc-vplex-cpu) | CPU Utilization %s |
| [emerson_stat](#check-emerson-stat) | Status |
| [emerson_temp](#check-emerson-temp) | Temperature %s |
| [emka_modules](#check-emka-modules) | Module %s |
| [emka_modules_alarm](#check-emka-modules-alarm) | Alarm %s |
| [emka_modules_handle](#check-emka-modules-handle) | Handle %s |
| [emka_modules_relay](#check-emka-modules-relay) | Relay %s |
| [emka_modules_sensor_humid](#check-emka-modules-sensor-humid) | Humidity %s |
| [emka_modules_sensor_temp](#check-emka-modules-sensor-temp) | Temperature %s |
| [emka_modules_sensor_volt](#check-emka-modules-sensor-volt) | Phase %s |
| [enterasys_cpu_util](#check-enterasys-cpu-util) | CPU util %s |
| [enterasys_fans](#check-enterasys-fans) | FAN %s |
| [enterasys_lsnat](#check-enterasys-lsnat) | LSNAT Bindings |
| [enterasys_powersupply](#check-enterasys-powersupply) | PSU %s |
| [enterasys_temp](#check-enterasys-temp) | Temperature %s |
| [entersekt](#check-entersekt) | Entersekt Server Status |
| [entersekt_certexpiry](#check-entersekt-certexpiry) | Entersekt Certificate Expiration |
| [entersekt_ecerterrors](#check-entersekt-ecerterrors) | Entersekt http Ecert Errors |
| [entersekt_emrerrors](#check-entersekt-emrerrors) | Entersekt http EMR Errors |
| [entersekt_soaperrors](#check-entersekt-soaperrors) | Entersekt Soap Service Errors |
| [entity_sensors_fan](#check-entity-sensors-fan) | Fan %s |
| [entity_sensors_power_presence](#check-entity-sensors-power-presence) | Power %s |
| [entity_sensors_temp](#check-entity-sensors-temp) | Temperature %s |
| [enviromux](#check-enviromux) | Sensor %s |
| [enviromux_all_external](#check-enviromux-all-external) | Sensor External %s |
| [enviromux_all_external_humidity](#check-enviromux-all-external-humidity) | Sensor External %s |
| [enviromux_all_external_voltage](#check-enviromux-all-external-voltage) | Sensor External %s |
| [enviromux_aux](#check-enviromux-aux) | Sensor %s |
| [enviromux_aux_humidity](#check-enviromux-aux-humidity) | Sensor %s |
| [enviromux_aux_voltage](#check-enviromux-aux-voltage) | Sensor %s |
| [enviromux_digital](#check-enviromux-digital) | Digital Sensor: %s |
| [enviromux_external](#check-enviromux-external) | Sensor External %s |
| [enviromux_external_humidity](#check-enviromux-external-humidity) | Sensor External %s |
| [enviromux_external_voltage](#check-enviromux-external-voltage) | Sensor External %s |
| [enviromux_humidity](#check-enviromux-humidity) | Sensor %s |
| [enviromux_micro_humidity](#check-enviromux-micro-humidity) | Sensor %s |
| [enviromux_micro_humidity_external](#check-enviromux-micro-humidity-external) | Sensor External %s |
| [enviromux_micro_temperature](#check-enviromux-micro-temperature) | Sensor %s |
| [enviromux_micro_temperature_external](#check-enviromux-micro-temperature-external) | Sensor External %s |
| [enviromux_remote_input](#check-enviromux-remote-input) | Remote Input %s |
| [enviromux_sems](#check-enviromux-sems) | Sensor %s |
| [enviromux_sems_digital](#check-enviromux-sems-digital) | Digital Sensor: %s |
| [enviromux_sems_e2d](#check-enviromux-sems-e2d) | Sensor %s |
| [enviromux_sems_e2d_digital](#check-enviromux-sems-e2d-digital) | Digital Sensor: %s |
| [enviromux_sems_e2d_external](#check-enviromux-sems-e2d-external) | Sensor External %s |
| [enviromux_sems_e2d_external_humidity](#check-enviromux-sems-e2d-external-humidity) | Sensor External %s |
| [enviromux_sems_e2d_external_voltage](#check-enviromux-sems-e2d-external-voltage) | Sensor External %s |
| [enviromux_sems_e2d_humidity](#check-enviromux-sems-e2d-humidity) | Sensor %s |
| [enviromux_sems_e2d_voltage](#check-enviromux-sems-e2d-voltage) | Sensor %s |
| [enviromux_sems_external](#check-enviromux-sems-external) | Sensor External %s |
| [enviromux_sems_external_humidity](#check-enviromux-sems-external-humidity) | Sensor External %s |
| [enviromux_sems_external_voltage](#check-enviromux-sems-external-voltage) | Sensor External %s |
| [enviromux_sems_humidity](#check-enviromux-sems-humidity) | Sensor %s |
| [enviromux_sems_voltage](#check-enviromux-sems-voltage) | Sensor %s |
| [enviromux_voltage](#check-enviromux-voltage) | Sensor %s |
| [epower](#check-epower) | Power phase %s |
| [epson_beamer_lamp](#check-epson-beamer-lamp) | Beamer Lamp |
| [etherbox2_temp](#check-etherbox2-temp) | Temperature %s |
| [etherbox_humidity](#check-etherbox-humidity) | Sensor %s |
| [etherbox_nosensor](#check-etherbox-nosensor) | Sensor %s |
| [etherbox_smoke](#check-etherbox-smoke) | Sensor %s |
| [etherbox_switch](#check-etherbox-switch) | Sensor %s |
| [etherbox_temp](#check-etherbox-temp) | Temperature %s |
| [etherbox_voltage](#check-etherbox-voltage) | Sensor %s |
| [ewon](#check-ewon) | %s |
| [extreme_vsp_switches_cpu_util](#check-extreme-vsp-switches-cpu-util) | VSP Switches CPU Utilization |
| [extreme_vsp_switches_fan](#check-extreme-vsp-switches-fan) | VSP Switch Fan %s |
| [extreme_vsp_switches_power_supply](#check-extreme-vsp-switches-power-supply) | VSP Switch Power Supply %s |
| [extreme_vsp_switches_temperature](#check-extreme-vsp-switches-temperature) | VSP Switch %s Temperature |
| [f5_bigip_cluster](#check-f5-bigip-cluster) | F5-BIGIP-Cluster Config Sync - SNMP sections and Checks |
| [f5_bigip_cluster_status](#check-f5-bigip-cluster-status) | F5-BIGIP-Cluster-Status SNMP Sections and Checks |
| [f5_bigip_cluster_status_v11_2](#check-f5-bigip-cluster-status-v11-2) | F5-BIGIP-Cluster-Status SNMP Sections and Checks |
| [f5_bigip_cluster_v11](#check-f5-bigip-cluster-v11) | F5-BIGIP-Cluster Config Sync - SNMP sections and Checks |
| [f5_bigip_pool](#check-f5-bigip-pool) | Load Balancing Pool %s |
| [f5_bigip_vcmpfailover](#check-f5-bigip-vcmpfailover) | F5-BIGIP-Cluster-Status SNMP Sections and Checks |
| [f5_bigip_vcmpguests](#check-f5-bigip-vcmpguests) | F5-BIGIP-Cluster-Status SNMP Sections and Checks |
| [fast_lta_headunit_replication](#check-fast-lta-headunit-replication) | Fast LTA Replication |
| [fast_lta_headunit_status](#check-fast-lta-headunit-status) | Fast LTA Headunit Status |
| [fast_lta_silent_cubes_capacity](#check-fast-lta-silent-cubes-capacity) | Fast LTA SC Capacity %s |
| [fast_lta_volumes](#check-fast-lta-volumes) | Fast LTA Volume %s |
| [fc_port](#check-fc-port) | FC Interface %s |
| [filehandler](#check-filehandler) | Filehandler |
| [fileinfo](#check-fileinfo) | File %s |
| [fileinfo_groups](#check-fileinfo-groups) | File group %s |
| [filestats](#check-filestats) | File group %s |
| [filestats_single](#check-filestats-single) | File %s |
| [fireeye_bypass](#check-fireeye-bypass) | Bypass Mail Rate |
| [fireeye_sys_status](#check-fireeye-sys-status) | System status |
| [fjdarye_ca_ports](#check-fjdarye-ca-ports) | CA Port IO %s |
| [fjdarye_ce_power_supply_units](#check-fjdarye-ce-power-supply-units) | CPSU %s |
| [fjdarye_channel_adapters](#check-fjdarye-channel-adapters) | Channel Adapter %s |
| [fjdarye_channel_modules](#check-fjdarye-channel-modules) | Controller Module %s |
| [fjdarye_controller_enclosures](#check-fjdarye-controller-enclosures) | Controller Enclosure %s |
| [fjdarye_controller_modules_flash](#check-fjdarye-controller-modules-flash) | Controller Module Flash %s |
| [fjdarye_controller_modules_memory](#check-fjdarye-controller-modules-memory) | Controller Module Memory %s |
| [fjdarye_device_enclosures](#check-fjdarye-device-enclosures) | Device Enclosure %s |
| [fjdarye_disks](#check-fjdarye-disks) | Disk %s |
| [fjdarye_disks_summary](#check-fjdarye-disks-summary) | Disk summary |
| [fjdarye_expanders](#check-fjdarye-expanders) | Expander %s |
| [fjdarye_inlet_thermal_sensors](#check-fjdarye-inlet-thermal-sensors) | Inlet Thermal %s |
| [fjdarye_pcie_flash_modules](#check-fjdarye-pcie-flash-modules) | PCIe flash module %s |
| [fjdarye_pools](#check-fjdarye-pools) | Thin Provisioning Pool %s |
| [fjdarye_power_supply_units](#check-fjdarye-power-supply-units) | PSU %s |
| [fjdarye_rluns](#check-fjdarye-rluns) | RLUN %s |
| [fjdarye_summary_status](#check-fjdarye-summary-status) | Summary Status |
| [fjdarye_system_capacitors](#check-fjdarye-system-capacitors) | System Capacitor Unit %s |
| [fjdarye_thermal_sensors](#check-fjdarye-thermal-sensors) | Thermal %s |
| [form_submit](#check-form-submit) |  |
| [fortiauthenticator_auth_fail](#check-fortiauthenticator-auth-fail) | Authentication Failures |
| [fortigate_antivirus](#check-fortigate-antivirus) | AntiVirus %s |
| [fortigate_ap_connection](#check-fortigate-ap-connection) | AP %s Connection |
| [fortigate_ips](#check-fortigate-ips) | IPS %s |
| [fortigate_ipsecvpn](#check-fortigate-ipsecvpn) | VPN IPSec Tunnels |
| [fortigate_node_memory](#check-fortigate-node-memory) | Memory %s |
| [fortigate_sensors](#check-fortigate-sensors) | Sensor Summary |
| [fortigate_signatures](#check-fortigate-signatures) | Signatures |
| [fortigate_sync_status](#check-fortigate-sync-status) | Sync Status |
| [fortimail_cpu_load](#check-fortimail-cpu-load) | CPU load |
| [fortimail_disk_usage](#check-fortimail-disk-usage) | Disk usage |
| [fortimail_queue](#check-fortimail-queue) | FortiMail %s |
| [fortinet_controller_aps](#check-fortinet-controller-aps) | AP %s |
| [fortisandbox_disk_usage](#check-fortisandbox-disk-usage) | Disk usage %s |
| [fortisandbox_mem_usage](#check-fortisandbox-mem-usage) | Memory |
| [fritz_conn](#check-fritz-conn) | Connection |
| [fritz_link](#check-fritz-link) | Link Info |
| [fritz_uptime](#check-fritz-uptime) | Uptime |
| [fritz_wan_if](#check-fritz-wan-if) | Interface %s |
| [fsc_ipmi_mem_status](#check-fsc-ipmi-mem-status) | IPMI Memory status %s |
| [fsc_subsystems](#check-fsc-subsystems) | FSC %s |
| [ftp](#check-ftp) |  |
| [genua_carp](#check-genua-carp) | Carp Interface %s |
| [genua_state_correlation](#check-genua-state-correlation) | Carp Correlation |
| [genua_vpn](#check-genua-vpn) | VPN %s |
| [globalprotect_utilization](#check-globalprotect-utilization) | GlobalProtect Gateway Utilization |
| [gude_humidity](#check-gude-humidity) | Humidity %s |
| [gude_powerbanks](#check-gude-powerbanks) | Powerbank %s |
| [gude_relayport](#check-gude-relayport) | Relay port %s |
| [gude_temp](#check-gude-temp) | Temperature %s |
| [h3c_lanswitch_cpu](#check-h3c-lanswitch-cpu) | CPU Utilization %s |
| [h3c_lanswitch_sensors](#check-h3c-lanswitch-sensors) | %s |
| [haproxy_backend](#check-haproxy-backend) | HAProxy Backend %s |
| [haproxy_frontend](#check-haproxy-frontend) | HAProxy Frontend %s |
| [haproxy_server](#check-haproxy-server) | HAProxy Server %s |
| [heartbeat_crm](#check-heartbeat-crm) | Heartbeat CRM General |
| [heartbeat_crm_resources](#check-heartbeat-crm-resources) | Heartbeat CRM %s |
| [heartbeat_nodes](#check-heartbeat-nodes) | Heartbeat Node %s |
| [heartbeat_rscstatus](#check-heartbeat-rscstatus) | Heartbeat Ressource Status |
| [hepta](#check-hepta) | HPF Info |
| [hepta_ntpsysstratum](#check-hepta-ntpsysstratum) | %s |
| [hepta_syncmoduletimelocal](#check-hepta-syncmoduletimelocal) | %s |
| [hepta_syncmoduletimesyncstate](#check-hepta-syncmoduletimesyncstate) | %s |
| [hitachi_hnas_fc_if](#check-hitachi-hnas-fc-if) | Interface FC %s |
| [hitachi_hnas_span](#check-hitachi-hnas-span) | Span %s |
| [hitachi_hnas_volume](#check-hitachi-hnas-volume) | Volumes %s |
| [hitachi_hnas_volume_virtual](#check-hitachi-hnas-volume-virtual) | Volumes %s |
| [hitachi_hus_dkc](#check-hitachi-hus-dkc) | HUS DKC Chassis %s |
| [hitachi_hus_dku](#check-hitachi-hus-dku) | HUS DKU Chassis %s |
| [hivemanager_devices](#check-hivemanager-devices) | Client %s |
| [hivemanager_ng_devices](#check-hivemanager-ng-devices) | Client %s |
| [hp_blade](#check-hp-blade) | General Status |
| [hp_blade_blades](#check-hp-blade-blades) | Blade %s |
| [hp_blade_fan](#check-hp-blade-fan) | FAN %s |
| [hp_blade_manager](#check-hp-blade-manager) | Manager %s |
| [hp_blade_psu](#check-hp-blade-psu) | PSU %s |
| [hp_eml_sum](#check-hp-eml-sum) | Summary Status |
| [hp_fan](#check-hp-fan) | Fan %s |
| [hp_hh3c_ext](#check-hp-hh3c-ext) | Temperature %s |
| [hp_hh3c_ext_cpu](#check-hp-hh3c-ext-cpu) | CPU utilization %s |
| [hp_hh3c_ext_mem](#check-hp-hh3c-ext-mem) | Memory %s |
| [hp_hh3c_ext_states](#check-hp-hh3c-ext-states) | Status %s |
| [hp_hh3c_fan](#check-hp-hh3c-fan) | Fan %s |
| [hp_hh3c_power](#check-hp-hh3c-power) | Power %s |
| [hp_mcs_sensors](#check-hp-mcs-sensors) | Sensor %s |
| [hp_mcs_sensors_fan](#check-hp-mcs-sensors-fan) | Sensor %s |
| [hp_mcs_system](#check-hp-mcs-system) | %s |
| [hp_msa_controller](#check-hp-msa-controller) | CPU Utilization %s |
| [hp_msa_controller_io](#check-hp-msa-controller-io) | Controller IO %s |
| [hp_msa_disk](#check-hp-msa-disk) | Disk Health %s |
| [hp_msa_disk_io](#check-hp-msa-disk-io) | Disk IO %s |
| [hp_msa_disk_temp](#check-hp-msa-disk-temp) | Temperature %s |
| [hp_msa_fan](#check-hp-msa-fan) | Fan %s |
| [hp_msa_psu](#check-hp-msa-psu) | Power Supply Health %s |
| [hp_msa_psu_sensor](#check-hp-msa-psu-sensor) | Power Supply Voltage %s |
| [hp_msa_psu_temp](#check-hp-msa-psu-temp) | Temperature Power Supply %s |
| [hp_msa_system](#check-hp-msa-system) | System Health %s |
| [hp_msa_volume](#check-hp-msa-volume) | Volume Health %s |
| [hp_msa_volume_df](#check-hp-msa-volume-df) | Filesystem %s |
| [hp_msa_volume_io](#check-hp-msa-volume-io) | Volume IO %s |
| [hp_procurve_cpu](#check-hp-procurve-cpu) | CPU utilization |
| [hp_procurve_mem](#check-hp-procurve-mem) | Memory |
| [hp_procurve_sensors](#check-hp-procurve-sensors) | Sensor %s |
| [hp_procurve_temp](#check-hp-procurve-temp) | Temperature %s |
| [hp_proliant](#check-hp-proliant) | General Status |
| [hp_proliant_cpu](#check-hp-proliant-cpu) | HW CPU %s |
| [hp_proliant_da_cntlr](#check-hp-proliant-da-cntlr) | HW Controller %s |
| [hp_proliant_da_phydrv](#check-hp-proliant-da-phydrv) | HW Phydrv %s |
| [hp_proliant_fans](#check-hp-proliant-fans) | HW FAN%s |
| [hp_proliant_mem](#check-hp-proliant-mem) | HW Mem %s |
| [hp_proliant_power](#check-hp-proliant-power) | HW Power Meter |
| [hp_proliant_psu](#check-hp-proliant-psu) | HW PSU %s |
| [hp_proliant_raid](#check-hp-proliant-raid) | Logical Device %s |
| [hp_proliant_temp](#check-hp-proliant-temp) | Temperature %s |
| [hp_psu](#check-hp-psu) | Power Supply Status %s |
| [hp_psu_temp](#check-hp-psu-temp) | Temperature Power Supply %s |
| [hp_sts_drvbox](#check-hp-sts-drvbox) | Drive Box %s |
| [hp_webmgmt_status](#check-hp-webmgmt-status) | Status %s |
| [hpux_fchba](#check-hpux-fchba) | FC HBA %s |
| [hpux_if](#check-hpux-if) | NIC %s |
| [hpux_lvm](#check-hpux-lvm) | Logical Volume %s |
| [hpux_multipath](#check-hpux-multipath) | Multipath %s |
| [hpux_serviceguard](#check-hpux-serviceguard) | Serviceguard %s |
| [hpux_snmp_cs_cpu](#check-hpux-snmp-cs-cpu) | CPU utilization |
| [hpux_tunables_maxfiles_lim](#check-hpux-tunables-maxfiles-lim) | Number of open files |
| [hpux_tunables_nkthread](#check-hpux-tunables-nkthread) | Number of threads |
| [hpux_tunables_nproc](#check-hpux-tunables-nproc) | Number of processes |
| [hpux_tunables_semmni](#check-hpux-tunables-semmni) | Number of IPC Semaphore IDs |
| [hpux_tunables_semmns](#check-hpux-tunables-semmns) | Number of IPC Semaphores |
| [hpux_tunables_shmseg](#check-hpux-tunables-shmseg) | Number of shared memory segments |
| [hr_cpu](#check-hr-cpu) | CPU utilization |
| [hr_fs](#check-hr-fs) | Filesystem %s |
| [hr_ps](#check-hr-ps) | Process %s |
| [http](#check-http) |  |
| [httpv2](#check-httpv2) |  |
| [huawei_osn_fan](#check-huawei-osn-fan) |  |
| [huawei_osn_if](#check-huawei-osn-if) | Interface %s |
| [huawei_osn_laser](#check-huawei-osn-laser) | Laser %s |
| [huawei_osn_power](#check-huawei-osn-power) |  |
| [huawei_osn_temp](#check-huawei-osn-temp) | Temperature %s |
| [huawei_switch_cpu](#check-huawei-switch-cpu) | CPU utilization %s |
| [huawei_switch_fan](#check-huawei-switch-fan) | Fan %s |
| [huawei_switch_mem](#check-huawei-switch-mem) | Memory %s |
| [huawei_switch_psu](#check-huawei-switch-psu) | Powersupply %s |
| [huawei_switch_stack](#check-huawei-switch-stack) | Stack role %s |
| [huawei_switch_temp](#check-huawei-switch-temp) | Temperature %s |
| [huawei_wlc_aps_cpu](#check-huawei-wlc-aps-cpu) | AP %s CPU |
| [huawei_wlc_aps_mem](#check-huawei-wlc-aps-mem) | AP %s Memory |
| [huawei_wlc_aps_status](#check-huawei-wlc-aps-status) | AP %s Status |
| [huawei_wlc_aps_temp](#check-huawei-wlc-aps-temp) | AP %s Temperature |
| [huawei_wlc_devs_cpu](#check-huawei-wlc-devs-cpu) | Device %s CPU |
| [huawei_wlc_devs_mem](#check-huawei-wlc-devs-mem) | Device %s Memory |
| [hwg_humidity](#check-hwg-humidity) | Humidity %s |
| [hwg_ste2](#check-hwg-ste2) | Temperature %s |
| [hwg_ste2_humidity](#check-hwg-ste2-humidity) | Humidity %s |
| [hwg_temp](#check-hwg-temp) | Temperature %s |
| [hyperv_checkpoints](#check-hyperv-checkpoints) | HyperV Checkpoints |
| [hyperv_vm_checkpoints](#check-hyperv-vm-checkpoints) | Hyper-V VM Checkpoints |
| [hyperv_vm_general](#check-hyperv-vm-general) | Hyper-V VM summary |
| [hyperv_vm_integration](#check-hyperv-vm-integration) | Hyper-V VM integration services |
| [hyperv_vm_nic](#check-hyperv-vm-nic) | HyperV NIC %s |
| [hyperv_vm_ram](#check-hyperv-vm-ram) | Hyper-V RAM |
| [hyperv_vm_vhd_dynamic](#check-hyperv-vm-vhd-dynamic) | Hyper-V VM Disk [%s] |
| [hyperv_vm_vhd_fixed](#check-hyperv-vm-vhd-fixed) | Hyper-V VM Disk [%s] |
| [hyperv_vms](#check-hyperv-vms) | VM %s |
| [hyperv_vmstatus](#check-hyperv-vmstatus) | HyperV Status |
| [ibm_imm_fan](#check-ibm-imm-fan) | Fan %s |
| [ibm_imm_health](#check-ibm-imm-health) | System health |
| [ibm_imm_temp](#check-ibm-imm-temp) | Temperature %s |
| [ibm_imm_voltage](#check-ibm-imm-voltage) | Voltage %s |
| [ibm_mq_channels](#check-ibm-mq-channels) | IBM MQ Channel %s |
| [ibm_mq_managers](#check-ibm-mq-managers) | IBM MQ Manager %s |
| [ibm_mq_plugin](#check-ibm-mq-plugin) | IBM MQ Plugin |
| [ibm_mq_queues](#check-ibm-mq-queues) | IBM MQ Queue %s |
| [ibm_rsa_health](#check-ibm-rsa-health) | System health |
| [ibm_storage_ts](#check-ibm-storage-ts) | Info |
| [ibm_storage_ts_drive](#check-ibm-storage-ts-drive) | Drive %s |
| [ibm_storage_ts_library](#check-ibm-storage-ts-library) | Library %s |
| [ibm_storage_ts_status](#check-ibm-storage-ts-status) | Status |
| [ibm_svc_array](#check-ibm-svc-array) | RAID Array %s |
| [ibm_svc_disks](#check-ibm-svc-disks) | Disk Summary |
| [ibm_svc_enclosure](#check-ibm-svc-enclosure) | Enclosure %s |
| [ibm_svc_enclosurestats_power](#check-ibm-svc-enclosurestats-power) | Power Enclosure %s |
| [ibm_svc_enclosurestats_temp](#check-ibm-svc-enclosurestats-temp) | Temperature Enclosure %s |
| [ibm_svc_eventlog](#check-ibm-svc-eventlog) | Eventlog |
| [ibm_svc_host](#check-ibm-svc-host) | Hosts |
| [ibm_svc_license](#check-ibm-svc-license) | License %s |
| [ibm_svc_mdisk](#check-ibm-svc-mdisk) | MDisk %s |
| [ibm_svc_mdiskgrp](#check-ibm-svc-mdiskgrp) | Pool Capacity %s |
| [ibm_svc_node](#check-ibm-svc-node) | IO Group %s |
| [ibm_svc_nodestats_cache](#check-ibm-svc-nodestats-cache) | Cache %s |
| [ibm_svc_nodestats_cpu_util](#check-ibm-svc-nodestats-cpu-util) | CPU utilization %s |
| [ibm_svc_nodestats_disk_latency](#check-ibm-svc-nodestats-disk-latency) | Disk Latency %s |
| [ibm_svc_nodestats_diskio](#check-ibm-svc-nodestats-diskio) | Disk IO %s |
| [ibm_svc_nodestats_iops](#check-ibm-svc-nodestats-iops) | Disk IOPS %s |
| [ibm_svc_portfc](#check-ibm-svc-portfc) | FC %s |
| [ibm_svc_portsas](#check-ibm-svc-portsas) | SAS %s |
| [ibm_svc_system](#check-ibm-svc-system) | Info |
| [ibm_svc_systemstats_cache](#check-ibm-svc-systemstats-cache) | Cache Total |
| [ibm_svc_systemstats_cpu_util](#check-ibm-svc-systemstats-cpu-util) | CPU utilization Total |
| [ibm_svc_systemstats_disk_latency](#check-ibm-svc-systemstats-disk-latency) | Latency %s Total |
| [ibm_svc_systemstats_diskio](#check-ibm-svc-systemstats-diskio) | Throughput %s Total |
| [ibm_svc_systemstats_iops](#check-ibm-svc-systemstats-iops) | IOPS %s Total |
| [ibm_tl_changer_devices](#check-ibm-tl-changer-devices) | Changer device %s |
| [ibm_tl_media_access_devices](#check-ibm-tl-media-access-devices) | Media access device %s |
| [ibm_xraid_pdisks](#check-ibm-xraid-pdisks) | RAID PDisk %s |
| [icmp](#check-icmp) |  |
| [icom_repeater](#check-icom-repeater) | Repeater Info |
| [icom_repeater_pll_volt](#check-icom-repeater-pll-volt) | %s PLL Lock Voltage |
| [icom_repeater_ps_volt](#check-icom-repeater-ps-volt) | Power Supply Voltage |
| [icom_repeater_temp](#check-icom-repeater-temp) | Temperature %s |
| [if64](#check-if64) | Interface %s |
| [iis_app_pool_state](#check-iis-app-pool-state) | IIS Application Pool %s |
| [infoblox_node_services](#check-infoblox-node-services) | Infoblox services and node services |
| [infoblox_services](#check-infoblox-services) | Infoblox services and node services |
| [infoblox_temp](#check-infoblox-temp) | Temperature %s |
| [informix_dbspaces](#check-informix-dbspaces) | Relevant documentation: |
| [informix_locks](#check-informix-locks) | Informix Locks %s |
| [informix_logusage](#check-informix-logusage) | Informix Log Usage %s |
| [informix_sessions](#check-informix-sessions) | Informix Sessions %s |
| [informix_status](#check-informix-status) | Informix Instance %s |
| [informix_tabextents](#check-informix-tabextents) | Informix Table Extents %s |
| [inotify](#check-inotify) | INotify %s |
| [interfaces](#check-interfaces) | Interface %s |
| [ipr400_in_voltage](#check-ipr400-in-voltage) | IN Voltage %s |
| [ipr400_temp](#check-ipr400-temp) | Temperature %s |
| [iptables](#check-iptables) | Iptables |
| [isc_dhcpd](#check-isc-dhcpd) | DHCP Pool %s |
| [janitza_umg](#check-janitza-umg) | Input %s |
| [janitza_umg_freq](#check-janitza-umg-freq) | Frequency %s |
| [janitza_umg_temp](#check-janitza-umg-temp) | Temperature External %s |
| [jar_signature](#check-jar-signature) | Jar-Signature %s |
| [jira_custom_svc](#check-jira-custom-svc) | Jira %s |
| [jira_workflow](#check-jira-workflow) | Jira Workflow %s |
| [job](#check-job) | Job %s |
| [juniper_alarm](#check-juniper-alarm) | Chassis |
| [juniper_bgp_state](#check-juniper-bgp-state) | BGP Status Peer %s |
| [juniper_cpu_util](#check-juniper-cpu-util) | CPU utilization %s |
| [juniper_fru](#check-juniper-fru) | Power Supply FRU %s |
| [juniper_fru_fan](#check-juniper-fru-fan) | Fan FRU %s |
| [juniper_mem](#check-juniper-mem) | Memory %s |
| [juniper_screenos_cpu](#check-juniper-screenos-cpu) | CPU utilization |
| [juniper_screenos_fan](#check-juniper-screenos-fan) | FAN %s |
| [juniper_screenos_mem](#check-juniper-screenos-mem) | Memory |
| [juniper_screenos_temp](#check-juniper-screenos-temp) | Temperature %s |
| [juniper_screenos_vpn](#check-juniper-screenos-vpn) | VPN %s |
| [juniper_temp](#check-juniper-temp) | Temperature %s |
| [juniper_trpz_aps](#check-juniper-trpz-aps) | Access Points |
| [juniper_trpz_aps_sessions](#check-juniper-trpz-aps-sessions) | Access Point %s |
| [juniper_trpz_cpu_util](#check-juniper-trpz-cpu-util) | CPU utilization |
| [juniper_trpz_flash](#check-juniper-trpz-flash) | Flash |
| [juniper_trpz_info](#check-juniper-trpz-info) | Info |
| [juniper_trpz_mem](#check-juniper-trpz-mem) | Memory |
| [juniper_trpz_power](#check-juniper-trpz-power) | PSU %s |
| [kaspersky_av_client](#check-kaspersky-av-client) | Kaspersky AV |
| [kaspersky_av_kesl_updates](#check-kaspersky-av-kesl-updates) | AV Update Status |
| [kaspersky_av_quarantine](#check-kaspersky-av-quarantine) | AV Quarantine |
| [kaspersky_av_tasks](#check-kaspersky-av-tasks) | AV Task %s |
| [kaspersky_av_updates](#check-kaspersky-av-updates) | AV Update Status |
| [keepalived](#check-keepalived) | VRRP Instance %s |
| [kemp_loadmaster_realserver](#check-kemp-loadmaster-realserver) | Real Server %s |
| [kemp_loadmaster_services](#check-kemp-loadmaster-services) | Service %s |
| [kentix_amp_sensors](#check-kentix-amp-sensors) | Temperature %s |
| [kentix_amp_sensors_humidity](#check-kentix-amp-sensors-humidity) | Humidity %s |
| [kentix_amp_sensors_leakage](#check-kentix-amp-sensors-leakage) | Leakage %s |
| [kentix_amp_sensors_smoke](#check-kentix-amp-sensors-smoke) | Smoke Detector %s |
| [kentix_co](#check-kentix-co) | Carbon Monoxide |
| [kentix_dewpoint](#check-kentix-dewpoint) | Dewpoint %s |
| [kentix_humidity](#check-kentix-humidity) | Humidity |
| [kentix_motion](#check-kentix-motion) | Motion Detector %s |
| [kentix_temp](#check-kentix-temp) | Temperature %s |
| [kernel_performance](#check-kernel-performance) | Kernel Performance |
| [kernel_util](#check-kernel-util) | CPU utilization |
| [knuerr_rms_humidity](#check-knuerr-rms-humidity) | Humidity |
| [knuerr_rms_temp](#check-knuerr-rms-temp) | Temperature %s |
| [knuerr_sensors](#check-knuerr-sensors) | Sensor %s |
| [ldap](#check-ldap) |  |
| [lgp_info](#check-lgp-info) | Liebert Info |
| [lgp_pdu_aux](#check-lgp-pdu-aux) | Liebert PDU AUX %s |
| [lgp_pdu_info](#check-lgp-pdu-info) | Liebert PDU Info %s |
| [libelle_business_shadow_archive_dir](#check-libelle-business-shadow-archive-dir) | Libelle Business Shadow %s |
| [libelle_business_shadow_info](#check-libelle-business-shadow-info) | Libelle Business Shadow Info |
| [libelle_business_shadow_process](#check-libelle-business-shadow-process) | Libelle Business Shadow Process |
| [libelle_business_shadow_status](#check-libelle-business-shadow-status) | Libelle Business Shadow Status |
| [liebert_bat_temp](#check-liebert-bat-temp) | Temperature %s |
| [liebert_chilled_water](#check-liebert-chilled-water) | %s |
| [liebert_chiller_status](#check-liebert-chiller-status) | Chiller status |
| [liebert_compressor](#check-liebert-compressor) | %s |
| [liebert_cooling](#check-liebert-cooling) | %s |
| [liebert_cooling_position](#check-liebert-cooling-position) | %s |
| [liebert_cooling_status](#check-liebert-cooling-status) | %s |
| [liebert_fans](#check-liebert-fans) | %s |
| [liebert_fans_condenser](#check-liebert-fans-condenser) | %s |
| [liebert_humidity_air](#check-liebert-humidity-air) | %s Humidity |
| [liebert_maintenance](#check-liebert-maintenance) | Maintenance |
| [liebert_pump](#check-liebert-pump) | %s |
| [liebert_reheating](#check-liebert-reheating) | Reheating Utilization |
| [liebert_system](#check-liebert-system) | Status %s |
| [liebert_system_events](#check-liebert-system-events) | System events |
| [liebert_temp_air](#check-liebert-temp-air) | %s Temperature |
| [liebert_temp_fluid](#check-liebert-temp-fluid) | %s |
| [liebert_temp_general](#check-liebert-temp-general) | %s |
| [livestatus_status](#check-livestatus-status) | OMD %s performance |
| [lnx_if](#check-lnx-if) | Interface %s |
| [lnx_quota](#check-lnx-quota) | Quota: %s |
| [lnx_thermal](#check-lnx-thermal) | Temperature %s |
| [local](#check-local) | %s |
| [logins](#check-logins) | Logins |
| [lparstat_aix](#check-lparstat-aix) | lparstat |
| [lparstat_aix_cpu_util](#check-lparstat-aix-cpu-util) | CPU utilization |
| [lsi_array](#check-lsi-array) | RAID array %s |
| [lsi_disk](#check-lsi-disk) | RAID disk %s |
| [lvm_lvs](#check-lvm-lvs) | LVM LV Pool %s |
| [lvm_vgs](#check-lvm-vgs) | LVM VG %s |
| [mail](#check-mail) |  |
| [mail_loop](#check-mail-loop) |  |
| [mailboxes](#check-mailboxes) |  |
| [mailman_lists](#check-mailman-lists) | Mailinglist %s |
| [mbg_lantime_ng_refclock](#check-mbg-lantime-ng-refclock) | LANTIME Refclock %s |
| [mbg_lantime_ng_refclock_gps](#check-mbg-lantime-ng-refclock-gps) | LANTIME Refclock %s |
| [mcafee_av_client](#check-mcafee-av-client) | McAfee AV |
| [mcafee_webgateway](#check-mcafee-webgateway) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_http_client_requests](#check-mcafee-webgateway-http-client-requests) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_https_client_requests](#check-mcafee-webgateway-https-client-requests) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_httpv2_client_requests](#check-mcafee-webgateway-httpv2-client-requests) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_info](#check-mcafee-webgateway-info) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_misc](#check-mcafee-webgateway-misc) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_time_consumed_by_rule_engine](#check-mcafee-webgateway-time-consumed-by-rule-engine) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcafee_webgateway_time_to_resolve_dns](#check-mcafee-webgateway-time-to-resolve-dns) | The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2. |
| [mcdata_fcport](#check-mcdata-fcport) | Port %s |
| [md](#check-md) | MD Softraid %s |
| [megaraid_bbu](#check-megaraid-bbu) | RAID BBU %s |
| [megaraid_ldisks](#check-megaraid-ldisks) | RAID logical disk %s |
| [megaraid_pdisks](#check-megaraid-pdisks) | RAID pysical disk %s |
| [mem_linux](#check-mem-linux) | Memory |
| [mem_used](#check-mem-used) | Memory |
| [mem_vmalloc](#check-mem-vmalloc) | Vmalloc address space |
| [mem_win](#check-mem-win) | Memory |
| [memory_utilization](#check-memory-utilization) | Memory |
| [mikrotik_signal](#check-mikrotik-signal) | Signal %s |
| [mkbackup](#check-mkbackup) | Backup %s |
| [mkbackup_site](#check-mkbackup-site) | OMD %s |
| [mkeventd_status](#check-mkeventd-status) | OMD %s Event Console |
| [mkevents](#check-mkevents) |  |
| [mknotifyd](#check-mknotifyd) | OMD %s Notification Spooler |
| [mknotifyd_connection](#check-mknotifyd-connection) | OMD %s Notify Connection |
| [mknotifyd_connection_v2](#check-mknotifyd-connection-v2) | OMD %s |
| [mobileiron_compliance](#check-mobileiron-compliance) | Mobileiron compliance |
| [mobileiron_statistics](#check-mobileiron-statistics) | Provides summarized insights into the fetched partitions. |
| [mobileiron_versions](#check-mobileiron-versions) | Mobileiron versions |
| [mongodb_asserts](#check-mongodb-asserts) | MongoDB Asserts |
| [mongodb_cluster](#check-mongodb-cluster) | MongoDB Database: %s |
| [mongodb_cluster_balancer](#check-mongodb-cluster-balancer) | MongoDB Balancer |
| [mongodb_cluster_collections](#check-mongodb-cluster-collections) | MongoDB Cluster: %s |
| [mongodb_collections](#check-mongodb-collections) | MongoDB Collection: %s |
| [mongodb_connections](#check-mongodb-connections) | MongoDB %s |
| [mongodb_counters](#check-mongodb-counters) | MongoDB Counters %s |
| [mongodb_flushing](#check-mongodb-flushing) | MongoDB Flushing |
| [mongodb_instance](#check-mongodb-instance) | MongoDB Instance |
| [mongodb_locks](#check-mongodb-locks) | MongoDB Locks |
| [mongodb_mem](#check-mongodb-mem) | Memory used MongoDB |
| [mongodb_replica](#check-mongodb-replica) | MongoDB Replica Set Status |
| [mongodb_replica_set](#check-mongodb-replica-set) | MongoDB Replication Lag |
| [mongodb_replica_set_election](#check-mongodb-replica-set-election) | MongoDB Replica Set Primary Election |
| [mongodb_replication_info](#check-mongodb-replication-info) | MongoDB Replication Info |
| [mounts](#check-mounts) | Mount options of %s |
| [moxa_iologik_register](#check-moxa-iologik-register) | Moxa Register %s |
| [mq_queues](#check-mq-queues) | Queue %s |
| [mqtt_broker](#check-mqtt-broker) | MQTT %s Broker |
| [mqtt_clients](#check-mqtt-clients) | MQTT %s Clients |
| [mqtt_messages](#check-mqtt-messages) | MQTT %s Messages |
| [mqtt_uptime](#check-mqtt-uptime) | MQTT %s Uptime |
| [mrpe](#check-mrpe) | %s |
| [msexch_activesync](#check-msexch-activesync) | Exchange ActiveSync |
| [msexch_autodiscovery](#check-msexch-autodiscovery) | Exchange Autodiscovery |
| [msexch_availability](#check-msexch-availability) | Exchange Availability Service |
| [msexch_dag_contentindex](#check-msexch-dag-contentindex) | Exchange DAG ContentIndex of %s |
| [msexch_dag_copyqueue](#check-msexch-dag-copyqueue) | Exchange DAG CopyQueue of %s |
| [msexch_dag_dbcopy](#check-msexch-dag-dbcopy) | Exchange DAG DBCopy for %s |
| [msexch_database](#check-msexch-database) | Exchange Database %s |
| [msexch_isclienttype](#check-msexch-isclienttype) | Exchange IS Client Type %s |
| [msexch_isstore](#check-msexch-isstore) | Exchange IS Store %s |
| [msexch_owa](#check-msexch-owa) | Exchange OWA |
| [msexch_replhealth](#check-msexch-replhealth) | Exchange Replication Health %s |
| [msexch_rpcclientaccess](#check-msexch-rpcclientaccess) | Exchange RPC Client Access |
| [msoffice_licenses](#check-msoffice-licenses) | MS Office Licenses %s |
| [msoffice_serviceplans](#check-msoffice-serviceplans) | MS Office Serviceplans %s |
| [mssql_availability_groups](#check-mssql-availability-groups) | MSSQL Availability Group %s |
| [mssql_backup](#check-mssql-backup) | MSSQL %s Backup |
| [mssql_backup_per_type](#check-mssql-backup-per-type) | MSSQL %s Backup |
| [mssql_blocked_sessions](#check-mssql-blocked-sessions) | MSSQL %s Blocked Sessions |
| [mssql_connections](#check-mssql-connections) | MSSQL Connections %s |
| [mssql_counters_cache_hits](#check-mssql-counters-cache-hits) | MSSQL %s |
| [mssql_counters_file_sizes](#check-mssql-counters-file-sizes) | MSSQL %s File Sizes |
| [mssql_counters_locks](#check-mssql-counters-locks) | MSSQL %s Locks |
| [mssql_counters_locks_per_batch](#check-mssql-counters-locks-per-batch) | MSSQL %s Locks per Batch |
| [mssql_counters_page_life_expectancy](#check-mssql-counters-page-life-expectancy) | MSSQL %s |
| [mssql_counters_pageactivity](#check-mssql-counters-pageactivity) | MSSQL %s Page Activity |
| [mssql_counters_sqlstats](#check-mssql-counters-sqlstats) | MSSQL %s |
| [mssql_counters_transactions](#check-mssql-counters-transactions) | MSSQL %s Transactions |
| [mssql_databases](#check-mssql-databases) | MSSQL %s Database |
| [mssql_datafiles](#check-mssql-datafiles) | MSSQL Datafile %s |
| [mssql_instance](#check-mssql-instance) | MSSQL %s Instance |
| [mssql_jobs](#check-mssql-jobs) | MSSQL job %s |
| [mssql_mirroring](#check-mssql-mirroring) | MSSQL Mirroring Status: %s |
| [mssql_tablespaces](#check-mssql-tablespaces) | MSSQL %s Sizes |
| [mssql_transactionlogs](#check-mssql-transactionlogs) | MSSQL Transactionlog %s |
| [mtr](#check-mtr) | Mtr to %s |
| [multipath](#check-multipath) | Multipath %s |
| [mysql](#check-mysql) | MySQL Version %s |
| [mysql_capacity](#check-mysql-capacity) | MySQL DB Size %s |
| [mysql_connections](#check-mysql-connections) | MySQL Connections %s |
| [mysql_galeradonor](#check-mysql-galeradonor) | MySQL Galera Donor %s |
| [mysql_galerasize](#check-mysql-galerasize) | MySQL Galera Size %s |
| [mysql_galerastartup](#check-mysql-galerastartup) | MySQL Galera Startup %s |
| [mysql_galerastatus](#check-mysql-galerastatus) | MySQL Galera Status %s |
| [mysql_galerasync](#check-mysql-galerasync) | MySQL Galera Sync %s |
| [mysql_innodb_io](#check-mysql-innodb-io) | MySQL InnoDB IO %s |
| [mysql_ping](#check-mysql-ping) | MySQL Instance %s |
| [mysql_replica_slave](#check-mysql-replica-slave) | MySQL DB Slave %s |
| [mysql_sessions](#check-mysql-sessions) | MySQL Sessions %s |
| [netctr_combined](#check-netctr-combined) | NIC %s counters |
| [netscaler_ha](#check-netscaler-ha) | HA Node Status |
| [netscaler_sslcertificates](#check-netscaler-sslcertificates) | SSL Certificate %s |
| [netscaler_tcp_conns](#check-netscaler-tcp-conns) | TCP Connections |
| [netscaler_vserver](#check-netscaler-vserver) | VServer %s |
| [netstat](#check-netstat) | TCP Connection %s |
| [nfsexports](#check-nfsexports) | NFS export %s |
| [nfsiostat](#check-nfsiostat) | NFS IO stats %s |
| [nfsmounts](#check-nfsmounts) | NFS mount %s |
| [nginx_status](#check-nginx-status) | Nginx %s Status |
| [nimble_latency](#check-nimble-latency) | Volume %s Read IO |
| [nimble_latency_write](#check-nimble-latency-write) | Volume %s Write IO |
| [nimble_volumes](#check-nimble-volumes) | Volume %s |
| [notify_count](#check-notify-count) |  |
| [ntp](#check-ntp) | NTP Peer %s |
| [ntp_time](#check-ntp-time) | NTP Time |
| [nullmailer_mailq](#check-nullmailer-mailq) | Nullmailer Queue |
| [nvidia_errors](#check-nvidia-errors) | NVIDIA GPU Errors |
| [nvidia_smi_en_de_coder_util](#check-nvidia-smi-en-de-coder-util) | Nvidia GPU En-/Decoder utilization %s |
| [nvidia_smi_gpu_util](#check-nvidia-smi-gpu-util) | Nvidia GPU utilization %s |
| [nvidia_smi_memory_util](#check-nvidia-smi-memory-util) | Nvidia GPU Memory utilization %s |
| [nvidia_smi_power](#check-nvidia-smi-power) | Nvidia GPU Power %s |
| [nvidia_smi_temperature](#check-nvidia-smi-temperature) | Nvidia GPU Temperature %s |
| [nvidia_temp](#check-nvidia-temp) | Temperature %s |
| [nvidia_temp_core](#check-nvidia-temp-core) | Temperature %s |
| [omd_apache](#check-omd-apache) | OMD %s apache |
| [omd_broker_queues](#check-omd-broker-queues) | OMD %s |
| [omd_broker_status](#check-omd-broker-status) | OMD %s message broker |
| [omd_diskusage](#check-omd-diskusage) | OMD %s disk usage |
| [omd_status](#check-omd-status) | <<<omd_status>>> |
| [openbsd_sensors](#check-openbsd-sensors) | Temperature %s |
| [openbsd_sensors_drive](#check-openbsd-sensors-drive) | Drive %s |
| [openbsd_sensors_fan](#check-openbsd-sensors-fan) | Fan %s |
| [openbsd_sensors_indicator](#check-openbsd-sensors-indicator) | Indicator %s |
| [openbsd_sensors_powersupply](#check-openbsd-sensors-powersupply) | Powersupply %s |
| [openbsd_sensors_voltage](#check-openbsd-sensors-voltage) | Voltage Type %s |
| [openhardwaremonitor](#check-openhardwaremonitor) | Clock %s |
| [openhardwaremonitor_fan](#check-openhardwaremonitor-fan) | Fan %s |
| [openhardwaremonitor_power](#check-openhardwaremonitor-power) | Power %s |
| [openhardwaremonitor_smart](#check-openhardwaremonitor-smart) | SMART %s Stats |
| [openhardwaremonitor_temperature](#check-openhardwaremonitor-temperature) | Temperature %s |
| [openvpn_clients](#check-openvpn-clients) | OpenVPN Client %s |
| [oracle_asm_diskgroup](#check-oracle-asm-diskgroup) | ASM Diskgroup %s |
| [oracle_crs_res](#check-oracle-crs-res) | ORA-GI %s Resource |
| [oracle_crs_version](#check-oracle-crs-version) | ORA-GI Version |
| [oracle_crs_voting](#check-oracle-crs-voting) | ORA-GI Voting |
| [oracle_dataguard_stats](#check-oracle-dataguard-stats) | ORA %s Dataguard-Stats |
| [oracle_diva_csm](#check-oracle-diva-csm) | DIVA Status %s |
| [oracle_diva_csm_actor](#check-oracle-diva-csm-actor) | DIVA Status %s |
| [oracle_diva_csm_archive](#check-oracle-diva-csm-archive) | DIVA Status %s |
| [oracle_diva_csm_drive](#check-oracle-diva-csm-drive) | DIVA Status %s |
| [oracle_diva_csm_objects](#check-oracle-diva-csm-objects) | DIVA Managed Objects |
| [oracle_diva_csm_tapes](#check-oracle-diva-csm-tapes) | DIVA Blank Tapes |
| [oracle_instance](#check-oracle-instance) | ORA %s Instance |
| [oracle_instance_uptime](#check-oracle-instance-uptime) | ORA %s Uptime |
| [oracle_jobs](#check-oracle-jobs) | ORA %s Job |
| [oracle_locks](#check-oracle-locks) | ORA %s Locks |
| [oracle_logswitches](#check-oracle-logswitches) | ORA %s Logswitches |
| [oracle_longactivesessions](#check-oracle-longactivesessions) | ORA %s Long Active Sessions |
| [oracle_performance](#check-oracle-performance) | ORA %s Performance |
| [oracle_performance_dbtime](#check-oracle-performance-dbtime) | ORA %s Performance DB-Time |
| [oracle_performance_iostat_bytes](#check-oracle-performance-iostat-bytes) | ORA %s Performance IO Stats Bytes |
| [oracle_performance_iostat_ios](#check-oracle-performance-iostat-ios) | ORA %s Performance IO Stats Requests |
| [oracle_performance_memory](#check-oracle-performance-memory) | ORA %s Performance Memory |
| [oracle_performance_waitclasses](#check-oracle-performance-waitclasses) | ORA %s Performance System Wait |
| [oracle_processes](#check-oracle-processes) | ORA %s Processes |
| [oracle_recovery_area](#check-oracle-recovery-area) | ORA %s Recovery Area |
| [oracle_recovery_status](#check-oracle-recovery-status) | ORA %s Recovery Status |
| [oracle_rman](#check-oracle-rman) | ORA %s RMAN Backup |
| [oracle_sessions](#check-oracle-sessions) | ORA %s Sessions |
| [oracle_sql](#check-oracle-sql) | ORA %s |
| [oracle_tablespaces](#check-oracle-tablespaces) | ORA %s Tablespace |
| [oracle_undostat](#check-oracle-undostat) | ORA %s Undo Retention |
| [oracle_version](#check-oracle-version) | ORA Version %s |
| [orion_backup](#check-orion-backup) | Backup |
| [orion_batterytest](#check-orion-batterytest) | Battery Test |
| [orion_system](#check-orion-system) | Temperature %s |
| [orion_system_charging](#check-orion-system-charging) | Charge %s |
| [orion_system_dc](#check-orion-system-dc) | Direct Current %s |
| [ovs_bonding](#check-ovs-bonding) | OVS Bonding interface %s |
| [packeteer_fan_status](#check-packeteer-fan-status) | Fan Status %s |
| [packeteer_ps_status](#check-packeteer-ps-status) | Power Supply Status |
| [palo_alto](#check-palo-alto) | Palo Alto State |
| [palo_alto_users](#check-palo-alto-users) | Palo Alto Users |
| [pandacom_10gm_temp](#check-pandacom-10gm-temp) | Temperature 10GM Module %s |
| [pandacom_fan](#check-pandacom-fan) | Fan %s |
| [pandacom_fc_temp](#check-pandacom-fc-temp) | Temperature FC Module %s |
| [pandacom_psu](#check-pandacom-psu) | Power Supply %s |
| [pandacom_sys_temp](#check-pandacom-sys-temp) | Temperature %s |
| [papouch_th2e_sensors](#check-papouch-th2e-sensors) | Temperature %s |
| [papouch_th2e_sensors_dewpoint](#check-papouch-th2e-sensors-dewpoint) | Dew point %s |
| [papouch_th2e_sensors_humidity](#check-papouch-th2e-sensors-humidity) | Humidity %s |
| [pdu_gude](#check-pdu-gude) | Phase %s |
| [pfsense_counter](#check-pfsense-counter) | pfSense Firewall Packet Rates |
| [pfsense_if](#check-pfsense-if) | Firewall Interface %s |
| [pfsense_status](#check-pfsense-status) | pfSense Status |
| [plesk_backups](#check-plesk-backups) | Plesk Backup %s |
| [plesk_domains](#check-plesk-domains) | Plesk Domains |
| [podman_container_cpu_utilization](#check-podman-container-cpu-utilization) | CPU utilization |
| [podman_container_diskstat](#check-podman-container-diskstat) | Container IO %s |
| [podman_container_health](#check-podman-container-health) | Health |
| [podman_container_memory](#check-podman-container-memory) | Memory |
| [podman_container_restarts](#check-podman-container-restarts) | Restarts |
| [podman_container_status](#check-podman-container-status) | Status |
| [podman_container_uptime](#check-podman-container-uptime) | Uptime |
| [podman_containers](#check-podman-containers) | Podman containers |
| [podman_disk_usage](#check-podman-disk-usage) | Podman disk usage: %s |
| [podman_pods](#check-podman-pods) | Podman pods |
| [podman_status](#check-podman-status) | Podman status |
| [poseidon_inputs](#check-poseidon-inputs) | %s |
| [poseidon_temp](#check-poseidon-temp) | Temperatur: %s |
| [postfix_mailq](#check-postfix-mailq) | Postfix Queue %s |
| [postfix_mailq_status](#check-postfix-mailq-status) | Postfix status %s |
| [postgres_bloat](#check-postgres-bloat) | PostgreSQL Bloat %s |
| [postgres_conn_time](#check-postgres-conn-time) | PostgreSQL Connection Time %s |
| [postgres_connections](#check-postgres-connections) | PostgreSQL Connections %s |
| [postgres_instances](#check-postgres-instances) | PostgreSQL Instance %s |
| [postgres_locks](#check-postgres-locks) | PostgreSQL Locks %s |
| [postgres_processes](#check-postgres-processes) | PostgreSQL Process Count |
| [postgres_query_duration](#check-postgres-query-duration) | PostgreSQL Query Duration %s |
| [postgres_sessions](#check-postgres-sessions) | PostgreSQL Daemon Sessions %s |
| [postgres_stat_database](#check-postgres-stat-database) | PostgreSQL DB %s Statistics |
| [postgres_stat_database_size](#check-postgres-stat-database-size) | PostgreSQL DB %s Size |
| [postgres_stats](#check-postgres-stats) | PostgreSQL %s |
| [primekey_cpu_temperature](#check-primekey-cpu-temperature) | Temperature PrimeKey %s |
| [primekey_data](#check-primekey-data) | PrimeKey %s Status |
| [primekey_db_usage](#check-primekey-db-usage) | PrimeKey DB Usage |
| [primekey_fan](#check-primekey-fan) | PrimeKey Fan %s |
| [primekey_hsm_battery_voltage](#check-primekey-hsm-battery-voltage) | PrimeKey HSM Battery %s |
| [printer_alerts](#check-printer-alerts) | Alerts |
| [printer_input](#check-printer-input) | Input %s |
| [printer_output](#check-printer-output) | Output %s |
| [printer_pages](#check-printer-pages) | Pages |
| [printer_pages_ricoh](#check-printer-pages-ricoh) | Pages |
| [printer_supply_ricoh](#check-printer-supply-ricoh) | Supply %s |
| [prometheus_build](#check-prometheus-build) | Prometheus Build Check |
| [ps](#check-ps) | Process %s |
| [pse_poe](#check-pse-poe) | POE%s consumption |
| [pulse_secure_cpu_util](#check-pulse-secure-cpu-util) | Pulse Secure IVE CPU utilization |
| [pulse_secure_disk_util](#check-pulse-secure-disk-util) | Pulse Secure disk utilization |
| [pulse_secure_log_util](#check-pulse-secure-log-util) | Pulse Secure log file utilization |
| [pulse_secure_mem_util](#check-pulse-secure-mem-util) | Pulse Secure IVE memory utilization |
| [pulse_secure_temp](#check-pulse-secure-temp) | Pulse Secure %s Temperature |
| [pulse_secure_users](#check-pulse-secure-users) | Pulse Secure users |
| [pvecm_nodes](#check-pvecm-nodes) | PVE Node %s |
| [pvecm_status](#check-pvecm-status) | PVE Cluster State |
| [qlogic_fcport](#check-qlogic-fcport) | FC Port %s |
| [qlogic_sanbox_fabric_element](#check-qlogic-sanbox-fabric-element) | Fabric Element %s |
| [qlogic_sanbox_psu](#check-qlogic-sanbox-psu) | PSU %s |
| [qlogic_sanbox_temp](#check-qlogic-sanbox-temp) | Temperature Sensor %s |
| [qmail_stats](#check-qmail-stats) | Qmail Queue |
| [quanta_fan](#check-quanta-fan) | Fan %s |
| [quanta_temperature](#check-quanta-temperature) | Temperature %s |
| [quanta_voltage](#check-quanta-voltage) | Voltage %s |
| [quantum_libsmall_door](#check-quantum-libsmall-door) | Tape library door |
| [quantum_libsmall_status](#check-quantum-libsmall-status) | Tape library status |
| [quantum_storage_status](#check-quantum-storage-status) | Device status |
| [ra32e_sensors](#check-ra32e-sensors) | Temperature %s |
| [ra32e_sensors_humidity](#check-ra32e-sensors-humidity) | Humidity %s |
| [ra32e_sensors_power](#check-ra32e-sensors-power) | Power State %s |
| [ra32e_sensors_voltage](#check-ra32e-sensors-voltage) | Voltage %s |
| [ra3s_internal_temperature](#check-ra3s-internal-temperature) | Temperature %s |
| [ra3s_sensors_humidity](#check-ra3s-sensors-humidity) | Humidity %s |
| [ra3s_sensors_power](#check-ra3s-sensors-power) | Power State %s |
| [ra3s_sensors_voltage](#check-ra3s-sensors-voltage) | Voltage %s |
| [raritan_px2_residual_current](#check-raritan-px2-residual-current) | Residual Current %s |
| [rds_licenses](#check-rds-licenses) | RDS Licenses %s |
| [redis_info](#check-redis-info) | Redis %s Server Info |
| [redis_info_clients](#check-redis-info-clients) | Redis %s Clients |
| [redis_info_persistence](#check-redis-info-persistence) | Redis %s Persistence |
| [rmon_stats](#check-rmon-stats) | RMON Stats IF %s |
| [rms200_temp](#check-rms200-temp) | Temperature %s |
| [rstcli](#check-rstcli) | RAID Volume %s |
| [rstcli_pdisks](#check-rstcli-pdisks) | RAID Disk %s |
| [ruckus_spot_ap](#check-ruckus-spot-ap) | Ruckus Spot Access Points %s |
| [safenet_hsm](#check-safenet-hsm) | HSM Operation Stats |
| [safenet_hsm_events](#check-safenet-hsm-events) | HSM Safenet Event Stats |
| [safenet_ntls](#check-safenet-ntls) | NTLS Operation Status |
| [safenet_ntls_clients](#check-safenet-ntls-clients) | NTLS Clients |
| [safenet_ntls_connrate](#check-safenet-ntls-connrate) | NTLS Connection Rate: %s |
| [safenet_ntls_expiration](#check-safenet-ntls-expiration) | NTLS Expiration Date |
| [safenet_ntls_links](#check-safenet-ntls-links) | NTLS Links |
| [salesforce_instances](#check-salesforce-instances) | Salesforce Instance %s |
| [sansymphony_alerts](#check-sansymphony-alerts) | sansymphony Alerts |
| [sansymphony_pool](#check-sansymphony-pool) | Sansymphony Pool %s |
| [sansymphony_ports](#check-sansymphony-ports) | sansymphony Port %s |
| [sansymphony_serverstatus](#check-sansymphony-serverstatus) | sansymphony Serverstatus |
| [sansymphony_virtualdiskstatus](#check-sansymphony-virtualdiskstatus) | sansymphony Virtual Disk %s |
| [sap_dialog](#check-sap-dialog) | %s Dialog |
| [sap_hana_backup](#check-sap-hana-backup) | SAP HANA Backup %s |
| [sap_hana_connect](#check-sap-hana-connect) | SAP HANA CONNECT %s |
| [sap_hana_data_volume](#check-sap-hana-data-volume) | SAP HANA Volume %s |
| [sap_hana_db_status](#check-sap-hana-db-status) | SAP HANA Database Status %s |
| [sap_hana_diskusage](#check-sap-hana-diskusage) | SAP HANA Disk %s |
| [sap_hana_ess](#check-sap-hana-ess) | SAP HANA ESS %s |
| [sap_hana_ess_migration](#check-sap-hana-ess-migration) | SAP HANA ESS Migration %s |
| [sap_hana_events](#check-sap-hana-events) | SAP HANA Events %s |
| [sap_hana_fileinfo](#check-sap-hana-fileinfo) | File %s |
| [sap_hana_fileinfo_groups](#check-sap-hana-fileinfo-groups) | File group %s |
| [sap_hana_instance_status](#check-sap-hana-instance-status) | SAP HANA Instance Status %s |
| [sap_hana_license](#check-sap-hana-license) | SAP HANA License %s |
| [sap_hana_memrate](#check-sap-hana-memrate) | SAP HANA Memory %s |
| [sap_hana_proc](#check-sap-hana-proc) | SAP HANA Process %s |
| [sap_hana_replication_status](#check-sap-hana-replication-status) | SAP HANA Replication Status %s |
| [sap_hana_status](#check-sap-hana-status) | SAP HANA %s |
| [sap_value](#check-sap-value) | %s |
| [sap_value_groups](#check-sap-value-groups) | %s |
| [scaleio_devices](#check-scaleio-devices) | ScaleIO Data Server %s Devices |
| [scaleio_mdm](#check-scaleio-mdm) | ScaleIO cluster status |
| [scaleio_pd](#check-scaleio-pd) | ScaleIO PD capacity %s |
| [scaleio_pd_status](#check-scaleio-pd-status) | ScaleIO PD status %s |
| [scaleio_sds](#check-scaleio-sds) | ScaleIO SDS capacity %s |
| [scaleio_sds_status](#check-scaleio-sds-status) | ScaleIO SDS status %s |
| [scaleio_storage_pool](#check-scaleio-storage-pool) | ScaleIO SP capacity %s |
| [scaleio_storage_pool_rebalancerw](#check-scaleio-storage-pool-rebalancerw) | ScaleIO SP rebalance IO %s |
| [scaleio_storage_pool_totalrw](#check-scaleio-storage-pool-totalrw) | ScaleIO SP total IO %s |
| [scaleio_system](#check-scaleio-system) | ScaleIO System %s |
| [scaleio_volume](#check-scaleio-volume) | ScaleIO Volume %s |
| [security_master](#check-security-master) | Sensor %s |
| [security_master_humidity](#check-security-master-humidity) | Sensor %s |
| [security_master_temp](#check-security-master-temp) | Sensor %s |
| [seh_ports](#check-seh-ports) | Port %s |
| [sensatronics_temp](#check-sensatronics-temp) | Temperature %s |
| [sentry_pdu](#check-sentry-pdu) | Plug %s |
| [sentry_pdu_outlets](#check-sentry-pdu-outlets) | Outlet %s |
| [sentry_pdu_outlets_v4](#check-sentry-pdu-outlets-v4) | Outlet %s |
| [sentry_pdu_v4](#check-sentry-pdu-v4) | Plug %s |
| [services](#check-services) | Service %s |
| [services_summary](#check-services-summary) | Service Summary |
| [sftp](#check-sftp) |  |
| [siemens_plc_counter](#check-siemens-plc-counter) | Counter %s |
| [siemens_plc_cpu_state](#check-siemens-plc-cpu-state) | CPU state |
| [siemens_plc_duration](#check-siemens-plc-duration) | Duration %s |
| [siemens_plc_flag](#check-siemens-plc-flag) | Flag %s |
| [siemens_plc_info](#check-siemens-plc-info) | Info %s |
| [siemens_plc_temp](#check-siemens-plc-temp) | Temperature %s |
| [silverpeak_VX6000](#check-silverpeak-vx6000) | Alarms |
| [site_object_counts](#check-site-object-counts) | OMD objects |
| [skype](#check-skype) | Skype Web Components |
| [skype_conferencing](#check-skype-conferencing) | Skype Conferencing |
| [skype_data_proxy](#check-skype-data-proxy) | Skype Data Proxy %s |
| [skype_edge](#check-skype-edge) | Skype AV Edge %s |
| [skype_edge_auth](#check-skype-edge-auth) | Skype Edge Authentification |
| [skype_mcu](#check-skype-mcu) | Skype MCU Health |
| [skype_mediation_server](#check-skype-mediation-server) | Skype Mediation Server |
| [skype_mobile](#check-skype-mobile) | Skype Mobile Sessions |
| [skype_sip_stack](#check-skype-sip-stack) | Skype SIP Stack |
| [skype_xmpp_proxy](#check-skype-xmpp-proxy) | Skype XMPP Proxy |
| [smart_ata_stats](#check-smart-ata-stats) | SMART %s Stats |
| [smart_ata_temp](#check-smart-ata-temp) | Temperature SMART %s |
| [smart_nvme_stats](#check-smart-nvme-stats) | SMART %s Stats |
| [smart_nvme_temp](#check-smart-nvme-temp) | Temperature SMART %s |
| [smart_scsi_temp](#check-smart-scsi-temp) | Temperature SMART %s |
| [smtp](#check-smtp) |  |
| [sni_octopuse_cpu](#check-sni-octopuse-cpu) | CPU utilization |
| [sni_octopuse_status](#check-sni-octopuse-status) | Global status |
| [sni_octopuse_trunks](#check-sni-octopuse-trunks) | Trunk Port %s |
| [snmp_info](#check-snmp-info) | SNMP Info |
| [solaris_fmadm](#check-solaris-fmadm) | FMD Status |
| [solaris_multipath](#check-solaris-multipath) | Multipath %s |
| [solaris_prtdiag_status](#check-solaris-prtdiag-status) | Hardware Overall State |
| [solaris_services](#check-solaris-services) | SMF Service %s |
| [solaris_services_summary](#check-solaris-services-summary) | SMF Services Summary |
| [sql](#check-sql) |  |
| [ssh](#check-ssh) |  |
| [sshd_config](#check-sshd-config) | SSH daemon configuration |
| [statgrab_cpu](#check-statgrab-cpu) | CPU utilization |
| [storcli_cache_vault](#check-storcli-cache-vault) | RAID cache vault %s |
| [storcli_pdisks](#check-storcli-pdisks) | RAID PDisk EID:Slot-Device %s |
| [storcli_vdrives](#check-storcli-vdrives) | RAID Virtual Drive %s |
| [storeonce4x_appliances](#check-storeonce4x-appliances) | Appliance %s Status |
| [storeonce4x_appliances_license](#check-storeonce4x-appliances-license) | Appliance %s License |
| [storeonce4x_appliances_storage](#check-storeonce4x-appliances-storage) | Appliance %s Storage |
| [storeonce4x_appliances_summaries](#check-storeonce4x-appliances-summaries) | Appliance %s Summaries |
| [storeonce4x_cat_stores](#check-storeonce4x-cat-stores) | Catalyst Stores %s |
| [storeonce_clusterinfo](#check-storeonce-clusterinfo) | %s |
| [storeonce_clusterinfo_cluster](#check-storeonce-clusterinfo-cluster) | Appliance Status |
| [storeonce_clusterinfo_space](#check-storeonce-clusterinfo-space) | %s |
| [storeonce_clusterinfo_uptime](#check-storeonce-clusterinfo-uptime) | Uptime |
| [storeonce_servicesets](#check-storeonce-servicesets) | ServiceSet %s Status |
| [storeonce_servicesets_capacity](#check-storeonce-servicesets-capacity) | ServiceSet %s Capacity |
| [storeonce_stores](#check-storeonce-stores) | %s |
| [stormshield_cluster](#check-stormshield-cluster) | HA Status |
| [stormshield_cluster_node](#check-stormshield-cluster-node) | HA Member %s |
| [stormshield_cpu_temp](#check-stormshield-cpu-temp) | CPU Temp %s |
| [stormshield_disk](#check-stormshield-disk) | Disk %s |
| [stormshield_info](#check-stormshield-info) | Stormshield Info |
| [stormshield_packets](#check-stormshield-packets) | Packet Stats %s |
| [stormshield_policy](#check-stormshield-policy) | Policy %s |
| [stormshield_route](#check-stormshield-route) | Gateway %s |
| [stormshield_services](#check-stormshield-services) | Service %s |
| [stormshield_updates](#check-stormshield-updates) | Autoupdate %s |
| [strem1_sensors](#check-strem1-sensors) | Sensor - %s |
| [supermicro](#check-supermicro) | Overall Hardware Health |
| [supermicro_sensors](#check-supermicro-sensors) | Sensor %s |
| [supermicro_smart](#check-supermicro-smart) | SMART Health %s |
| [superstack3_sensors](#check-superstack3-sensors) | %s |
| [suseconnect](#check-suseconnect) | SLES license |
| [sylo](#check-sylo) | Sylo |
| [sym_brightmail_queues](#check-sym-brightmail-queues) | Queue %s |
| [symantec_av_progstate](#check-symantec-av-progstate) | AV Program Status |
| [symantec_av_quarantine](#check-symantec-av-quarantine) | AV Quarantine |
| [symantec_av_updates](#check-symantec-av-updates) | AV Update Status |
| [synology_disks](#check-synology-disks) | Disks %s |
| [synology_fans](#check-synology-fans) | Fan %s |
| [synology_info](#check-synology-info) | Info |
| [synology_raid](#check-synology-raid) | Raid %s |
| [synology_status](#check-synology-status) | Status |
| [synology_update](#check-synology-update) | Update |
| [systemd_units_services](#check-systemd-units-services) | Systemd Service %s |
| [systemd_units_services_summary](#check-systemd-units-services-summary) | Systemd Service Summary |
| [systemd_units_sockets](#check-systemd-units-sockets) | Systemd Socket %s |
| [systemd_units_sockets_summary](#check-systemd-units-sockets-summary) | Systemd Socket Summary |
| [systemtime](#check-systemtime) | System Time |
| [tcp](#check-tcp) |  |
| [tcp_conn_stats](#check-tcp-conn-stats) | TCP Connections |
| [teracom_tcw241_analog](#check-teracom-tcw241-analog) | Analog Sensor %s |
| [teracom_tcw241_digital](#check-teracom-tcw241-digital) | Digital Sensor %s |
| [timemachine](#check-timemachine) |  |
| [timesyncd](#check-timesyncd) | Systemd Timesyncd Time |
| [traceroute](#check-traceroute) |  |
| [tsm_drives](#check-tsm-drives) | TSM Drive %s |
| [tsm_paths](#check-tsm-paths) | TSM Paths |
| [tsm_scratch](#check-tsm-scratch) | Scratch Pool %s |
| [tsm_sessions](#check-tsm-sessions) | tsm_sessions |
| [tsm_stagingpools](#check-tsm-stagingpools) | TSM Stagingpool %s |
| [tsm_storagepools](#check-tsm-storagepools) | TSM Storagepool %s |
| [ucd_cpu_util](#check-ucd-cpu-util) | CPU utilization |
| [ucd_disk](#check-ucd-disk) | Filesystem %s |
| [ucd_diskio](#check-ucd-diskio) | Disk IO %s |
| [ucd_processes](#check-ucd-processes) | Processes %s |
| [uniserv](#check-uniserv) |  |
| [unitrends_backup](#check-unitrends-backup) | Schedule %s |
| [unitrends_replication](#check-unitrends-replication) | Replicaion %s |
| [ups_bat_temp](#check-ups-bat-temp) | Temperature %s |
| [ups_battery_state](#check-ups-battery-state) | Battery state |
| [ups_capacity](#check-ups-capacity) | Battery capacity |
| [ups_cps_battery](#check-ups-cps-battery) | UPS Battery |
| [ups_cps_battery_temp](#check-ups-cps-battery-temp) | Temperature %s |
| [ups_cps_inphase](#check-ups-cps-inphase) | UPS Input Phase %s |
| [ups_cps_outphase](#check-ups-cps-outphase) | UPS Output Phase %s |
| [ups_eaton_enviroment](#check-ups-eaton-enviroment) | Enviroment |
| [ups_in_freq](#check-ups-in-freq) | IN frequency phase %s |
| [ups_in_voltage](#check-ups-in-voltage) | IN voltage phase %s |
| [ups_modulys_alarms](#check-ups-modulys-alarms) | UPS Alarms |
| [ups_modulys_battery](#check-ups-modulys-battery) | Battery Charge |
| [ups_modulys_battery_temp](#check-ups-modulys-battery-temp) | Temperature %s |
| [ups_modulys_inphase](#check-ups-modulys-inphase) | Input %s |
| [ups_modulys_outphase](#check-ups-modulys-outphase) | Output %s |
| [ups_out_load](#check-ups-out-load) | OUT load phase %s |
| [ups_out_voltage](#check-ups-out-voltage) | OUT voltage phase %s |
| [ups_socomec_capacity](#check-ups-socomec-capacity) | Battery capacity |
| [ups_socomec_in_voltage](#check-ups-socomec-in-voltage) | IN voltage phase %s |
| [ups_socomec_out_source](#check-ups-socomec-out-source) | Output Source |
| [ups_socomec_out_voltage](#check-ups-socomec-out-voltage) | OUT voltage phase %s |
| [ups_socomec_outphase](#check-ups-socomec-outphase) | Output %s |
| [ups_test](#check-ups-test) | Self Test |
| [varnish](#check-varnish) | Varnish Uptime |
| [varnish_backend](#check-varnish-backend) | Varnish Backend |
| [varnish_cache](#check-varnish-cache) | Varnish Cache |
| [varnish_cache_hit_ratio](#check-varnish-cache-hit-ratio) | Varnish Cache Hit Ratio |
| [varnish_client](#check-varnish-client) | Varnish Client |
| [varnish_esi](#check-varnish-esi) | Varnish ESI |
| [varnish_fetch](#check-varnish-fetch) | Varnish Fetch |
| [varnish_objects](#check-varnish-objects) | Varnish Objects |
| [varnish_worker](#check-varnish-worker) | Varnish Worker |
| [varnish_worker_thread_ratio](#check-varnish-worker-thread-ratio) | Varnish Worker Thread Ratio |
| [vbox_guest](#check-vbox-guest) | VBox Guest Additions |
| [veeam_cdp_jobs](#check-veeam-cdp-jobs) | VEEAM CDP Job %s |
| [veeam_jobs](#check-veeam-jobs) | VEEAM Job %s |
| [veeam_tapejobs](#check-veeam-tapejobs) | VEEAM Tape Job %s |
| [veritas_vcs](#check-veritas-vcs) | VCS Cluster %s |
| [veritas_vcs_resource](#check-veritas-vcs-resource) | VCS Resource %s |
| [veritas_vcs_servicegroup](#check-veritas-vcs-servicegroup) | VCS Service Group %s |
| [veritas_vcs_system](#check-veritas-vcs-system) | VCS System %s |
| [viprinet_firmware](#check-viprinet-firmware) | Firmware Version |
| [viprinet_mem](#check-viprinet-mem) | Memory |
| [vms_cpu](#check-vms-cpu) | CPU utilization |
| [vms_diskstat_df](#check-vms-diskstat-df) | Filesystem %s |
| [vms_system_ios](#check-vms-system-ios) | IOs |
| [vms_system_procs](#check-vms-system-procs) | Number of processes |
| [vms_users](#check-vms-users) | VMS Users |
| [vnx_quotas](#check-vnx-quotas) | VNX Quota %s |
| [vutlan_ems_smoke](#check-vutlan-ems-smoke) | Smoke Detector %s |
| [vxvm_enclosures](#check-vxvm-enclosures) | Enclosure %s |
| [vxvm_multipath](#check-vxvm-multipath) | Multipath %s |
| [vxvm_objstatus](#check-vxvm-objstatus) | VXVM objstatus %s |
| [w32time_status](#check-w32time-status) | Windows time service |
| [wagner_titanus_topsense_airflow_deviation](#check-wagner-titanus-topsense-airflow-deviation) | Airflow Deviation Detector %s |
| [wagner_titanus_topsense_alarm](#check-wagner-titanus-topsense-alarm) | Alarm Detector %s |
| [wagner_titanus_topsense_chamber_deviation](#check-wagner-titanus-topsense-chamber-deviation) | Chamber Deviation Detector %s |
| [wagner_titanus_topsense_info](#check-wagner-titanus-topsense-info) | Topsense Info |
| [wagner_titanus_topsense_overall_status](#check-wagner-titanus-topsense-overall-status) | Overall Status |
| [wagner_titanus_topsense_smoke](#check-wagner-titanus-topsense-smoke) | Smoke Detector %s |
| [wagner_titanus_topsense_temp](#check-wagner-titanus-topsense-temp) | Temperature %s |
| [watchdog_sensors](#check-watchdog-sensors) | %s |
| [watchdog_sensors_dew](#check-watchdog-sensors-dew) | %s |
| [watchdog_sensors_humidity](#check-watchdog-sensors-humidity) | %s |
| [watchdog_sensors_temp](#check-watchdog-sensors-temp) | %s |
| [win_dhcp_pools](#check-win-dhcp-pools) | DHCP Pool %s |
| [win_dhcp_pools_stats](#check-win-dhcp-pools-stats) | DHCP Stats |
| [win_license](#check-win-license) | Windows License |
| [win_netstat](#check-win-netstat) | TCP Connection %s |
| [win_printers](#check-win-printers) | Printer %s |
| [windows_broadcom_bonding](#check-windows-broadcom-bonding) | Bonding Interface %s |
| [windows_intel_bonding](#check-windows-intel-bonding) | Bonding interface %s |
| [windows_multipath](#check-windows-multipath) | Multipath |
| [windows_tasks](#check-windows-tasks) | Task %s |
| [windows_updates](#check-windows-updates) | System Updates |
| [winperf_if](#check-winperf-if) | Interface %s |
| [winperf_mem](#check-winperf-mem) | Memory Pages |
| [winperf_msx_queues](#check-winperf-msx-queues) | Queue %s |
| [winperf_phydisk](#check-winperf-phydisk) | Disk IO %s |
| [winperf_ts_sessions](#check-winperf-ts-sessions) | Sessions |
| [wmi_webservices](#check-wmi-webservices) | Web Service %s |
| [wmic_process](#check-wmic-process) | Process %s |
| [wut_webio](#check-wut-webio) | Check plug-in for W&T WebIO device |
| [wut_webtherm](#check-wut-webtherm) | Temperature %s |
| [wut_webtherm_pressure](#check-wut-webtherm-pressure) | Pressure %s |
| [zebra_model](#check-zebra-model) | Zebra Printer Model |
| [zebra_printer_status](#check-zebra-printer-status) | Zebra Printer Status |
| [zertificon_mail_queues](#check-zertificon-mail-queues) | Zertificon Mail Queues |
| [zerto_agent](#check-zerto-agent) | Zerto Agent Status |
| [zerto_vpg_rpo](#check-zerto-vpg-rpo) | Zerto VPG RPO %s |
| [zfs_arc_cache](#check-zfs-arc-cache) | ZFS arc cache |
| [zfs_arc_cache_l2](#check-zfs-arc-cache-l2) | ZFS arc cache L2 |
| [zfsget](#check-zfsget) | Filesystem %s |
| [zorp_connections](#check-zorp-connections) | Zorp FW - connections |
| [zpool](#check-zpool) | Storage Pool %s |
| [zpool_status](#check-zpool-status) | zpool status |
| [zypper](#check-zypper) | Zypper Updates |

### adva_fsp_if

<a id="check-adva-fsp-if"></a>

*Interface %s*

### akcp_sensor_temp

<a id="check-akcp-sensor-temp"></a>

*Temperature %s*

### alcatel_timetra_chassis

<a id="check-alcatel-timetra-chassis"></a>

*Device %s*

### allnet_ip_sensoric_tension

<a id="check-allnet-ip-sensoric-tension"></a>

*Electric Tension %s*

### apc_ats_status

<a id="check-apc-ats-status"></a>

*ATS Status*

### apc_mod_pdu_modules

<a id="check-apc-mod-pdu-modules"></a>

*Module %s*

### apc_symmetra_input

<a id="check-apc-symmetra-input"></a>

*Phase %s*

### arcserve_backup

<a id="check-arcserve-backup"></a>

*Arcserve Backup %s*

### arris_cmts_mem

<a id="check-arris-cmts-mem"></a>

*Memory Module %s*

### audiocodes_ipgroup

<a id="check-audiocodes-ipgroup"></a>

*IP group %s*

### audiocodes_system_events

<a id="check-audiocodes-system-events"></a>

*System events*

### bgp_peer

<a id="check-bgp-peer"></a>

*This is how an Arista BGP SNMP message is constructed:*

### bluecoat_sensors

<a id="check-bluecoat-sensors"></a>

*%s*

### bluecoat_sensors_temp

<a id="check-bluecoat-sensors-temp"></a>

*Temperature %s*

### bluenet_sensor

<a id="check-bluenet-sensor"></a>

*Temperature %s*

### brocade_fcport

<a id="check-brocade-fcport"></a>

*Port %s*

### brocade_mlx_module_cpu

<a id="check-brocade-mlx-module-cpu"></a>

*CPU utilization Module %s*

### brocade_optical

<a id="check-brocade-optical"></a>

*Interface %s Optical*

### brocade_sfp

<a id="check-brocade-sfp"></a>

*SFP %s*

### brocade_sfp_temp

<a id="check-brocade-sfp-temp"></a>

*SFP Temperature %s*

### brocade_tm

<a id="check-brocade-tm"></a>

*TM %s*

### bvip_fans

<a id="check-bvip-fans"></a>

*Fan %s*

### cadvisor_cpu

<a id="check-cadvisor-cpu"></a>

*CPU utilization*

### cadvisor_if

<a id="check-cadvisor-if"></a>

*Interface %s*

### carel_sensors

<a id="check-carel-sensors"></a>

*Temperature %s*

### casa_power

<a id="check-casa-power"></a>

*Power %s*

### cephdfclass

<a id="check-cephdfclass"></a>

*Ceph Class %s*

### cephstatus

<a id="check-cephstatus"></a>

*Ceph %s*

### checkpoint_ha_problems

<a id="check-checkpoint-ha-problems"></a>

*HA Problem %s*

### checkpoint_vsx_packets

<a id="check-checkpoint-vsx-packets"></a>

*VS %s Packets*

### checkpoint_vsx_traffic

<a id="check-checkpoint-vsx-traffic"></a>

*VS %s Traffic*

### chrony

<a id="check-chrony"></a>

*NTP Time*

### ciena_cpu_util_5171

<a id="check-ciena-cpu-util-5171"></a>

*CPU utilization*

### cifsmounts

<a id="check-cifsmounts"></a>

*CIFS mount %s*

### cisco_ace_rserver

<a id="check-cisco-ace-rserver"></a>

*ACE RServer %s*

### cisco_asa_conn

<a id="check-cisco-asa-conn"></a>

*Connection %s*

### cisco_meraki_org_appliance_uplinks

<a id="check-cisco-meraki-org-appliance-uplinks"></a>

*Uplink %s*

### cisco_meraki_org_device_status

<a id="check-cisco-meraki-org-device-status"></a>

*Device Status*

### cisco_meraki_org_sensor_battery

<a id="check-cisco-meraki-org-sensor-battery"></a>

*Cisco Meraki Battery Percentage %s*

### cisco_meraki_org_sensor_humidity

<a id="check-cisco-meraki-org-sensor-humidity"></a>

*Cisco Meraki Humidity Relative Percentage %s*

### cisco_meraki_org_sensor_temperature

<a id="check-cisco-meraki-org-sensor-temperature"></a>

*Cisco Meraki Temperature %s*

### cisco_meraki_org_switch_ports_statuses

<a id="check-cisco-meraki-org-switch-ports-statuses"></a>

*Interface %s*

### cisco_power

<a id="check-cisco-power"></a>

*Power %s*

### cisco_qos

<a id="check-cisco-qos"></a>

*QoS %s*

### cisco_secure

<a id="check-cisco-secure"></a>

*Port Security*

### cisco_sma_resource_conservation

<a id="check-cisco-sma-resource-conservation"></a>

*Resource conservation*

### cisco_temperature

<a id="check-cisco-temperature"></a>

*Temperature %s*

### cisco_ucs_hdd

<a id="check-cisco-ucs-hdd"></a>

*HDD %s*

### cisco_ucs_mem

<a id="check-cisco-ucs-mem"></a>

*Memory %s*

### cisco_vpn_tunnel

<a id="check-cisco-vpn-tunnel"></a>

*VPN Tunnel %s*

### citrix_licenses

<a id="check-citrix-licenses"></a>

*Citrix Licenses %s*

### citrix_serverload

<a id="check-citrix-serverload"></a>

*Citrix Serverload*

### citrix_sessions

<a id="check-citrix-sessions"></a>

*Citrix Sessions*

### citrix_state

<a id="check-citrix-state"></a>

*Citrix Instance State*

### citrix_state_controller

<a id="check-citrix-state-controller"></a>

*Citrix Controller*

### citrix_state_hosting_server

<a id="check-citrix-state-hosting-server"></a>

*Citrix Hosting Server*

### climaveneta_alarm

<a id="check-climaveneta-alarm"></a>

*Alarm Status*

### climaveneta_fan

<a id="check-climaveneta-fan"></a>

*Fan %s*

### climaveneta_temp

<a id="check-climaveneta-temp"></a>

*Temperature %s*

### cmc_temp

<a id="check-cmc-temp"></a>

*Temperature Sensor %s*

### cmciii

<a id="check-cmciii"></a>

*State %s*

### cmciii_access

<a id="check-cmciii-access"></a>

*%s*

### cmciii_can_current

<a id="check-cmciii-can-current"></a>

*%s*

### cmciii_humidity

<a id="check-cmciii-humidity"></a>

*%s*

### cmciii_lcp_water

<a id="check-cmciii-lcp-water"></a>

*Temperature Water LCP %s*

### cmciii_phase

<a id="check-cmciii-phase"></a>

*Input %s*

### cmciii_psm_current

<a id="check-cmciii-psm-current"></a>

*Current %s*

### cmctc_config

<a id="check-cmctc-config"></a>

*TC configuration*

### cmctc_lcp_flow

<a id="check-cmctc-lcp-flow"></a>

*Waterflow %s*

### cmctc_lcp_humidity

<a id="check-cmctc-lcp-humidity"></a>

*Humidity %s*

### cmctc_temp

<a id="check-cmctc-temp"></a>

*Temperature %s*

### corosync_latency

<a id="check-corosync-latency"></a>

*Corosync Latency %s*

### couchbase_buckets_vbuckets_replica

<a id="check-couchbase-buckets-vbuckets-replica"></a>

*Couchbase Bucket %s replica vBuckets*

### couchbase_nodes_info

<a id="check-couchbase-nodes-info"></a>

*Couchbase %s Info*

### couchbase_nodes_items

<a id="check-couchbase-nodes-items"></a>

*Couchbase %s vBucket items*

### couchbase_nodes_operations

<a id="check-couchbase-nodes-operations"></a>

*Couchbase %s Operations*

### couchbase_nodes_operations_total

<a id="check-couchbase-nodes-operations-total"></a>

*Couchbase Total Operations*

### couchbase_nodes_services

<a id="check-couchbase-nodes-services"></a>

*Couchbase %s Services*

### couchbase_nodes_size_couch_views

<a id="check-couchbase-nodes-size-couch-views"></a>

*Couchbase %s Couch Views*

### couchbase_nodes_size_docs

<a id="check-couchbase-nodes-size-docs"></a>

*Couchbase %s Documents*

### couchbase_nodes_size_spacial_views

<a id="check-couchbase-nodes-size-spacial-views"></a>

*Couchbase %s Spacial Views*

### couchbase_nodes_stats_cpu_util

<a id="check-couchbase-nodes-stats-cpu-util"></a>

*Couchbase %s CPU utilization*

### couchbase_nodes_stats_mem

<a id="check-couchbase-nodes-stats-mem"></a>

*Couchbase %s Memory*

### couchbase_nodes_uptime

<a id="check-couchbase-nodes-uptime"></a>

*Couchbase %s Uptime*

### cpsecure_sessions

<a id="check-cpsecure-sessions"></a>

*Number of %s sessions*

### cpu_loads

<a id="check-cpu-loads"></a>

*CPU load*

### cpu_threads

<a id="check-cpu-threads"></a>

*Number of threads*

### cpu_utilization_os

<a id="check-cpu-utilization-os"></a>

*CPU utilization*

### cups_queues

<a id="check-cups-queues"></a>

*CUPS Queue %s*

### datadog_events

<a id="check-datadog-events"></a>

*The main purpose of this plug-in is to ensure the regular execution of the Datadog special agent in*

### datadog_logs

<a id="check-datadog-logs"></a>

*The main purpose of this plug-in is to ensure the regular execution of the Datadog special agent in*

### datadog_monitors

<a id="check-datadog-monitors"></a>

*Datadog Monitor %s*

### datapower_fan

<a id="check-datapower-fan"></a>

*Fan %s*

### datapower_ldrive

<a id="check-datapower-ldrive"></a>

*Logical Drive %s*

### datapower_pdrive

<a id="check-datapower-pdrive"></a>

*Physical Drive %s*

### datapower_raid_bat

<a id="check-datapower-raid-bat"></a>

*Raid Battery %s*

### datapower_temp

<a id="check-datapower-temp"></a>

*Temperature %s*

### db2_backup

<a id="check-db2-backup"></a>

*DB2 Backup %s*

### db2_bp_hitratios

<a id="check-db2-bp-hitratios"></a>

*DB2 BP-Hitratios %s*

### db2_connections

<a id="check-db2-connections"></a>

*DB2 Connections %s*

### db2_counters

<a id="check-db2-counters"></a>

*DB2 Counters %s*

### db2_logsizes

<a id="check-db2-logsizes"></a>

*DB2 Logsize %s*

### db2_mem

<a id="check-db2-mem"></a>

*Memory %s*

### db2_sort_overflow

<a id="check-db2-sort-overflow"></a>

*DB2 Sort Overflow %s*

### db2_tablespaces

<a id="check-db2-tablespaces"></a>

*DB2 Tablespace %s*

### db2_version

<a id="check-db2-version"></a>

*DB2 Instance %s*

### decru_cpu

<a id="check-decru-cpu"></a>

*CPU utilization*

### decru_fans

<a id="check-decru-fans"></a>

*FAN %s*

### decru_perf

<a id="check-decru-perf"></a>

*COUNTER %s*

### decru_power

<a id="check-decru-power"></a>

*POWER %s*

### decru_temps

<a id="check-decru-temps"></a>

*Temperature %s*

### df

<a id="check-df"></a>

*Filesystem %s*

### df_netapp

<a id="check-df-netapp"></a>

*Filesystem %s*

### df_netscaler

<a id="check-df-netscaler"></a>

*Filesystem %s*

### df_zos

<a id="check-df-zos"></a>

*Filesystem %s*

### didactum_can_sensors_analog

<a id="check-didactum-can-sensors-analog"></a>

*Temperature CAN %s*

### didactum_can_sensors_analog_humidity

<a id="check-didactum-can-sensors-analog-humidity"></a>

*Humidity CAN %s*

### didactum_can_sensors_analog_voltage

<a id="check-didactum-can-sensors-analog-voltage"></a>

*Phase CAN %s*

### didactum_sensors_analog

<a id="check-didactum-sensors-analog"></a>

*Temperature %s*

### didactum_sensors_analog_humidity

<a id="check-didactum-sensors-analog-humidity"></a>

*Humidity %s*

### didactum_sensors_analog_voltage

<a id="check-didactum-sensors-analog-voltage"></a>

*Phase %s*

### didactum_sensors_discrete

<a id="check-didactum-sensors-discrete"></a>

*Discrete sensor %s*

### didactum_sensors_outlet

<a id="check-didactum-sensors-outlet"></a>

*Relay %s*

### disk_io_utilization

<a id="check-disk-io-utilization"></a>

*Disk IO Utilization*

### disk_smb

<a id="check-disk-smb"></a>

### diskstat

<a id="check-diskstat"></a>

*Disk IO %s*

### diskstat_io

<a id="check-diskstat-io"></a>

*Disk IO %s*

### diskstat_io_director

<a id="check-diskstat-io-director"></a>

*Disk IO Director %s*

### diskstat_io_volumes

<a id="check-diskstat-io-volumes"></a>

*Disk IO Volumes %s*

### dmi_sysinfo

<a id="check-dmi-sysinfo"></a>

*DMI Sysinfo*

### dmraid_ldisks

<a id="check-dmraid-ldisks"></a>

*RAID LDisk %s*

### dmraid_pdisks

<a id="check-dmraid-pdisks"></a>

*RAID PDisk %s*

### dns

<a id="check-dns"></a>

### docker_container_status

<a id="check-docker-container-status"></a>

*Docker container status*

### docker_container_status_health

<a id="check-docker-container-status-health"></a>

*Docker container health*

### docker_container_status_uptime

<a id="check-docker-container-status-uptime"></a>

*Uptime*

### docker_node_info

<a id="check-docker-node-info"></a>

*Docker node info*

### docker_node_info_containers

<a id="check-docker-node-info-containers"></a>

*Docker containers*

### docsis_channels_downstream

<a id="check-docsis-channels-downstream"></a>

*Downstream Channel %s*

### docsis_channels_upstream

<a id="check-docsis-channels-upstream"></a>

*Upstream Channel %s*

### docsis_cm_status

<a id="check-docsis-cm-status"></a>

*Cable Modem %s Status*

### domino_info

<a id="check-domino-info"></a>

*Domino Info*

### domino_mailqueues

<a id="check-domino-mailqueues"></a>

*Domino Queue %s*

### domino_tasks

<a id="check-domino-tasks"></a>

*Domino Task %s*

### domino_transactions

<a id="check-domino-transactions"></a>

*Domino Server Transactions*

### domino_users

<a id="check-domino-users"></a>

*Domino Users*

### dotnet_clrmemory

<a id="check-dotnet-clrmemory"></a>

*DotNet Memory Management %s*

### drbd

<a id="check-drbd"></a>

*DRBD %s status*

### drbd_disk

<a id="check-drbd-disk"></a>

*DRBD %s disk*

### drbd_net

<a id="check-drbd-net"></a>

*DRBD %s net*

### drbd_stats

<a id="check-drbd-stats"></a>

*DRBD %s stats*

### eltek_systemstatus

<a id="check-eltek-systemstatus"></a>

*System Status*

### emc_datadomain_disks

<a id="check-emc-datadomain-disks"></a>

*Hard Disk %s*

### emc_datadomain_fans

<a id="check-emc-datadomain-fans"></a>

*FAN %s*

### emc_datadomain_fs

<a id="check-emc-datadomain-fs"></a>

*DD-Filesystem %s*

### emc_datadomain_mtree

<a id="check-emc-datadomain-mtree"></a>

*MTree %s*

### emc_datadomain_nvbat

<a id="check-emc-datadomain-nvbat"></a>

*NVRAM Battery %s*

### emc_datadomain_power

<a id="check-emc-datadomain-power"></a>

*Power Module %s*

### emc_datadomain_temps

<a id="check-emc-datadomain-temps"></a>

*Temperature %s*

### emc_isilon_clusterhealth

<a id="check-emc-isilon-clusterhealth"></a>

*Cluster Health*

### emc_isilon_cpu

<a id="check-emc-isilon-cpu"></a>

*Node CPU utilization*

### emc_isilon_diskstatus

<a id="check-emc-isilon-diskstatus"></a>

*Disk bay %s Status*

### emc_isilon_fans

<a id="check-emc-isilon-fans"></a>

*Fan %s*

### emc_isilon_ifs

<a id="check-emc-isilon-ifs"></a>

*Filesystem %s*

### emc_isilon_iops

<a id="check-emc-isilon-iops"></a>

*Disk %s IO*

### emc_isilon_names

<a id="check-emc-isilon-names"></a>

*Isilon Info*

### emc_isilon_nodehealth

<a id="check-emc-isilon-nodehealth"></a>

*Node Health*

### emc_isilon_nodes

<a id="check-emc-isilon-nodes"></a>

*Nodes*

### emc_isilon_power

<a id="check-emc-isilon-power"></a>

*Voltage %s*

### emc_isilon_quota

<a id="check-emc-isilon-quota"></a>

*Quota %s*

### emc_isilon_temp

<a id="check-emc-isilon-temp"></a>

*Temperature %s*

### emc_isilon_temp_cpu

<a id="check-emc-isilon-temp-cpu"></a>

*Temperature %s*

### emc_vplex_cpu

<a id="check-emc-vplex-cpu"></a>

*CPU Utilization %s*

### emerson_stat

<a id="check-emerson-stat"></a>

*Status*

### emerson_temp

<a id="check-emerson-temp"></a>

*Temperature %s*

### emka_modules

<a id="check-emka-modules"></a>

*Module %s*

### emka_modules_alarm

<a id="check-emka-modules-alarm"></a>

*Alarm %s*

### emka_modules_handle

<a id="check-emka-modules-handle"></a>

*Handle %s*

### emka_modules_relay

<a id="check-emka-modules-relay"></a>

*Relay %s*

### emka_modules_sensor_humid

<a id="check-emka-modules-sensor-humid"></a>

*Humidity %s*

### emka_modules_sensor_temp

<a id="check-emka-modules-sensor-temp"></a>

*Temperature %s*

### emka_modules_sensor_volt

<a id="check-emka-modules-sensor-volt"></a>

*Phase %s*

### enterasys_cpu_util

<a id="check-enterasys-cpu-util"></a>

*CPU util %s*

### enterasys_fans

<a id="check-enterasys-fans"></a>

*FAN %s*

### enterasys_lsnat

<a id="check-enterasys-lsnat"></a>

*LSNAT Bindings*

### enterasys_powersupply

<a id="check-enterasys-powersupply"></a>

*PSU %s*

### enterasys_temp

<a id="check-enterasys-temp"></a>

*Temperature %s*

### entersekt

<a id="check-entersekt"></a>

*Entersekt Server Status*

### entersekt_certexpiry

<a id="check-entersekt-certexpiry"></a>

*Entersekt Certificate Expiration*

### entersekt_ecerterrors

<a id="check-entersekt-ecerterrors"></a>

*Entersekt http Ecert Errors*

### entersekt_emrerrors

<a id="check-entersekt-emrerrors"></a>

*Entersekt http EMR Errors*

### entersekt_soaperrors

<a id="check-entersekt-soaperrors"></a>

*Entersekt Soap Service Errors*

### entity_sensors_fan

<a id="check-entity-sensors-fan"></a>

*Fan %s*

### entity_sensors_power_presence

<a id="check-entity-sensors-power-presence"></a>

*Power %s*

### entity_sensors_temp

<a id="check-entity-sensors-temp"></a>

*Temperature %s*

### enviromux

<a id="check-enviromux"></a>

*Sensor %s*

### enviromux_all_external

<a id="check-enviromux-all-external"></a>

*Sensor External %s*

### enviromux_all_external_humidity

<a id="check-enviromux-all-external-humidity"></a>

*Sensor External %s*

### enviromux_all_external_voltage

<a id="check-enviromux-all-external-voltage"></a>

*Sensor External %s*

### enviromux_aux

<a id="check-enviromux-aux"></a>

*Sensor %s*

### enviromux_aux_humidity

<a id="check-enviromux-aux-humidity"></a>

*Sensor %s*

### enviromux_aux_voltage

<a id="check-enviromux-aux-voltage"></a>

*Sensor %s*

### enviromux_digital

<a id="check-enviromux-digital"></a>

*Digital Sensor: %s*

### enviromux_external

<a id="check-enviromux-external"></a>

*Sensor External %s*

### enviromux_external_humidity

<a id="check-enviromux-external-humidity"></a>

*Sensor External %s*

### enviromux_external_voltage

<a id="check-enviromux-external-voltage"></a>

*Sensor External %s*

### enviromux_humidity

<a id="check-enviromux-humidity"></a>

*Sensor %s*

### enviromux_micro_humidity

<a id="check-enviromux-micro-humidity"></a>

*Sensor %s*

### enviromux_micro_humidity_external

<a id="check-enviromux-micro-humidity-external"></a>

*Sensor External %s*

### enviromux_micro_temperature

<a id="check-enviromux-micro-temperature"></a>

*Sensor %s*

### enviromux_micro_temperature_external

<a id="check-enviromux-micro-temperature-external"></a>

*Sensor External %s*

### enviromux_remote_input

<a id="check-enviromux-remote-input"></a>

*Remote Input %s*

### enviromux_sems

<a id="check-enviromux-sems"></a>

*Sensor %s*

### enviromux_sems_digital

<a id="check-enviromux-sems-digital"></a>

*Digital Sensor: %s*

### enviromux_sems_e2d

<a id="check-enviromux-sems-e2d"></a>

*Sensor %s*

### enviromux_sems_e2d_digital

<a id="check-enviromux-sems-e2d-digital"></a>

*Digital Sensor: %s*

### enviromux_sems_e2d_external

<a id="check-enviromux-sems-e2d-external"></a>

*Sensor External %s*

### enviromux_sems_e2d_external_humidity

<a id="check-enviromux-sems-e2d-external-humidity"></a>

*Sensor External %s*

### enviromux_sems_e2d_external_voltage

<a id="check-enviromux-sems-e2d-external-voltage"></a>

*Sensor External %s*

### enviromux_sems_e2d_humidity

<a id="check-enviromux-sems-e2d-humidity"></a>

*Sensor %s*

### enviromux_sems_e2d_voltage

<a id="check-enviromux-sems-e2d-voltage"></a>

*Sensor %s*

### enviromux_sems_external

<a id="check-enviromux-sems-external"></a>

*Sensor External %s*

### enviromux_sems_external_humidity

<a id="check-enviromux-sems-external-humidity"></a>

*Sensor External %s*

### enviromux_sems_external_voltage

<a id="check-enviromux-sems-external-voltage"></a>

*Sensor External %s*

### enviromux_sems_humidity

<a id="check-enviromux-sems-humidity"></a>

*Sensor %s*

### enviromux_sems_voltage

<a id="check-enviromux-sems-voltage"></a>

*Sensor %s*

### enviromux_voltage

<a id="check-enviromux-voltage"></a>

*Sensor %s*

### epower

<a id="check-epower"></a>

*Power phase %s*

### epson_beamer_lamp

<a id="check-epson-beamer-lamp"></a>

*Beamer Lamp*

### etherbox2_temp

<a id="check-etherbox2-temp"></a>

*Temperature %s*

### etherbox_humidity

<a id="check-etherbox-humidity"></a>

*Sensor %s*

### etherbox_nosensor

<a id="check-etherbox-nosensor"></a>

*Sensor %s*

### etherbox_smoke

<a id="check-etherbox-smoke"></a>

*Sensor %s*

### etherbox_switch

<a id="check-etherbox-switch"></a>

*Sensor %s*

### etherbox_temp

<a id="check-etherbox-temp"></a>

*Temperature %s*

### etherbox_voltage

<a id="check-etherbox-voltage"></a>

*Sensor %s*

### ewon

<a id="check-ewon"></a>

*%s*

### extreme_vsp_switches_cpu_util

<a id="check-extreme-vsp-switches-cpu-util"></a>

*VSP Switches CPU Utilization*

### extreme_vsp_switches_fan

<a id="check-extreme-vsp-switches-fan"></a>

*VSP Switch Fan %s*

### extreme_vsp_switches_power_supply

<a id="check-extreme-vsp-switches-power-supply"></a>

*VSP Switch Power Supply %s*

### extreme_vsp_switches_temperature

<a id="check-extreme-vsp-switches-temperature"></a>

*VSP Switch %s Temperature*

### f5_bigip_cluster

<a id="check-f5-bigip-cluster"></a>

*F5-BIGIP-Cluster Config Sync - SNMP sections and Checks*

### f5_bigip_cluster_status

<a id="check-f5-bigip-cluster-status"></a>

*F5-BIGIP-Cluster-Status SNMP Sections and Checks*

### f5_bigip_cluster_status_v11_2

<a id="check-f5-bigip-cluster-status-v11-2"></a>

*F5-BIGIP-Cluster-Status SNMP Sections and Checks*

### f5_bigip_cluster_v11

<a id="check-f5-bigip-cluster-v11"></a>

*F5-BIGIP-Cluster Config Sync - SNMP sections and Checks*

### f5_bigip_pool

<a id="check-f5-bigip-pool"></a>

*Load Balancing Pool %s*

### f5_bigip_vcmpfailover

<a id="check-f5-bigip-vcmpfailover"></a>

*F5-BIGIP-Cluster-Status SNMP Sections and Checks*

### f5_bigip_vcmpguests

<a id="check-f5-bigip-vcmpguests"></a>

*F5-BIGIP-Cluster-Status SNMP Sections and Checks*

### fast_lta_headunit_replication

<a id="check-fast-lta-headunit-replication"></a>

*Fast LTA Replication*

### fast_lta_headunit_status

<a id="check-fast-lta-headunit-status"></a>

*Fast LTA Headunit Status*

### fast_lta_silent_cubes_capacity

<a id="check-fast-lta-silent-cubes-capacity"></a>

*Fast LTA SC Capacity %s*

### fast_lta_volumes

<a id="check-fast-lta-volumes"></a>

*Fast LTA Volume %s*

### fc_port

<a id="check-fc-port"></a>

*FC Interface %s*

### filehandler

<a id="check-filehandler"></a>

*Filehandler*

### fileinfo

<a id="check-fileinfo"></a>

*File %s*

### fileinfo_groups

<a id="check-fileinfo-groups"></a>

*File group %s*

### filestats

<a id="check-filestats"></a>

*File group %s*

### filestats_single

<a id="check-filestats-single"></a>

*File %s*

### fireeye_bypass

<a id="check-fireeye-bypass"></a>

*Bypass Mail Rate*

### fireeye_sys_status

<a id="check-fireeye-sys-status"></a>

*System status*

### fjdarye_ca_ports

<a id="check-fjdarye-ca-ports"></a>

*CA Port IO %s*

### fjdarye_ce_power_supply_units

<a id="check-fjdarye-ce-power-supply-units"></a>

*CPSU %s*

### fjdarye_channel_adapters

<a id="check-fjdarye-channel-adapters"></a>

*Channel Adapter %s*

### fjdarye_channel_modules

<a id="check-fjdarye-channel-modules"></a>

*Controller Module %s*

### fjdarye_controller_enclosures

<a id="check-fjdarye-controller-enclosures"></a>

*Controller Enclosure %s*

### fjdarye_controller_modules_flash

<a id="check-fjdarye-controller-modules-flash"></a>

*Controller Module Flash %s*

### fjdarye_controller_modules_memory

<a id="check-fjdarye-controller-modules-memory"></a>

*Controller Module Memory %s*

### fjdarye_device_enclosures

<a id="check-fjdarye-device-enclosures"></a>

*Device Enclosure %s*

### fjdarye_disks

<a id="check-fjdarye-disks"></a>

*Disk %s*

### fjdarye_disks_summary

<a id="check-fjdarye-disks-summary"></a>

*Disk summary*

### fjdarye_expanders

<a id="check-fjdarye-expanders"></a>

*Expander %s*

### fjdarye_inlet_thermal_sensors

<a id="check-fjdarye-inlet-thermal-sensors"></a>

*Inlet Thermal %s*

### fjdarye_pcie_flash_modules

<a id="check-fjdarye-pcie-flash-modules"></a>

*PCIe flash module %s*

### fjdarye_pools

<a id="check-fjdarye-pools"></a>

*Thin Provisioning Pool %s*

### fjdarye_power_supply_units

<a id="check-fjdarye-power-supply-units"></a>

*PSU %s*

### fjdarye_rluns

<a id="check-fjdarye-rluns"></a>

*RLUN %s*

### fjdarye_summary_status

<a id="check-fjdarye-summary-status"></a>

*Summary Status*

### fjdarye_system_capacitors

<a id="check-fjdarye-system-capacitors"></a>

*System Capacitor Unit %s*

### fjdarye_thermal_sensors

<a id="check-fjdarye-thermal-sensors"></a>

*Thermal %s*

### form_submit

<a id="check-form-submit"></a>

### fortiauthenticator_auth_fail

<a id="check-fortiauthenticator-auth-fail"></a>

*Authentication Failures*

### fortigate_antivirus

<a id="check-fortigate-antivirus"></a>

*AntiVirus %s*

### fortigate_ap_connection

<a id="check-fortigate-ap-connection"></a>

*AP %s Connection*

### fortigate_ips

<a id="check-fortigate-ips"></a>

*IPS %s*

### fortigate_ipsecvpn

<a id="check-fortigate-ipsecvpn"></a>

*VPN IPSec Tunnels*

### fortigate_node_memory

<a id="check-fortigate-node-memory"></a>

*Memory %s*

### fortigate_sensors

<a id="check-fortigate-sensors"></a>

*Sensor Summary*

### fortigate_signatures

<a id="check-fortigate-signatures"></a>

*Signatures*

### fortigate_sync_status

<a id="check-fortigate-sync-status"></a>

*Sync Status*

### fortimail_cpu_load

<a id="check-fortimail-cpu-load"></a>

*CPU load*

### fortimail_disk_usage

<a id="check-fortimail-disk-usage"></a>

*Disk usage*

### fortimail_queue

<a id="check-fortimail-queue"></a>

*FortiMail %s*

### fortinet_controller_aps

<a id="check-fortinet-controller-aps"></a>

*AP %s*

### fortisandbox_disk_usage

<a id="check-fortisandbox-disk-usage"></a>

*Disk usage %s*

### fortisandbox_mem_usage

<a id="check-fortisandbox-mem-usage"></a>

*Memory*

### fritz_conn

<a id="check-fritz-conn"></a>

*Connection*

### fritz_link

<a id="check-fritz-link"></a>

*Link Info*

### fritz_uptime

<a id="check-fritz-uptime"></a>

*Uptime*

### fritz_wan_if

<a id="check-fritz-wan-if"></a>

*Interface %s*

### fsc_ipmi_mem_status

<a id="check-fsc-ipmi-mem-status"></a>

*IPMI Memory status %s*

### fsc_subsystems

<a id="check-fsc-subsystems"></a>

*FSC %s*

### ftp

<a id="check-ftp"></a>

### genua_carp

<a id="check-genua-carp"></a>

*Carp Interface %s*

### genua_state_correlation

<a id="check-genua-state-correlation"></a>

*Carp Correlation*

### genua_vpn

<a id="check-genua-vpn"></a>

*VPN %s*

### globalprotect_utilization

<a id="check-globalprotect-utilization"></a>

*GlobalProtect Gateway Utilization*

### gude_humidity

<a id="check-gude-humidity"></a>

*Humidity %s*

### gude_powerbanks

<a id="check-gude-powerbanks"></a>

*Powerbank %s*

### gude_relayport

<a id="check-gude-relayport"></a>

*Relay port %s*

### gude_temp

<a id="check-gude-temp"></a>

*Temperature %s*

### h3c_lanswitch_cpu

<a id="check-h3c-lanswitch-cpu"></a>

*CPU Utilization %s*

### h3c_lanswitch_sensors

<a id="check-h3c-lanswitch-sensors"></a>

*%s*

### haproxy_backend

<a id="check-haproxy-backend"></a>

*HAProxy Backend %s*

### haproxy_frontend

<a id="check-haproxy-frontend"></a>

*HAProxy Frontend %s*

### haproxy_server

<a id="check-haproxy-server"></a>

*HAProxy Server %s*

### heartbeat_crm

<a id="check-heartbeat-crm"></a>

*Heartbeat CRM General*

### heartbeat_crm_resources

<a id="check-heartbeat-crm-resources"></a>

*Heartbeat CRM %s*

### heartbeat_nodes

<a id="check-heartbeat-nodes"></a>

*Heartbeat Node %s*

### heartbeat_rscstatus

<a id="check-heartbeat-rscstatus"></a>

*Heartbeat Ressource Status*

### hepta

<a id="check-hepta"></a>

*HPF Info*

### hepta_ntpsysstratum

<a id="check-hepta-ntpsysstratum"></a>

*%s*

### hepta_syncmoduletimelocal

<a id="check-hepta-syncmoduletimelocal"></a>

*%s*

### hepta_syncmoduletimesyncstate

<a id="check-hepta-syncmoduletimesyncstate"></a>

*%s*

### hitachi_hnas_fc_if

<a id="check-hitachi-hnas-fc-if"></a>

*Interface FC %s*

### hitachi_hnas_span

<a id="check-hitachi-hnas-span"></a>

*Span %s*

### hitachi_hnas_volume

<a id="check-hitachi-hnas-volume"></a>

*Volumes %s*

### hitachi_hnas_volume_virtual

<a id="check-hitachi-hnas-volume-virtual"></a>

*Volumes %s*

### hitachi_hus_dkc

<a id="check-hitachi-hus-dkc"></a>

*HUS DKC Chassis %s*

### hitachi_hus_dku

<a id="check-hitachi-hus-dku"></a>

*HUS DKU Chassis %s*

### hivemanager_devices

<a id="check-hivemanager-devices"></a>

*Client %s*

### hivemanager_ng_devices

<a id="check-hivemanager-ng-devices"></a>

*Client %s*

### hp_blade

<a id="check-hp-blade"></a>

*General Status*

### hp_blade_blades

<a id="check-hp-blade-blades"></a>

*Blade %s*

### hp_blade_fan

<a id="check-hp-blade-fan"></a>

*FAN %s*

### hp_blade_manager

<a id="check-hp-blade-manager"></a>

*Manager %s*

### hp_blade_psu

<a id="check-hp-blade-psu"></a>

*PSU %s*

### hp_eml_sum

<a id="check-hp-eml-sum"></a>

*Summary Status*

### hp_fan

<a id="check-hp-fan"></a>

*Fan %s*

### hp_hh3c_ext

<a id="check-hp-hh3c-ext"></a>

*Temperature %s*

### hp_hh3c_ext_cpu

<a id="check-hp-hh3c-ext-cpu"></a>

*CPU utilization %s*

### hp_hh3c_ext_mem

<a id="check-hp-hh3c-ext-mem"></a>

*Memory %s*

### hp_hh3c_ext_states

<a id="check-hp-hh3c-ext-states"></a>

*Status %s*

### hp_hh3c_fan

<a id="check-hp-hh3c-fan"></a>

*Fan %s*

### hp_hh3c_power

<a id="check-hp-hh3c-power"></a>

*Power %s*

### hp_mcs_sensors

<a id="check-hp-mcs-sensors"></a>

*Sensor %s*

### hp_mcs_sensors_fan

<a id="check-hp-mcs-sensors-fan"></a>

*Sensor %s*

### hp_mcs_system

<a id="check-hp-mcs-system"></a>

*%s*

### hp_msa_controller

<a id="check-hp-msa-controller"></a>

*CPU Utilization %s*

### hp_msa_controller_io

<a id="check-hp-msa-controller-io"></a>

*Controller IO %s*

### hp_msa_disk

<a id="check-hp-msa-disk"></a>

*Disk Health %s*

### hp_msa_disk_io

<a id="check-hp-msa-disk-io"></a>

*Disk IO %s*

### hp_msa_disk_temp

<a id="check-hp-msa-disk-temp"></a>

*Temperature %s*

### hp_msa_fan

<a id="check-hp-msa-fan"></a>

*Fan %s*

### hp_msa_psu

<a id="check-hp-msa-psu"></a>

*Power Supply Health %s*

### hp_msa_psu_sensor

<a id="check-hp-msa-psu-sensor"></a>

*Power Supply Voltage %s*

### hp_msa_psu_temp

<a id="check-hp-msa-psu-temp"></a>

*Temperature Power Supply %s*

### hp_msa_system

<a id="check-hp-msa-system"></a>

*System Health %s*

### hp_msa_volume

<a id="check-hp-msa-volume"></a>

*Volume Health %s*

### hp_msa_volume_df

<a id="check-hp-msa-volume-df"></a>

*Filesystem %s*

### hp_msa_volume_io

<a id="check-hp-msa-volume-io"></a>

*Volume IO %s*

### hp_procurve_cpu

<a id="check-hp-procurve-cpu"></a>

*CPU utilization*

### hp_procurve_mem

<a id="check-hp-procurve-mem"></a>

*Memory*

### hp_procurve_sensors

<a id="check-hp-procurve-sensors"></a>

*Sensor %s*

### hp_procurve_temp

<a id="check-hp-procurve-temp"></a>

*Temperature %s*

### hp_proliant

<a id="check-hp-proliant"></a>

*General Status*

### hp_proliant_cpu

<a id="check-hp-proliant-cpu"></a>

*HW CPU %s*

### hp_proliant_da_cntlr

<a id="check-hp-proliant-da-cntlr"></a>

*HW Controller %s*

### hp_proliant_da_phydrv

<a id="check-hp-proliant-da-phydrv"></a>

*HW Phydrv %s*

### hp_proliant_fans

<a id="check-hp-proliant-fans"></a>

*HW FAN%s*

### hp_proliant_mem

<a id="check-hp-proliant-mem"></a>

*HW Mem %s*

### hp_proliant_power

<a id="check-hp-proliant-power"></a>

*HW Power Meter*

### hp_proliant_psu

<a id="check-hp-proliant-psu"></a>

*HW PSU %s*

### hp_proliant_raid

<a id="check-hp-proliant-raid"></a>

*Logical Device %s*

### hp_proliant_temp

<a id="check-hp-proliant-temp"></a>

*Temperature %s*

### hp_psu

<a id="check-hp-psu"></a>

*Power Supply Status %s*

### hp_psu_temp

<a id="check-hp-psu-temp"></a>

*Temperature Power Supply %s*

### hp_sts_drvbox

<a id="check-hp-sts-drvbox"></a>

*Drive Box %s*

### hp_webmgmt_status

<a id="check-hp-webmgmt-status"></a>

*Status %s*

### hpux_fchba

<a id="check-hpux-fchba"></a>

*FC HBA %s*

### hpux_if

<a id="check-hpux-if"></a>

*NIC %s*

### hpux_lvm

<a id="check-hpux-lvm"></a>

*Logical Volume %s*

### hpux_multipath

<a id="check-hpux-multipath"></a>

*Multipath %s*

### hpux_serviceguard

<a id="check-hpux-serviceguard"></a>

*Serviceguard %s*

### hpux_snmp_cs_cpu

<a id="check-hpux-snmp-cs-cpu"></a>

*CPU utilization*

### hpux_tunables_maxfiles_lim

<a id="check-hpux-tunables-maxfiles-lim"></a>

*Number of open files*

### hpux_tunables_nkthread

<a id="check-hpux-tunables-nkthread"></a>

*Number of threads*

### hpux_tunables_nproc

<a id="check-hpux-tunables-nproc"></a>

*Number of processes*

### hpux_tunables_semmni

<a id="check-hpux-tunables-semmni"></a>

*Number of IPC Semaphore IDs*

### hpux_tunables_semmns

<a id="check-hpux-tunables-semmns"></a>

*Number of IPC Semaphores*

### hpux_tunables_shmseg

<a id="check-hpux-tunables-shmseg"></a>

*Number of shared memory segments*

### hr_cpu

<a id="check-hr-cpu"></a>

*CPU utilization*

### hr_fs

<a id="check-hr-fs"></a>

*Filesystem %s*

### hr_ps

<a id="check-hr-ps"></a>

*Process %s*

### http

<a id="check-http"></a>

### httpv2

<a id="check-httpv2"></a>

### huawei_osn_fan

<a id="check-huawei-osn-fan"></a>

### huawei_osn_if

<a id="check-huawei-osn-if"></a>

*Interface %s*

### huawei_osn_laser

<a id="check-huawei-osn-laser"></a>

*Laser %s*

### huawei_osn_power

<a id="check-huawei-osn-power"></a>

### huawei_osn_temp

<a id="check-huawei-osn-temp"></a>

*Temperature %s*

### huawei_switch_cpu

<a id="check-huawei-switch-cpu"></a>

*CPU utilization %s*

### huawei_switch_fan

<a id="check-huawei-switch-fan"></a>

*Fan %s*

### huawei_switch_mem

<a id="check-huawei-switch-mem"></a>

*Memory %s*

### huawei_switch_psu

<a id="check-huawei-switch-psu"></a>

*Powersupply %s*

### huawei_switch_stack

<a id="check-huawei-switch-stack"></a>

*Stack role %s*

### huawei_switch_temp

<a id="check-huawei-switch-temp"></a>

*Temperature %s*

### huawei_wlc_aps_cpu

<a id="check-huawei-wlc-aps-cpu"></a>

*AP %s CPU*

### huawei_wlc_aps_mem

<a id="check-huawei-wlc-aps-mem"></a>

*AP %s Memory*

### huawei_wlc_aps_status

<a id="check-huawei-wlc-aps-status"></a>

*AP %s Status*

### huawei_wlc_aps_temp

<a id="check-huawei-wlc-aps-temp"></a>

*AP %s Temperature*

### huawei_wlc_devs_cpu

<a id="check-huawei-wlc-devs-cpu"></a>

*Device %s CPU*

### huawei_wlc_devs_mem

<a id="check-huawei-wlc-devs-mem"></a>

*Device %s Memory*

### hwg_humidity

<a id="check-hwg-humidity"></a>

*Humidity %s*

### hwg_ste2

<a id="check-hwg-ste2"></a>

*Temperature %s*

### hwg_ste2_humidity

<a id="check-hwg-ste2-humidity"></a>

*Humidity %s*

### hwg_temp

<a id="check-hwg-temp"></a>

*Temperature %s*

### hyperv_checkpoints

<a id="check-hyperv-checkpoints"></a>

*HyperV Checkpoints*

### hyperv_vm_checkpoints

<a id="check-hyperv-vm-checkpoints"></a>

*Hyper-V VM Checkpoints*

### hyperv_vm_general

<a id="check-hyperv-vm-general"></a>

*Hyper-V VM summary*

### hyperv_vm_integration

<a id="check-hyperv-vm-integration"></a>

*Hyper-V VM integration services*

### hyperv_vm_nic

<a id="check-hyperv-vm-nic"></a>

*HyperV NIC %s*

### hyperv_vm_ram

<a id="check-hyperv-vm-ram"></a>

*Hyper-V RAM*

### hyperv_vm_vhd_dynamic

<a id="check-hyperv-vm-vhd-dynamic"></a>

*Hyper-V VM Disk [%s]*

### hyperv_vm_vhd_fixed

<a id="check-hyperv-vm-vhd-fixed"></a>

*Hyper-V VM Disk [%s]*

### hyperv_vms

<a id="check-hyperv-vms"></a>

*VM %s*

### hyperv_vmstatus

<a id="check-hyperv-vmstatus"></a>

*HyperV Status*

### ibm_imm_fan

<a id="check-ibm-imm-fan"></a>

*Fan %s*

### ibm_imm_health

<a id="check-ibm-imm-health"></a>

*System health*

### ibm_imm_temp

<a id="check-ibm-imm-temp"></a>

*Temperature %s*

### ibm_imm_voltage

<a id="check-ibm-imm-voltage"></a>

*Voltage %s*

### ibm_mq_channels

<a id="check-ibm-mq-channels"></a>

*IBM MQ Channel %s*

### ibm_mq_managers

<a id="check-ibm-mq-managers"></a>

*IBM MQ Manager %s*

### ibm_mq_plugin

<a id="check-ibm-mq-plugin"></a>

*IBM MQ Plugin*

### ibm_mq_queues

<a id="check-ibm-mq-queues"></a>

*IBM MQ Queue %s*

### ibm_rsa_health

<a id="check-ibm-rsa-health"></a>

*System health*

### ibm_storage_ts

<a id="check-ibm-storage-ts"></a>

*Info*

### ibm_storage_ts_drive

<a id="check-ibm-storage-ts-drive"></a>

*Drive %s*

### ibm_storage_ts_library

<a id="check-ibm-storage-ts-library"></a>

*Library %s*

### ibm_storage_ts_status

<a id="check-ibm-storage-ts-status"></a>

*Status*

### ibm_svc_array

<a id="check-ibm-svc-array"></a>

*RAID Array %s*

### ibm_svc_disks

<a id="check-ibm-svc-disks"></a>

*Disk Summary*

### ibm_svc_enclosure

<a id="check-ibm-svc-enclosure"></a>

*Enclosure %s*

### ibm_svc_enclosurestats_power

<a id="check-ibm-svc-enclosurestats-power"></a>

*Power Enclosure %s*

### ibm_svc_enclosurestats_temp

<a id="check-ibm-svc-enclosurestats-temp"></a>

*Temperature Enclosure %s*

### ibm_svc_eventlog

<a id="check-ibm-svc-eventlog"></a>

*Eventlog*

### ibm_svc_host

<a id="check-ibm-svc-host"></a>

*Hosts*

### ibm_svc_license

<a id="check-ibm-svc-license"></a>

*License %s*

### ibm_svc_mdisk

<a id="check-ibm-svc-mdisk"></a>

*MDisk %s*

### ibm_svc_mdiskgrp

<a id="check-ibm-svc-mdiskgrp"></a>

*Pool Capacity %s*

### ibm_svc_node

<a id="check-ibm-svc-node"></a>

*IO Group %s*

### ibm_svc_nodestats_cache

<a id="check-ibm-svc-nodestats-cache"></a>

*Cache %s*

### ibm_svc_nodestats_cpu_util

<a id="check-ibm-svc-nodestats-cpu-util"></a>

*CPU utilization %s*

### ibm_svc_nodestats_disk_latency

<a id="check-ibm-svc-nodestats-disk-latency"></a>

*Disk Latency %s*

### ibm_svc_nodestats_diskio

<a id="check-ibm-svc-nodestats-diskio"></a>

*Disk IO %s*

### ibm_svc_nodestats_iops

<a id="check-ibm-svc-nodestats-iops"></a>

*Disk IOPS %s*

### ibm_svc_portfc

<a id="check-ibm-svc-portfc"></a>

*FC %s*

### ibm_svc_portsas

<a id="check-ibm-svc-portsas"></a>

*SAS %s*

### ibm_svc_system

<a id="check-ibm-svc-system"></a>

*Info*

### ibm_svc_systemstats_cache

<a id="check-ibm-svc-systemstats-cache"></a>

*Cache Total*

### ibm_svc_systemstats_cpu_util

<a id="check-ibm-svc-systemstats-cpu-util"></a>

*CPU utilization Total*

### ibm_svc_systemstats_disk_latency

<a id="check-ibm-svc-systemstats-disk-latency"></a>

*Latency %s Total*

### ibm_svc_systemstats_diskio

<a id="check-ibm-svc-systemstats-diskio"></a>

*Throughput %s Total*

### ibm_svc_systemstats_iops

<a id="check-ibm-svc-systemstats-iops"></a>

*IOPS %s Total*

### ibm_tl_changer_devices

<a id="check-ibm-tl-changer-devices"></a>

*Changer device %s*

### ibm_tl_media_access_devices

<a id="check-ibm-tl-media-access-devices"></a>

*Media access device %s*

### ibm_xraid_pdisks

<a id="check-ibm-xraid-pdisks"></a>

*RAID PDisk %s*

### icmp

<a id="check-icmp"></a>

### icom_repeater

<a id="check-icom-repeater"></a>

*Repeater Info*

### icom_repeater_pll_volt

<a id="check-icom-repeater-pll-volt"></a>

*%s PLL Lock Voltage*

### icom_repeater_ps_volt

<a id="check-icom-repeater-ps-volt"></a>

*Power Supply Voltage*

### icom_repeater_temp

<a id="check-icom-repeater-temp"></a>

*Temperature %s*

### if64

<a id="check-if64"></a>

*Interface %s*

### iis_app_pool_state

<a id="check-iis-app-pool-state"></a>

*IIS Application Pool %s*

### infoblox_node_services

<a id="check-infoblox-node-services"></a>

*Infoblox services and node services*

### infoblox_services

<a id="check-infoblox-services"></a>

*Infoblox services and node services*

### infoblox_temp

<a id="check-infoblox-temp"></a>

*Temperature %s*

### informix_dbspaces

<a id="check-informix-dbspaces"></a>

*Relevant documentation:*

### informix_locks

<a id="check-informix-locks"></a>

*Informix Locks %s*

### informix_logusage

<a id="check-informix-logusage"></a>

*Informix Log Usage %s*

### informix_sessions

<a id="check-informix-sessions"></a>

*Informix Sessions %s*

### informix_status

<a id="check-informix-status"></a>

*Informix Instance %s*

### informix_tabextents

<a id="check-informix-tabextents"></a>

*Informix Table Extents %s*

### inotify

<a id="check-inotify"></a>

*INotify %s*

### interfaces

<a id="check-interfaces"></a>

*Interface %s*

### ipr400_in_voltage

<a id="check-ipr400-in-voltage"></a>

*IN Voltage %s*

### ipr400_temp

<a id="check-ipr400-temp"></a>

*Temperature %s*

### iptables

<a id="check-iptables"></a>

*Iptables*

### isc_dhcpd

<a id="check-isc-dhcpd"></a>

*DHCP Pool %s*

### janitza_umg

<a id="check-janitza-umg"></a>

*Input %s*

### janitza_umg_freq

<a id="check-janitza-umg-freq"></a>

*Frequency %s*

### janitza_umg_temp

<a id="check-janitza-umg-temp"></a>

*Temperature External %s*

### jar_signature

<a id="check-jar-signature"></a>

*Jar-Signature %s*

### jira_custom_svc

<a id="check-jira-custom-svc"></a>

*Jira %s*

### jira_workflow

<a id="check-jira-workflow"></a>

*Jira Workflow %s*

### job

<a id="check-job"></a>

*Job %s*

### juniper_alarm

<a id="check-juniper-alarm"></a>

*Chassis*

### juniper_bgp_state

<a id="check-juniper-bgp-state"></a>

*BGP Status Peer %s*

### juniper_cpu_util

<a id="check-juniper-cpu-util"></a>

*CPU utilization %s*

### juniper_fru

<a id="check-juniper-fru"></a>

*Power Supply FRU %s*

### juniper_fru_fan

<a id="check-juniper-fru-fan"></a>

*Fan FRU %s*

### juniper_mem

<a id="check-juniper-mem"></a>

*Memory %s*

### juniper_screenos_cpu

<a id="check-juniper-screenos-cpu"></a>

*CPU utilization*

### juniper_screenos_fan

<a id="check-juniper-screenos-fan"></a>

*FAN %s*

### juniper_screenos_mem

<a id="check-juniper-screenos-mem"></a>

*Memory*

### juniper_screenos_temp

<a id="check-juniper-screenos-temp"></a>

*Temperature %s*

### juniper_screenos_vpn

<a id="check-juniper-screenos-vpn"></a>

*VPN %s*

### juniper_temp

<a id="check-juniper-temp"></a>

*Temperature %s*

### juniper_trpz_aps

<a id="check-juniper-trpz-aps"></a>

*Access Points*

### juniper_trpz_aps_sessions

<a id="check-juniper-trpz-aps-sessions"></a>

*Access Point %s*

### juniper_trpz_cpu_util

<a id="check-juniper-trpz-cpu-util"></a>

*CPU utilization*

### juniper_trpz_flash

<a id="check-juniper-trpz-flash"></a>

*Flash*

### juniper_trpz_info

<a id="check-juniper-trpz-info"></a>

*Info*

### juniper_trpz_mem

<a id="check-juniper-trpz-mem"></a>

*Memory*

### juniper_trpz_power

<a id="check-juniper-trpz-power"></a>

*PSU %s*

### kaspersky_av_client

<a id="check-kaspersky-av-client"></a>

*Kaspersky AV*

### kaspersky_av_kesl_updates

<a id="check-kaspersky-av-kesl-updates"></a>

*AV Update Status*

### kaspersky_av_quarantine

<a id="check-kaspersky-av-quarantine"></a>

*AV Quarantine*

### kaspersky_av_tasks

<a id="check-kaspersky-av-tasks"></a>

*AV Task %s*

### kaspersky_av_updates

<a id="check-kaspersky-av-updates"></a>

*AV Update Status*

### keepalived

<a id="check-keepalived"></a>

*VRRP Instance %s*

### kemp_loadmaster_realserver

<a id="check-kemp-loadmaster-realserver"></a>

*Real Server %s*

### kemp_loadmaster_services

<a id="check-kemp-loadmaster-services"></a>

*Service %s*

### kentix_amp_sensors

<a id="check-kentix-amp-sensors"></a>

*Temperature %s*

### kentix_amp_sensors_humidity

<a id="check-kentix-amp-sensors-humidity"></a>

*Humidity %s*

### kentix_amp_sensors_leakage

<a id="check-kentix-amp-sensors-leakage"></a>

*Leakage %s*

### kentix_amp_sensors_smoke

<a id="check-kentix-amp-sensors-smoke"></a>

*Smoke Detector %s*

### kentix_co

<a id="check-kentix-co"></a>

*Carbon Monoxide*

### kentix_dewpoint

<a id="check-kentix-dewpoint"></a>

*Dewpoint %s*

### kentix_humidity

<a id="check-kentix-humidity"></a>

*Humidity*

### kentix_motion

<a id="check-kentix-motion"></a>

*Motion Detector %s*

### kentix_temp

<a id="check-kentix-temp"></a>

*Temperature %s*

### kernel_performance

<a id="check-kernel-performance"></a>

*Kernel Performance*

### kernel_util

<a id="check-kernel-util"></a>

*CPU utilization*

### knuerr_rms_humidity

<a id="check-knuerr-rms-humidity"></a>

*Humidity*

### knuerr_rms_temp

<a id="check-knuerr-rms-temp"></a>

*Temperature %s*

### knuerr_sensors

<a id="check-knuerr-sensors"></a>

*Sensor %s*

### ldap

<a id="check-ldap"></a>

### lgp_info

<a id="check-lgp-info"></a>

*Liebert Info*

### lgp_pdu_aux

<a id="check-lgp-pdu-aux"></a>

*Liebert PDU AUX %s*

### lgp_pdu_info

<a id="check-lgp-pdu-info"></a>

*Liebert PDU Info %s*

### libelle_business_shadow_archive_dir

<a id="check-libelle-business-shadow-archive-dir"></a>

*Libelle Business Shadow %s*

### libelle_business_shadow_info

<a id="check-libelle-business-shadow-info"></a>

*Libelle Business Shadow Info*

### libelle_business_shadow_process

<a id="check-libelle-business-shadow-process"></a>

*Libelle Business Shadow Process*

### libelle_business_shadow_status

<a id="check-libelle-business-shadow-status"></a>

*Libelle Business Shadow Status*

### liebert_bat_temp

<a id="check-liebert-bat-temp"></a>

*Temperature %s*

### liebert_chilled_water

<a id="check-liebert-chilled-water"></a>

*%s*

### liebert_chiller_status

<a id="check-liebert-chiller-status"></a>

*Chiller status*

### liebert_compressor

<a id="check-liebert-compressor"></a>

*%s*

### liebert_cooling

<a id="check-liebert-cooling"></a>

*%s*

### liebert_cooling_position

<a id="check-liebert-cooling-position"></a>

*%s*

### liebert_cooling_status

<a id="check-liebert-cooling-status"></a>

*%s*

### liebert_fans

<a id="check-liebert-fans"></a>

*%s*

### liebert_fans_condenser

<a id="check-liebert-fans-condenser"></a>

*%s*

### liebert_humidity_air

<a id="check-liebert-humidity-air"></a>

*%s Humidity*

### liebert_maintenance

<a id="check-liebert-maintenance"></a>

*Maintenance*

### liebert_pump

<a id="check-liebert-pump"></a>

*%s*

### liebert_reheating

<a id="check-liebert-reheating"></a>

*Reheating Utilization*

### liebert_system

<a id="check-liebert-system"></a>

*Status %s*

### liebert_system_events

<a id="check-liebert-system-events"></a>

*System events*

### liebert_temp_air

<a id="check-liebert-temp-air"></a>

*%s Temperature*

### liebert_temp_fluid

<a id="check-liebert-temp-fluid"></a>

*%s*

### liebert_temp_general

<a id="check-liebert-temp-general"></a>

*%s*

### livestatus_status

<a id="check-livestatus-status"></a>

*OMD %s performance*

### lnx_if

<a id="check-lnx-if"></a>

*Interface %s*

### lnx_quota

<a id="check-lnx-quota"></a>

*Quota: %s*

### lnx_thermal

<a id="check-lnx-thermal"></a>

*Temperature %s*

### local

<a id="check-local"></a>

*%s*

### logins

<a id="check-logins"></a>

*Logins*

### lparstat_aix

<a id="check-lparstat-aix"></a>

*lparstat*

### lparstat_aix_cpu_util

<a id="check-lparstat-aix-cpu-util"></a>

*CPU utilization*

### lsi_array

<a id="check-lsi-array"></a>

*RAID array %s*

### lsi_disk

<a id="check-lsi-disk"></a>

*RAID disk %s*

### lvm_lvs

<a id="check-lvm-lvs"></a>

*LVM LV Pool %s*

### lvm_vgs

<a id="check-lvm-vgs"></a>

*LVM VG %s*

### mail

<a id="check-mail"></a>

### mail_loop

<a id="check-mail-loop"></a>

### mailboxes

<a id="check-mailboxes"></a>

### mailman_lists

<a id="check-mailman-lists"></a>

*Mailinglist %s*

### mbg_lantime_ng_refclock

<a id="check-mbg-lantime-ng-refclock"></a>

*LANTIME Refclock %s*

### mbg_lantime_ng_refclock_gps

<a id="check-mbg-lantime-ng-refclock-gps"></a>

*LANTIME Refclock %s*

### mcafee_av_client

<a id="check-mcafee-av-client"></a>

*McAfee AV*

### mcafee_webgateway

<a id="check-mcafee-webgateway"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_http_client_requests

<a id="check-mcafee-webgateway-http-client-requests"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_https_client_requests

<a id="check-mcafee-webgateway-https-client-requests"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_httpv2_client_requests

<a id="check-mcafee-webgateway-httpv2-client-requests"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_info

<a id="check-mcafee-webgateway-info"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_misc

<a id="check-mcafee-webgateway-misc"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_time_consumed_by_rule_engine

<a id="check-mcafee-webgateway-time-consumed-by-rule-engine"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcafee_webgateway_time_to_resolve_dns

<a id="check-mcafee-webgateway-time-to-resolve-dns"></a>

*The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway with its release 12.2.2.*

### mcdata_fcport

<a id="check-mcdata-fcport"></a>

*Port %s*

### md

<a id="check-md"></a>

*MD Softraid %s*

### megaraid_bbu

<a id="check-megaraid-bbu"></a>

*RAID BBU %s*

### megaraid_ldisks

<a id="check-megaraid-ldisks"></a>

*RAID logical disk %s*

### megaraid_pdisks

<a id="check-megaraid-pdisks"></a>

*RAID pysical disk %s*

### mem_linux

<a id="check-mem-linux"></a>

*Memory*

### mem_used

<a id="check-mem-used"></a>

*Memory*

### mem_vmalloc

<a id="check-mem-vmalloc"></a>

*Vmalloc address space*

### mem_win

<a id="check-mem-win"></a>

*Memory*

### memory_utilization

<a id="check-memory-utilization"></a>

*Memory*

### mikrotik_signal

<a id="check-mikrotik-signal"></a>

*Signal %s*

### mkbackup

<a id="check-mkbackup"></a>

*Backup %s*

### mkbackup_site

<a id="check-mkbackup-site"></a>

*OMD %s*

### mkeventd_status

<a id="check-mkeventd-status"></a>

*OMD %s Event Console*

### mkevents

<a id="check-mkevents"></a>

### mknotifyd

<a id="check-mknotifyd"></a>

*OMD %s Notification Spooler*

### mknotifyd_connection

<a id="check-mknotifyd-connection"></a>

*OMD %s Notify Connection*

### mknotifyd_connection_v2

<a id="check-mknotifyd-connection-v2"></a>

*OMD %s*

### mobileiron_compliance

<a id="check-mobileiron-compliance"></a>

*Mobileiron compliance*

### mobileiron_statistics

<a id="check-mobileiron-statistics"></a>

*Provides summarized insights into the fetched partitions.*

### mobileiron_versions

<a id="check-mobileiron-versions"></a>

*Mobileiron versions*

### mongodb_asserts

<a id="check-mongodb-asserts"></a>

*MongoDB Asserts*

### mongodb_cluster

<a id="check-mongodb-cluster"></a>

*MongoDB Database: %s*

### mongodb_cluster_balancer

<a id="check-mongodb-cluster-balancer"></a>

*MongoDB Balancer*

### mongodb_cluster_collections

<a id="check-mongodb-cluster-collections"></a>

*MongoDB Cluster: %s*

### mongodb_collections

<a id="check-mongodb-collections"></a>

*MongoDB Collection: %s*

### mongodb_connections

<a id="check-mongodb-connections"></a>

*MongoDB %s*

### mongodb_counters

<a id="check-mongodb-counters"></a>

*MongoDB Counters %s*

### mongodb_flushing

<a id="check-mongodb-flushing"></a>

*MongoDB Flushing*

### mongodb_instance

<a id="check-mongodb-instance"></a>

*MongoDB Instance*

### mongodb_locks

<a id="check-mongodb-locks"></a>

*MongoDB Locks*

### mongodb_mem

<a id="check-mongodb-mem"></a>

*Memory used MongoDB*

### mongodb_replica

<a id="check-mongodb-replica"></a>

*MongoDB Replica Set Status*

### mongodb_replica_set

<a id="check-mongodb-replica-set"></a>

*MongoDB Replication Lag*

### mongodb_replica_set_election

<a id="check-mongodb-replica-set-election"></a>

*MongoDB Replica Set Primary Election*

### mongodb_replication_info

<a id="check-mongodb-replication-info"></a>

*MongoDB Replication Info*

### mounts

<a id="check-mounts"></a>

*Mount options of %s*

### moxa_iologik_register

<a id="check-moxa-iologik-register"></a>

*Moxa Register %s*

### mq_queues

<a id="check-mq-queues"></a>

*Queue %s*

### mqtt_broker

<a id="check-mqtt-broker"></a>

*MQTT %s Broker*

### mqtt_clients

<a id="check-mqtt-clients"></a>

*MQTT %s Clients*

### mqtt_messages

<a id="check-mqtt-messages"></a>

*MQTT %s Messages*

### mqtt_uptime

<a id="check-mqtt-uptime"></a>

*MQTT %s Uptime*

### mrpe

<a id="check-mrpe"></a>

*%s*

### msexch_activesync

<a id="check-msexch-activesync"></a>

*Exchange ActiveSync*

### msexch_autodiscovery

<a id="check-msexch-autodiscovery"></a>

*Exchange Autodiscovery*

### msexch_availability

<a id="check-msexch-availability"></a>

*Exchange Availability Service*

### msexch_dag_contentindex

<a id="check-msexch-dag-contentindex"></a>

*Exchange DAG ContentIndex of %s*

### msexch_dag_copyqueue

<a id="check-msexch-dag-copyqueue"></a>

*Exchange DAG CopyQueue of %s*

### msexch_dag_dbcopy

<a id="check-msexch-dag-dbcopy"></a>

*Exchange DAG DBCopy for %s*

### msexch_database

<a id="check-msexch-database"></a>

*Exchange Database %s*

### msexch_isclienttype

<a id="check-msexch-isclienttype"></a>

*Exchange IS Client Type %s*

### msexch_isstore

<a id="check-msexch-isstore"></a>

*Exchange IS Store %s*

### msexch_owa

<a id="check-msexch-owa"></a>

*Exchange OWA*

### msexch_replhealth

<a id="check-msexch-replhealth"></a>

*Exchange Replication Health %s*

### msexch_rpcclientaccess

<a id="check-msexch-rpcclientaccess"></a>

*Exchange RPC Client Access*

### msoffice_licenses

<a id="check-msoffice-licenses"></a>

*MS Office Licenses %s*

### msoffice_serviceplans

<a id="check-msoffice-serviceplans"></a>

*MS Office Serviceplans %s*

### mssql_availability_groups

<a id="check-mssql-availability-groups"></a>

*MSSQL Availability Group %s*

### mssql_backup

<a id="check-mssql-backup"></a>

*MSSQL %s Backup*

### mssql_backup_per_type

<a id="check-mssql-backup-per-type"></a>

*MSSQL %s Backup*

### mssql_blocked_sessions

<a id="check-mssql-blocked-sessions"></a>

*MSSQL %s Blocked Sessions*

### mssql_connections

<a id="check-mssql-connections"></a>

*MSSQL Connections %s*

### mssql_counters_cache_hits

<a id="check-mssql-counters-cache-hits"></a>

*MSSQL %s*

### mssql_counters_file_sizes

<a id="check-mssql-counters-file-sizes"></a>

*MSSQL %s File Sizes*

### mssql_counters_locks

<a id="check-mssql-counters-locks"></a>

*MSSQL %s Locks*

### mssql_counters_locks_per_batch

<a id="check-mssql-counters-locks-per-batch"></a>

*MSSQL %s Locks per Batch*

### mssql_counters_page_life_expectancy

<a id="check-mssql-counters-page-life-expectancy"></a>

*MSSQL %s*

### mssql_counters_pageactivity

<a id="check-mssql-counters-pageactivity"></a>

*MSSQL %s Page Activity*

### mssql_counters_sqlstats

<a id="check-mssql-counters-sqlstats"></a>

*MSSQL %s*

### mssql_counters_transactions

<a id="check-mssql-counters-transactions"></a>

*MSSQL %s Transactions*

### mssql_databases

<a id="check-mssql-databases"></a>

*MSSQL %s Database*

### mssql_datafiles

<a id="check-mssql-datafiles"></a>

*MSSQL Datafile %s*

### mssql_instance

<a id="check-mssql-instance"></a>

*MSSQL %s Instance*

### mssql_jobs

<a id="check-mssql-jobs"></a>

*MSSQL job %s*

### mssql_mirroring

<a id="check-mssql-mirroring"></a>

*MSSQL Mirroring Status: %s*

### mssql_tablespaces

<a id="check-mssql-tablespaces"></a>

*MSSQL %s Sizes*

### mssql_transactionlogs

<a id="check-mssql-transactionlogs"></a>

*MSSQL Transactionlog %s*

### mtr

<a id="check-mtr"></a>

*Mtr to %s*

### multipath

<a id="check-multipath"></a>

*Multipath %s*

### mysql

<a id="check-mysql"></a>

*MySQL Version %s*

### mysql_capacity

<a id="check-mysql-capacity"></a>

*MySQL DB Size %s*

### mysql_connections

<a id="check-mysql-connections"></a>

*MySQL Connections %s*

### mysql_galeradonor

<a id="check-mysql-galeradonor"></a>

*MySQL Galera Donor %s*

### mysql_galerasize

<a id="check-mysql-galerasize"></a>

*MySQL Galera Size %s*

### mysql_galerastartup

<a id="check-mysql-galerastartup"></a>

*MySQL Galera Startup %s*

### mysql_galerastatus

<a id="check-mysql-galerastatus"></a>

*MySQL Galera Status %s*

### mysql_galerasync

<a id="check-mysql-galerasync"></a>

*MySQL Galera Sync %s*

### mysql_innodb_io

<a id="check-mysql-innodb-io"></a>

*MySQL InnoDB IO %s*

### mysql_ping

<a id="check-mysql-ping"></a>

*MySQL Instance %s*

### mysql_replica_slave

<a id="check-mysql-replica-slave"></a>

*MySQL DB Slave %s*

### mysql_sessions

<a id="check-mysql-sessions"></a>

*MySQL Sessions %s*

### netctr_combined

<a id="check-netctr-combined"></a>

*NIC %s counters*

### netscaler_ha

<a id="check-netscaler-ha"></a>

*HA Node Status*

### netscaler_sslcertificates

<a id="check-netscaler-sslcertificates"></a>

*SSL Certificate %s*

### netscaler_tcp_conns

<a id="check-netscaler-tcp-conns"></a>

*TCP Connections*

### netscaler_vserver

<a id="check-netscaler-vserver"></a>

*VServer %s*

### netstat

<a id="check-netstat"></a>

*TCP Connection %s*

### nfsexports

<a id="check-nfsexports"></a>

*NFS export %s*

### nfsiostat

<a id="check-nfsiostat"></a>

*NFS IO stats %s*

### nfsmounts

<a id="check-nfsmounts"></a>

*NFS mount %s*

### nginx_status

<a id="check-nginx-status"></a>

*Nginx %s Status*

### nimble_latency

<a id="check-nimble-latency"></a>

*Volume %s Read IO*

### nimble_latency_write

<a id="check-nimble-latency-write"></a>

*Volume %s Write IO*

### nimble_volumes

<a id="check-nimble-volumes"></a>

*Volume %s*

### notify_count

<a id="check-notify-count"></a>

### ntp

<a id="check-ntp"></a>

*NTP Peer %s*

### ntp_time

<a id="check-ntp-time"></a>

*NTP Time*

### nullmailer_mailq

<a id="check-nullmailer-mailq"></a>

*Nullmailer Queue*

### nvidia_errors

<a id="check-nvidia-errors"></a>

*NVIDIA GPU Errors*

### nvidia_smi_en_de_coder_util

<a id="check-nvidia-smi-en-de-coder-util"></a>

*Nvidia GPU En-/Decoder utilization %s*

### nvidia_smi_gpu_util

<a id="check-nvidia-smi-gpu-util"></a>

*Nvidia GPU utilization %s*

### nvidia_smi_memory_util

<a id="check-nvidia-smi-memory-util"></a>

*Nvidia GPU Memory utilization %s*

### nvidia_smi_power

<a id="check-nvidia-smi-power"></a>

*Nvidia GPU Power %s*

### nvidia_smi_temperature

<a id="check-nvidia-smi-temperature"></a>

*Nvidia GPU Temperature %s*

### nvidia_temp

<a id="check-nvidia-temp"></a>

*Temperature %s*

### nvidia_temp_core

<a id="check-nvidia-temp-core"></a>

*Temperature %s*

### omd_apache

<a id="check-omd-apache"></a>

*OMD %s apache*

### omd_broker_queues

<a id="check-omd-broker-queues"></a>

*OMD %s*

### omd_broker_status

<a id="check-omd-broker-status"></a>

*OMD %s message broker*

### omd_diskusage

<a id="check-omd-diskusage"></a>

*OMD %s disk usage*

### omd_status

<a id="check-omd-status"></a>

*<<<omd_status>>>*

### openbsd_sensors

<a id="check-openbsd-sensors"></a>

*Temperature %s*

### openbsd_sensors_drive

<a id="check-openbsd-sensors-drive"></a>

*Drive %s*

### openbsd_sensors_fan

<a id="check-openbsd-sensors-fan"></a>

*Fan %s*

### openbsd_sensors_indicator

<a id="check-openbsd-sensors-indicator"></a>

*Indicator %s*

### openbsd_sensors_powersupply

<a id="check-openbsd-sensors-powersupply"></a>

*Powersupply %s*

### openbsd_sensors_voltage

<a id="check-openbsd-sensors-voltage"></a>

*Voltage Type %s*

### openhardwaremonitor

<a id="check-openhardwaremonitor"></a>

*Clock %s*

### openhardwaremonitor_fan

<a id="check-openhardwaremonitor-fan"></a>

*Fan %s*

### openhardwaremonitor_power

<a id="check-openhardwaremonitor-power"></a>

*Power %s*

### openhardwaremonitor_smart

<a id="check-openhardwaremonitor-smart"></a>

*SMART %s Stats*

### openhardwaremonitor_temperature

<a id="check-openhardwaremonitor-temperature"></a>

*Temperature %s*

### openvpn_clients

<a id="check-openvpn-clients"></a>

*OpenVPN Client %s*

### oracle_asm_diskgroup

<a id="check-oracle-asm-diskgroup"></a>

*ASM Diskgroup %s*

### oracle_crs_res

<a id="check-oracle-crs-res"></a>

*ORA-GI %s Resource*

### oracle_crs_version

<a id="check-oracle-crs-version"></a>

*ORA-GI Version*

### oracle_crs_voting

<a id="check-oracle-crs-voting"></a>

*ORA-GI Voting*

### oracle_dataguard_stats

<a id="check-oracle-dataguard-stats"></a>

*ORA %s Dataguard-Stats*

### oracle_diva_csm

<a id="check-oracle-diva-csm"></a>

*DIVA Status %s*

### oracle_diva_csm_actor

<a id="check-oracle-diva-csm-actor"></a>

*DIVA Status %s*

### oracle_diva_csm_archive

<a id="check-oracle-diva-csm-archive"></a>

*DIVA Status %s*

### oracle_diva_csm_drive

<a id="check-oracle-diva-csm-drive"></a>

*DIVA Status %s*

### oracle_diva_csm_objects

<a id="check-oracle-diva-csm-objects"></a>

*DIVA Managed Objects*

### oracle_diva_csm_tapes

<a id="check-oracle-diva-csm-tapes"></a>

*DIVA Blank Tapes*

### oracle_instance

<a id="check-oracle-instance"></a>

*ORA %s Instance*

### oracle_instance_uptime

<a id="check-oracle-instance-uptime"></a>

*ORA %s Uptime*

### oracle_jobs

<a id="check-oracle-jobs"></a>

*ORA %s Job*

### oracle_locks

<a id="check-oracle-locks"></a>

*ORA %s Locks*

### oracle_logswitches

<a id="check-oracle-logswitches"></a>

*ORA %s Logswitches*

### oracle_longactivesessions

<a id="check-oracle-longactivesessions"></a>

*ORA %s Long Active Sessions*

### oracle_performance

<a id="check-oracle-performance"></a>

*ORA %s Performance*

### oracle_performance_dbtime

<a id="check-oracle-performance-dbtime"></a>

*ORA %s Performance DB-Time*

### oracle_performance_iostat_bytes

<a id="check-oracle-performance-iostat-bytes"></a>

*ORA %s Performance IO Stats Bytes*

### oracle_performance_iostat_ios

<a id="check-oracle-performance-iostat-ios"></a>

*ORA %s Performance IO Stats Requests*

### oracle_performance_memory

<a id="check-oracle-performance-memory"></a>

*ORA %s Performance Memory*

### oracle_performance_waitclasses

<a id="check-oracle-performance-waitclasses"></a>

*ORA %s Performance System Wait*

### oracle_processes

<a id="check-oracle-processes"></a>

*ORA %s Processes*

### oracle_recovery_area

<a id="check-oracle-recovery-area"></a>

*ORA %s Recovery Area*

### oracle_recovery_status

<a id="check-oracle-recovery-status"></a>

*ORA %s Recovery Status*

### oracle_rman

<a id="check-oracle-rman"></a>

*ORA %s RMAN Backup*

### oracle_sessions

<a id="check-oracle-sessions"></a>

*ORA %s Sessions*

### oracle_sql

<a id="check-oracle-sql"></a>

*ORA %s*

### oracle_tablespaces

<a id="check-oracle-tablespaces"></a>

*ORA %s Tablespace*

### oracle_undostat

<a id="check-oracle-undostat"></a>

*ORA %s Undo Retention*

### oracle_version

<a id="check-oracle-version"></a>

*ORA Version %s*

### orion_backup

<a id="check-orion-backup"></a>

*Backup*

### orion_batterytest

<a id="check-orion-batterytest"></a>

*Battery Test*

### orion_system

<a id="check-orion-system"></a>

*Temperature %s*

### orion_system_charging

<a id="check-orion-system-charging"></a>

*Charge %s*

### orion_system_dc

<a id="check-orion-system-dc"></a>

*Direct Current %s*

### ovs_bonding

<a id="check-ovs-bonding"></a>

*OVS Bonding interface %s*

### packeteer_fan_status

<a id="check-packeteer-fan-status"></a>

*Fan Status %s*

### packeteer_ps_status

<a id="check-packeteer-ps-status"></a>

*Power Supply Status*

### palo_alto

<a id="check-palo-alto"></a>

*Palo Alto State*

### palo_alto_users

<a id="check-palo-alto-users"></a>

*Palo Alto Users*

### pandacom_10gm_temp

<a id="check-pandacom-10gm-temp"></a>

*Temperature 10GM Module %s*

### pandacom_fan

<a id="check-pandacom-fan"></a>

*Fan %s*

### pandacom_fc_temp

<a id="check-pandacom-fc-temp"></a>

*Temperature FC Module %s*

### pandacom_psu

<a id="check-pandacom-psu"></a>

*Power Supply %s*

### pandacom_sys_temp

<a id="check-pandacom-sys-temp"></a>

*Temperature %s*

### papouch_th2e_sensors

<a id="check-papouch-th2e-sensors"></a>

*Temperature %s*

### papouch_th2e_sensors_dewpoint

<a id="check-papouch-th2e-sensors-dewpoint"></a>

*Dew point %s*

### papouch_th2e_sensors_humidity

<a id="check-papouch-th2e-sensors-humidity"></a>

*Humidity %s*

### pdu_gude

<a id="check-pdu-gude"></a>

*Phase %s*

### pfsense_counter

<a id="check-pfsense-counter"></a>

*pfSense Firewall Packet Rates*

### pfsense_if

<a id="check-pfsense-if"></a>

*Firewall Interface %s*

### pfsense_status

<a id="check-pfsense-status"></a>

*pfSense Status*

### plesk_backups

<a id="check-plesk-backups"></a>

*Plesk Backup %s*

### plesk_domains

<a id="check-plesk-domains"></a>

*Plesk Domains*

### podman_container_cpu_utilization

<a id="check-podman-container-cpu-utilization"></a>

*CPU utilization*

### podman_container_diskstat

<a id="check-podman-container-diskstat"></a>

*Container IO %s*

### podman_container_health

<a id="check-podman-container-health"></a>

*Health*

### podman_container_memory

<a id="check-podman-container-memory"></a>

*Memory*

### podman_container_restarts

<a id="check-podman-container-restarts"></a>

*Restarts*

### podman_container_status

<a id="check-podman-container-status"></a>

*Status*

### podman_container_uptime

<a id="check-podman-container-uptime"></a>

*Uptime*

### podman_containers

<a id="check-podman-containers"></a>

*Podman containers*

### podman_disk_usage

<a id="check-podman-disk-usage"></a>

*Podman disk usage: %s*

### podman_pods

<a id="check-podman-pods"></a>

*Podman pods*

### podman_status

<a id="check-podman-status"></a>

*Podman status*

### poseidon_inputs

<a id="check-poseidon-inputs"></a>

*%s*

### poseidon_temp

<a id="check-poseidon-temp"></a>

*Temperatur: %s*

### postfix_mailq

<a id="check-postfix-mailq"></a>

*Postfix Queue %s*

### postfix_mailq_status

<a id="check-postfix-mailq-status"></a>

*Postfix status %s*

### postgres_bloat

<a id="check-postgres-bloat"></a>

*PostgreSQL Bloat %s*

### postgres_conn_time

<a id="check-postgres-conn-time"></a>

*PostgreSQL Connection Time %s*

### postgres_connections

<a id="check-postgres-connections"></a>

*PostgreSQL Connections %s*

### postgres_instances

<a id="check-postgres-instances"></a>

*PostgreSQL Instance %s*

### postgres_locks

<a id="check-postgres-locks"></a>

*PostgreSQL Locks %s*

### postgres_processes

<a id="check-postgres-processes"></a>

*PostgreSQL Process Count*

### postgres_query_duration

<a id="check-postgres-query-duration"></a>

*PostgreSQL Query Duration %s*

### postgres_sessions

<a id="check-postgres-sessions"></a>

*PostgreSQL Daemon Sessions %s*

### postgres_stat_database

<a id="check-postgres-stat-database"></a>

*PostgreSQL DB %s Statistics*

### postgres_stat_database_size

<a id="check-postgres-stat-database-size"></a>

*PostgreSQL DB %s Size*

### postgres_stats

<a id="check-postgres-stats"></a>

*PostgreSQL %s*

### primekey_cpu_temperature

<a id="check-primekey-cpu-temperature"></a>

*Temperature PrimeKey %s*

### primekey_data

<a id="check-primekey-data"></a>

*PrimeKey %s Status*

### primekey_db_usage

<a id="check-primekey-db-usage"></a>

*PrimeKey DB Usage*

### primekey_fan

<a id="check-primekey-fan"></a>

*PrimeKey Fan %s*

### primekey_hsm_battery_voltage

<a id="check-primekey-hsm-battery-voltage"></a>

*PrimeKey HSM Battery %s*

### printer_alerts

<a id="check-printer-alerts"></a>

*Alerts*

### printer_input

<a id="check-printer-input"></a>

*Input %s*

### printer_output

<a id="check-printer-output"></a>

*Output %s*

### printer_pages

<a id="check-printer-pages"></a>

*Pages*

### printer_pages_ricoh

<a id="check-printer-pages-ricoh"></a>

*Pages*

### printer_supply_ricoh

<a id="check-printer-supply-ricoh"></a>

*Supply %s*

### prometheus_build

<a id="check-prometheus-build"></a>

*Prometheus Build Check*

### ps

<a id="check-ps"></a>

*Process %s*

### pse_poe

<a id="check-pse-poe"></a>

*POE%s consumption*

### pulse_secure_cpu_util

<a id="check-pulse-secure-cpu-util"></a>

*Pulse Secure IVE CPU utilization*

### pulse_secure_disk_util

<a id="check-pulse-secure-disk-util"></a>

*Pulse Secure disk utilization*

### pulse_secure_log_util

<a id="check-pulse-secure-log-util"></a>

*Pulse Secure log file utilization*

### pulse_secure_mem_util

<a id="check-pulse-secure-mem-util"></a>

*Pulse Secure IVE memory utilization*

### pulse_secure_temp

<a id="check-pulse-secure-temp"></a>

*Pulse Secure %s Temperature*

### pulse_secure_users

<a id="check-pulse-secure-users"></a>

*Pulse Secure users*

### pvecm_nodes

<a id="check-pvecm-nodes"></a>

*PVE Node %s*

### pvecm_status

<a id="check-pvecm-status"></a>

*PVE Cluster State*

### qlogic_fcport

<a id="check-qlogic-fcport"></a>

*FC Port %s*

### qlogic_sanbox_fabric_element

<a id="check-qlogic-sanbox-fabric-element"></a>

*Fabric Element %s*

### qlogic_sanbox_psu

<a id="check-qlogic-sanbox-psu"></a>

*PSU %s*

### qlogic_sanbox_temp

<a id="check-qlogic-sanbox-temp"></a>

*Temperature Sensor %s*

### qmail_stats

<a id="check-qmail-stats"></a>

*Qmail Queue*

### quanta_fan

<a id="check-quanta-fan"></a>

*Fan %s*

### quanta_temperature

<a id="check-quanta-temperature"></a>

*Temperature %s*

### quanta_voltage

<a id="check-quanta-voltage"></a>

*Voltage %s*

### quantum_libsmall_door

<a id="check-quantum-libsmall-door"></a>

*Tape library door*

### quantum_libsmall_status

<a id="check-quantum-libsmall-status"></a>

*Tape library status*

### quantum_storage_status

<a id="check-quantum-storage-status"></a>

*Device status*

### ra32e_sensors

<a id="check-ra32e-sensors"></a>

*Temperature %s*

### ra32e_sensors_humidity

<a id="check-ra32e-sensors-humidity"></a>

*Humidity %s*

### ra32e_sensors_power

<a id="check-ra32e-sensors-power"></a>

*Power State %s*

### ra32e_sensors_voltage

<a id="check-ra32e-sensors-voltage"></a>

*Voltage %s*

### ra3s_internal_temperature

<a id="check-ra3s-internal-temperature"></a>

*Temperature %s*

### ra3s_sensors_humidity

<a id="check-ra3s-sensors-humidity"></a>

*Humidity %s*

### ra3s_sensors_power

<a id="check-ra3s-sensors-power"></a>

*Power State %s*

### ra3s_sensors_voltage

<a id="check-ra3s-sensors-voltage"></a>

*Voltage %s*

### raritan_px2_residual_current

<a id="check-raritan-px2-residual-current"></a>

*Residual Current %s*

### rds_licenses

<a id="check-rds-licenses"></a>

*RDS Licenses %s*

### redis_info

<a id="check-redis-info"></a>

*Redis %s Server Info*

### redis_info_clients

<a id="check-redis-info-clients"></a>

*Redis %s Clients*

### redis_info_persistence

<a id="check-redis-info-persistence"></a>

*Redis %s Persistence*

### rmon_stats

<a id="check-rmon-stats"></a>

*RMON Stats IF %s*

### rms200_temp

<a id="check-rms200-temp"></a>

*Temperature %s*

### rstcli

<a id="check-rstcli"></a>

*RAID Volume %s*

### rstcli_pdisks

<a id="check-rstcli-pdisks"></a>

*RAID Disk %s*

### ruckus_spot_ap

<a id="check-ruckus-spot-ap"></a>

*Ruckus Spot Access Points %s*

### safenet_hsm

<a id="check-safenet-hsm"></a>

*HSM Operation Stats*

### safenet_hsm_events

<a id="check-safenet-hsm-events"></a>

*HSM Safenet Event Stats*

### safenet_ntls

<a id="check-safenet-ntls"></a>

*NTLS Operation Status*

### safenet_ntls_clients

<a id="check-safenet-ntls-clients"></a>

*NTLS Clients*

### safenet_ntls_connrate

<a id="check-safenet-ntls-connrate"></a>

*NTLS Connection Rate: %s*

### safenet_ntls_expiration

<a id="check-safenet-ntls-expiration"></a>

*NTLS Expiration Date*

### safenet_ntls_links

<a id="check-safenet-ntls-links"></a>

*NTLS Links*

### salesforce_instances

<a id="check-salesforce-instances"></a>

*Salesforce Instance %s*

### sansymphony_alerts

<a id="check-sansymphony-alerts"></a>

*sansymphony Alerts*

### sansymphony_pool

<a id="check-sansymphony-pool"></a>

*Sansymphony Pool %s*

### sansymphony_ports

<a id="check-sansymphony-ports"></a>

*sansymphony Port %s*

### sansymphony_serverstatus

<a id="check-sansymphony-serverstatus"></a>

*sansymphony Serverstatus*

### sansymphony_virtualdiskstatus

<a id="check-sansymphony-virtualdiskstatus"></a>

*sansymphony Virtual Disk %s*

### sap_dialog

<a id="check-sap-dialog"></a>

*%s Dialog*

### sap_hana_backup

<a id="check-sap-hana-backup"></a>

*SAP HANA Backup %s*

### sap_hana_connect

<a id="check-sap-hana-connect"></a>

*SAP HANA CONNECT %s*

### sap_hana_data_volume

<a id="check-sap-hana-data-volume"></a>

*SAP HANA Volume %s*

### sap_hana_db_status

<a id="check-sap-hana-db-status"></a>

*SAP HANA Database Status %s*

### sap_hana_diskusage

<a id="check-sap-hana-diskusage"></a>

*SAP HANA Disk %s*

### sap_hana_ess

<a id="check-sap-hana-ess"></a>

*SAP HANA ESS %s*

### sap_hana_ess_migration

<a id="check-sap-hana-ess-migration"></a>

*SAP HANA ESS Migration %s*

### sap_hana_events

<a id="check-sap-hana-events"></a>

*SAP HANA Events %s*

### sap_hana_fileinfo

<a id="check-sap-hana-fileinfo"></a>

*File %s*

### sap_hana_fileinfo_groups

<a id="check-sap-hana-fileinfo-groups"></a>

*File group %s*

### sap_hana_instance_status

<a id="check-sap-hana-instance-status"></a>

*SAP HANA Instance Status %s*

### sap_hana_license

<a id="check-sap-hana-license"></a>

*SAP HANA License %s*

### sap_hana_memrate

<a id="check-sap-hana-memrate"></a>

*SAP HANA Memory %s*

### sap_hana_proc

<a id="check-sap-hana-proc"></a>

*SAP HANA Process %s*

### sap_hana_replication_status

<a id="check-sap-hana-replication-status"></a>

*SAP HANA Replication Status %s*

### sap_hana_status

<a id="check-sap-hana-status"></a>

*SAP HANA %s*

### sap_value

<a id="check-sap-value"></a>

*%s*

### sap_value_groups

<a id="check-sap-value-groups"></a>

*%s*

### scaleio_devices

<a id="check-scaleio-devices"></a>

*ScaleIO Data Server %s Devices*

### scaleio_mdm

<a id="check-scaleio-mdm"></a>

*ScaleIO cluster status*

### scaleio_pd

<a id="check-scaleio-pd"></a>

*ScaleIO PD capacity %s*

### scaleio_pd_status

<a id="check-scaleio-pd-status"></a>

*ScaleIO PD status %s*

### scaleio_sds

<a id="check-scaleio-sds"></a>

*ScaleIO SDS capacity %s*

### scaleio_sds_status

<a id="check-scaleio-sds-status"></a>

*ScaleIO SDS status %s*

### scaleio_storage_pool

<a id="check-scaleio-storage-pool"></a>

*ScaleIO SP capacity %s*

### scaleio_storage_pool_rebalancerw

<a id="check-scaleio-storage-pool-rebalancerw"></a>

*ScaleIO SP rebalance IO %s*

### scaleio_storage_pool_totalrw

<a id="check-scaleio-storage-pool-totalrw"></a>

*ScaleIO SP total IO %s*

### scaleio_system

<a id="check-scaleio-system"></a>

*ScaleIO System %s*

### scaleio_volume

<a id="check-scaleio-volume"></a>

*ScaleIO Volume %s*

### security_master

<a id="check-security-master"></a>

*Sensor %s*

### security_master_humidity

<a id="check-security-master-humidity"></a>

*Sensor %s*

### security_master_temp

<a id="check-security-master-temp"></a>

*Sensor %s*

### seh_ports

<a id="check-seh-ports"></a>

*Port %s*

### sensatronics_temp

<a id="check-sensatronics-temp"></a>

*Temperature %s*

### sentry_pdu

<a id="check-sentry-pdu"></a>

*Plug %s*

### sentry_pdu_outlets

<a id="check-sentry-pdu-outlets"></a>

*Outlet %s*

### sentry_pdu_outlets_v4

<a id="check-sentry-pdu-outlets-v4"></a>

*Outlet %s*

### sentry_pdu_v4

<a id="check-sentry-pdu-v4"></a>

*Plug %s*

### services

<a id="check-services"></a>

*Service %s*

### services_summary

<a id="check-services-summary"></a>

*Service Summary*

### sftp

<a id="check-sftp"></a>

### siemens_plc_counter

<a id="check-siemens-plc-counter"></a>

*Counter %s*

### siemens_plc_cpu_state

<a id="check-siemens-plc-cpu-state"></a>

*CPU state*

### siemens_plc_duration

<a id="check-siemens-plc-duration"></a>

*Duration %s*

### siemens_plc_flag

<a id="check-siemens-plc-flag"></a>

*Flag %s*

### siemens_plc_info

<a id="check-siemens-plc-info"></a>

*Info %s*

### siemens_plc_temp

<a id="check-siemens-plc-temp"></a>

*Temperature %s*

### silverpeak_VX6000

<a id="check-silverpeak-vx6000"></a>

*Alarms*

### site_object_counts

<a id="check-site-object-counts"></a>

*OMD objects*

### skype

<a id="check-skype"></a>

*Skype Web Components*

### skype_conferencing

<a id="check-skype-conferencing"></a>

*Skype Conferencing*

### skype_data_proxy

<a id="check-skype-data-proxy"></a>

*Skype Data Proxy %s*

### skype_edge

<a id="check-skype-edge"></a>

*Skype AV Edge %s*

### skype_edge_auth

<a id="check-skype-edge-auth"></a>

*Skype Edge Authentification*

### skype_mcu

<a id="check-skype-mcu"></a>

*Skype MCU Health*

### skype_mediation_server

<a id="check-skype-mediation-server"></a>

*Skype Mediation Server*

### skype_mobile

<a id="check-skype-mobile"></a>

*Skype Mobile Sessions*

### skype_sip_stack

<a id="check-skype-sip-stack"></a>

*Skype SIP Stack*

### skype_xmpp_proxy

<a id="check-skype-xmpp-proxy"></a>

*Skype XMPP Proxy*

### smart_ata_stats

<a id="check-smart-ata-stats"></a>

*SMART %s Stats*

### smart_ata_temp

<a id="check-smart-ata-temp"></a>

*Temperature SMART %s*

### smart_nvme_stats

<a id="check-smart-nvme-stats"></a>

*SMART %s Stats*

### smart_nvme_temp

<a id="check-smart-nvme-temp"></a>

*Temperature SMART %s*

### smart_scsi_temp

<a id="check-smart-scsi-temp"></a>

*Temperature SMART %s*

### smtp

<a id="check-smtp"></a>

### sni_octopuse_cpu

<a id="check-sni-octopuse-cpu"></a>

*CPU utilization*

### sni_octopuse_status

<a id="check-sni-octopuse-status"></a>

*Global status*

### sni_octopuse_trunks

<a id="check-sni-octopuse-trunks"></a>

*Trunk Port %s*

### snmp_info

<a id="check-snmp-info"></a>

*SNMP Info*

### solaris_fmadm

<a id="check-solaris-fmadm"></a>

*FMD Status*

### solaris_multipath

<a id="check-solaris-multipath"></a>

*Multipath %s*

### solaris_prtdiag_status

<a id="check-solaris-prtdiag-status"></a>

*Hardware Overall State*

### solaris_services

<a id="check-solaris-services"></a>

*SMF Service %s*

### solaris_services_summary

<a id="check-solaris-services-summary"></a>

*SMF Services Summary*

### sql

<a id="check-sql"></a>

### ssh

<a id="check-ssh"></a>

### sshd_config

<a id="check-sshd-config"></a>

*SSH daemon configuration*

### statgrab_cpu

<a id="check-statgrab-cpu"></a>

*CPU utilization*

### storcli_cache_vault

<a id="check-storcli-cache-vault"></a>

*RAID cache vault %s*

### storcli_pdisks

<a id="check-storcli-pdisks"></a>

*RAID PDisk EID:Slot-Device %s*

### storcli_vdrives

<a id="check-storcli-vdrives"></a>

*RAID Virtual Drive %s*

### storeonce4x_appliances

<a id="check-storeonce4x-appliances"></a>

*Appliance %s Status*

### storeonce4x_appliances_license

<a id="check-storeonce4x-appliances-license"></a>

*Appliance %s License*

### storeonce4x_appliances_storage

<a id="check-storeonce4x-appliances-storage"></a>

*Appliance %s Storage*

### storeonce4x_appliances_summaries

<a id="check-storeonce4x-appliances-summaries"></a>

*Appliance %s Summaries*

### storeonce4x_cat_stores

<a id="check-storeonce4x-cat-stores"></a>

*Catalyst Stores %s*

### storeonce_clusterinfo

<a id="check-storeonce-clusterinfo"></a>

*%s*

### storeonce_clusterinfo_cluster

<a id="check-storeonce-clusterinfo-cluster"></a>

*Appliance Status*

### storeonce_clusterinfo_space

<a id="check-storeonce-clusterinfo-space"></a>

*%s*

### storeonce_clusterinfo_uptime

<a id="check-storeonce-clusterinfo-uptime"></a>

*Uptime*

### storeonce_servicesets

<a id="check-storeonce-servicesets"></a>

*ServiceSet %s Status*

### storeonce_servicesets_capacity

<a id="check-storeonce-servicesets-capacity"></a>

*ServiceSet %s Capacity*

### storeonce_stores

<a id="check-storeonce-stores"></a>

*%s*

### stormshield_cluster

<a id="check-stormshield-cluster"></a>

*HA Status*

### stormshield_cluster_node

<a id="check-stormshield-cluster-node"></a>

*HA Member %s*

### stormshield_cpu_temp

<a id="check-stormshield-cpu-temp"></a>

*CPU Temp %s*

### stormshield_disk

<a id="check-stormshield-disk"></a>

*Disk %s*

### stormshield_info

<a id="check-stormshield-info"></a>

*Stormshield Info*

### stormshield_packets

<a id="check-stormshield-packets"></a>

*Packet Stats %s*

### stormshield_policy

<a id="check-stormshield-policy"></a>

*Policy %s*

### stormshield_route

<a id="check-stormshield-route"></a>

*Gateway %s*

### stormshield_services

<a id="check-stormshield-services"></a>

*Service %s*

### stormshield_updates

<a id="check-stormshield-updates"></a>

*Autoupdate %s*

### strem1_sensors

<a id="check-strem1-sensors"></a>

*Sensor - %s*

### supermicro

<a id="check-supermicro"></a>

*Overall Hardware Health*

### supermicro_sensors

<a id="check-supermicro-sensors"></a>

*Sensor %s*

### supermicro_smart

<a id="check-supermicro-smart"></a>

*SMART Health %s*

### superstack3_sensors

<a id="check-superstack3-sensors"></a>

*%s*

### suseconnect

<a id="check-suseconnect"></a>

*SLES license*

### sylo

<a id="check-sylo"></a>

*Sylo*

### sym_brightmail_queues

<a id="check-sym-brightmail-queues"></a>

*Queue %s*

### symantec_av_progstate

<a id="check-symantec-av-progstate"></a>

*AV Program Status*

### symantec_av_quarantine

<a id="check-symantec-av-quarantine"></a>

*AV Quarantine*

### symantec_av_updates

<a id="check-symantec-av-updates"></a>

*AV Update Status*

### synology_disks

<a id="check-synology-disks"></a>

*Disks %s*

### synology_fans

<a id="check-synology-fans"></a>

*Fan %s*

### synology_info

<a id="check-synology-info"></a>

*Info*

### synology_raid

<a id="check-synology-raid"></a>

*Raid %s*

### synology_status

<a id="check-synology-status"></a>

*Status*

### synology_update

<a id="check-synology-update"></a>

*Update*

### systemd_units_services

<a id="check-systemd-units-services"></a>

*Systemd Service %s*

### systemd_units_services_summary

<a id="check-systemd-units-services-summary"></a>

*Systemd Service Summary*

### systemd_units_sockets

<a id="check-systemd-units-sockets"></a>

*Systemd Socket %s*

### systemd_units_sockets_summary

<a id="check-systemd-units-sockets-summary"></a>

*Systemd Socket Summary*

### systemtime

<a id="check-systemtime"></a>

*System Time*

### tcp

<a id="check-tcp"></a>

### tcp_conn_stats

<a id="check-tcp-conn-stats"></a>

*TCP Connections*

### teracom_tcw241_analog

<a id="check-teracom-tcw241-analog"></a>

*Analog Sensor %s*

### teracom_tcw241_digital

<a id="check-teracom-tcw241-digital"></a>

*Digital Sensor %s*

### timemachine

<a id="check-timemachine"></a>

### timesyncd

<a id="check-timesyncd"></a>

*Systemd Timesyncd Time*

### traceroute

<a id="check-traceroute"></a>

### tsm_drives

<a id="check-tsm-drives"></a>

*TSM Drive %s*

### tsm_paths

<a id="check-tsm-paths"></a>

*TSM Paths*

### tsm_scratch

<a id="check-tsm-scratch"></a>

*Scratch Pool %s*

### tsm_sessions

<a id="check-tsm-sessions"></a>

*tsm_sessions*

### tsm_stagingpools

<a id="check-tsm-stagingpools"></a>

*TSM Stagingpool %s*

### tsm_storagepools

<a id="check-tsm-storagepools"></a>

*TSM Storagepool %s*

### ucd_cpu_util

<a id="check-ucd-cpu-util"></a>

*CPU utilization*

### ucd_disk

<a id="check-ucd-disk"></a>

*Filesystem %s*

### ucd_diskio

<a id="check-ucd-diskio"></a>

*Disk IO %s*

### ucd_processes

<a id="check-ucd-processes"></a>

*Processes %s*

### uniserv

<a id="check-uniserv"></a>

### unitrends_backup

<a id="check-unitrends-backup"></a>

*Schedule %s*

### unitrends_replication

<a id="check-unitrends-replication"></a>

*Replicaion %s*

### ups_bat_temp

<a id="check-ups-bat-temp"></a>

*Temperature %s*

### ups_battery_state

<a id="check-ups-battery-state"></a>

*Battery state*

### ups_capacity

<a id="check-ups-capacity"></a>

*Battery capacity*

### ups_cps_battery

<a id="check-ups-cps-battery"></a>

*UPS Battery*

### ups_cps_battery_temp

<a id="check-ups-cps-battery-temp"></a>

*Temperature %s*

### ups_cps_inphase

<a id="check-ups-cps-inphase"></a>

*UPS Input Phase %s*

### ups_cps_outphase

<a id="check-ups-cps-outphase"></a>

*UPS Output Phase %s*

### ups_eaton_enviroment

<a id="check-ups-eaton-enviroment"></a>

*Enviroment*

### ups_in_freq

<a id="check-ups-in-freq"></a>

*IN frequency phase %s*

### ups_in_voltage

<a id="check-ups-in-voltage"></a>

*IN voltage phase %s*

### ups_modulys_alarms

<a id="check-ups-modulys-alarms"></a>

*UPS Alarms*

### ups_modulys_battery

<a id="check-ups-modulys-battery"></a>

*Battery Charge*

### ups_modulys_battery_temp

<a id="check-ups-modulys-battery-temp"></a>

*Temperature %s*

### ups_modulys_inphase

<a id="check-ups-modulys-inphase"></a>

*Input %s*

### ups_modulys_outphase

<a id="check-ups-modulys-outphase"></a>

*Output %s*

### ups_out_load

<a id="check-ups-out-load"></a>

*OUT load phase %s*

### ups_out_voltage

<a id="check-ups-out-voltage"></a>

*OUT voltage phase %s*

### ups_socomec_capacity

<a id="check-ups-socomec-capacity"></a>

*Battery capacity*

### ups_socomec_in_voltage

<a id="check-ups-socomec-in-voltage"></a>

*IN voltage phase %s*

### ups_socomec_out_source

<a id="check-ups-socomec-out-source"></a>

*Output Source*

### ups_socomec_out_voltage

<a id="check-ups-socomec-out-voltage"></a>

*OUT voltage phase %s*

### ups_socomec_outphase

<a id="check-ups-socomec-outphase"></a>

*Output %s*

### ups_test

<a id="check-ups-test"></a>

*Self Test*

### varnish

<a id="check-varnish"></a>

*Varnish Uptime*

### varnish_backend

<a id="check-varnish-backend"></a>

*Varnish Backend*

### varnish_cache

<a id="check-varnish-cache"></a>

*Varnish Cache*

### varnish_cache_hit_ratio

<a id="check-varnish-cache-hit-ratio"></a>

*Varnish Cache Hit Ratio*

### varnish_client

<a id="check-varnish-client"></a>

*Varnish Client*

### varnish_esi

<a id="check-varnish-esi"></a>

*Varnish ESI*

### varnish_fetch

<a id="check-varnish-fetch"></a>

*Varnish Fetch*

### varnish_objects

<a id="check-varnish-objects"></a>

*Varnish Objects*

### varnish_worker

<a id="check-varnish-worker"></a>

*Varnish Worker*

### varnish_worker_thread_ratio

<a id="check-varnish-worker-thread-ratio"></a>

*Varnish Worker Thread Ratio*

### vbox_guest

<a id="check-vbox-guest"></a>

*VBox Guest Additions*

### veeam_cdp_jobs

<a id="check-veeam-cdp-jobs"></a>

*VEEAM CDP Job %s*

### veeam_jobs

<a id="check-veeam-jobs"></a>

*VEEAM Job %s*

### veeam_tapejobs

<a id="check-veeam-tapejobs"></a>

*VEEAM Tape Job %s*

### veritas_vcs

<a id="check-veritas-vcs"></a>

*VCS Cluster %s*

### veritas_vcs_resource

<a id="check-veritas-vcs-resource"></a>

*VCS Resource %s*

### veritas_vcs_servicegroup

<a id="check-veritas-vcs-servicegroup"></a>

*VCS Service Group %s*

### veritas_vcs_system

<a id="check-veritas-vcs-system"></a>

*VCS System %s*

### viprinet_firmware

<a id="check-viprinet-firmware"></a>

*Firmware Version*

### viprinet_mem

<a id="check-viprinet-mem"></a>

*Memory*

### vms_cpu

<a id="check-vms-cpu"></a>

*CPU utilization*

### vms_diskstat_df

<a id="check-vms-diskstat-df"></a>

*Filesystem %s*

### vms_system_ios

<a id="check-vms-system-ios"></a>

*IOs*

### vms_system_procs

<a id="check-vms-system-procs"></a>

*Number of processes*

### vms_users

<a id="check-vms-users"></a>

*VMS Users*

### vnx_quotas

<a id="check-vnx-quotas"></a>

*VNX Quota %s*

### vutlan_ems_smoke

<a id="check-vutlan-ems-smoke"></a>

*Smoke Detector %s*

### vxvm_enclosures

<a id="check-vxvm-enclosures"></a>

*Enclosure %s*

### vxvm_multipath

<a id="check-vxvm-multipath"></a>

*Multipath %s*

### vxvm_objstatus

<a id="check-vxvm-objstatus"></a>

*VXVM objstatus %s*

### w32time_status

<a id="check-w32time-status"></a>

*Windows time service*

### wagner_titanus_topsense_airflow_deviation

<a id="check-wagner-titanus-topsense-airflow-deviation"></a>

*Airflow Deviation Detector %s*

### wagner_titanus_topsense_alarm

<a id="check-wagner-titanus-topsense-alarm"></a>

*Alarm Detector %s*

### wagner_titanus_topsense_chamber_deviation

<a id="check-wagner-titanus-topsense-chamber-deviation"></a>

*Chamber Deviation Detector %s*

### wagner_titanus_topsense_info

<a id="check-wagner-titanus-topsense-info"></a>

*Topsense Info*

### wagner_titanus_topsense_overall_status

<a id="check-wagner-titanus-topsense-overall-status"></a>

*Overall Status*

### wagner_titanus_topsense_smoke

<a id="check-wagner-titanus-topsense-smoke"></a>

*Smoke Detector %s*

### wagner_titanus_topsense_temp

<a id="check-wagner-titanus-topsense-temp"></a>

*Temperature %s*

### watchdog_sensors

<a id="check-watchdog-sensors"></a>

*%s*

### watchdog_sensors_dew

<a id="check-watchdog-sensors-dew"></a>

*%s*

### watchdog_sensors_humidity

<a id="check-watchdog-sensors-humidity"></a>

*%s*

### watchdog_sensors_temp

<a id="check-watchdog-sensors-temp"></a>

*%s*

### win_dhcp_pools

<a id="check-win-dhcp-pools"></a>

*DHCP Pool %s*

### win_dhcp_pools_stats

<a id="check-win-dhcp-pools-stats"></a>

*DHCP Stats*

### win_license

<a id="check-win-license"></a>

*Windows License*

### win_netstat

<a id="check-win-netstat"></a>

*TCP Connection %s*

### win_printers

<a id="check-win-printers"></a>

*Printer %s*

### windows_broadcom_bonding

<a id="check-windows-broadcom-bonding"></a>

*Bonding Interface %s*

### windows_intel_bonding

<a id="check-windows-intel-bonding"></a>

*Bonding interface %s*

### windows_multipath

<a id="check-windows-multipath"></a>

*Multipath*

### windows_tasks

<a id="check-windows-tasks"></a>

*Task %s*

### windows_updates

<a id="check-windows-updates"></a>

*System Updates*

### winperf_if

<a id="check-winperf-if"></a>

*Interface %s*

### winperf_mem

<a id="check-winperf-mem"></a>

*Memory Pages*

### winperf_msx_queues

<a id="check-winperf-msx-queues"></a>

*Queue %s*

### winperf_phydisk

<a id="check-winperf-phydisk"></a>

*Disk IO %s*

### winperf_ts_sessions

<a id="check-winperf-ts-sessions"></a>

*Sessions*

### wmi_webservices

<a id="check-wmi-webservices"></a>

*Web Service %s*

### wmic_process

<a id="check-wmic-process"></a>

*Process %s*

### wut_webio

<a id="check-wut-webio"></a>

*Check plug-in for W&T WebIO device*

### wut_webtherm

<a id="check-wut-webtherm"></a>

*Temperature %s*

### wut_webtherm_pressure

<a id="check-wut-webtherm-pressure"></a>

*Pressure %s*

### zebra_model

<a id="check-zebra-model"></a>

*Zebra Printer Model*

### zebra_printer_status

<a id="check-zebra-printer-status"></a>

*Zebra Printer Status*

### zertificon_mail_queues

<a id="check-zertificon-mail-queues"></a>

*Zertificon Mail Queues*

### zerto_agent

<a id="check-zerto-agent"></a>

*Zerto Agent Status*

### zerto_vpg_rpo

<a id="check-zerto-vpg-rpo"></a>

*Zerto VPG RPO %s*

### zfs_arc_cache

<a id="check-zfs-arc-cache"></a>

*ZFS arc cache*

### zfs_arc_cache_l2

<a id="check-zfs-arc-cache-l2"></a>

*ZFS arc cache L2*

### zfsget

<a id="check-zfsget"></a>

*Filesystem %s*

### zorp_connections

<a id="check-zorp-connections"></a>

*Zorp FW - connections*

### zpool

<a id="check-zpool"></a>

*Storage Pool %s*

### zpool_status

<a id="check-zpool-status"></a>

*zpool status*

### zypper

<a id="check-zypper"></a>

*Zypper Updates*

