def main(ctx, params):
    active_zones = params.get("active_zones", False)
    zones_list = params.get("zones", [])

    # Check required dependencies via CLI (firewall-cmd) instead of Python imports
    # First verify firewalld is running
    res = ctx.run(["systemctl", "is-active", "firewalld"], mutates=False, ok_codes=[0, 3])
    if res.rc == 3:
        fail("firewalld is not running")

    # Verify firewall-cmd is available
    res = ctx.run(["which", "firewall-cmd"], mutates=False)
    if res.rc != 0:
        fail("firewall-cmd is not installed")

    # Gather general information
    default_zone_res = ctx.run(["firewall-cmd", "--get-default-zone"], mutates=False)
    if default_zone_res.rc != 0:
        fail("failed to get default zone: " + default_zone_res.stderr)

    version_res = ctx.run(["firewall-cmd", "--version"], mutates=False)
    if version_res.rc != 0:
        fail("failed to get firewalld version: " + version_res.stderr)
    version = version_res.stdout.strip()

    # Determine which zones to collect
    if active_zones:
        zones_res = ctx.run(["firewall-cmd", "--get-active-zones"], mutates=False)
        if zones_res.rc != 0:
            fail("failed to get active zones: " + zones_res.stderr)
        # Parse active zones (format: zone name on line, interfaces/sources indented)
        all_zones_set = set()
        for line in zones_res.stdout.strip().splitlines():
            if line and not line.startswith(" ") and not line.startswith("\t"):
                all_zones_set.add(line.strip())
        collect_zones = sorted(list(all_zones_set))
        undefined_zones = []
    elif zones_list:
        # Get all available zones
        all_zones_res = ctx.run(["firewall-cmd", "--get-zones"], mutates=False)
        if all_zones_res.rc != 0:
            fail("failed to get all zones: " + all_zones_res.stderr)
        all_zones_set = set(all_zones_res.stdout.strip().split())
        specified_zones_set = set(zones_list)
        collect_zones = sorted(list(specified_zones_set & all_zones_set))
        undefined_zones = sorted(list(specified_zones_set - all_zones_set))
    else:
        # Get all zones
        all_zones_res = ctx.run(["firewall-cmd", "--get-zones"], mutates=False)
        if all_zones_res.rc != 0:
            fail("failed to get all zones: " + all_zones_res.stderr)
        collect_zones = sorted(all_zones_res.stdout.strip().split())
        undefined_zones = []

    # Build zones_info
    zones_info = {}
    for zone in collect_zones:
        zone_res = ctx.run(["firewall-cmd", "--info-zone=" + zone], mutates=False)
        if zone_res.rc != 0:
            fail("failed to get zone info for " + zone + ": " + zone_res.stderr)
        
        zone_info = {
            "target": "",
            "icmp_block_inversion": False,
            "interfaces": [],
            "sources": [],
            "services": [],
            "ports": [],
            "protocols": [],
            "masquerade": False,
            "forward_ports": [],
            "source_ports": [],
            "icmp_blocks": [],
            "rich_rules": []
        }

        for line in zone_res.stdout.strip().splitlines():
            parts = line.strip().split(": ")
            if len(parts) == 2:
                key, value = parts
                if key == "target":
                    zone_info["target"] = value
                elif key == "interfaces":
                    zone_info["interfaces"] = [i.strip() for i in value.split(",") if i.strip()]
                elif key == "sources":
                    zone_info["sources"] = [s.strip() for s in value.split(",") if s.strip()]
                elif key == "services":
                    zone_info["services"] = [s.strip() for s in value.split(",") if s.strip()]
                elif key == "ports":
                    zone_info["ports"] = [[p.strip() for p in part.split()] for part in value.split(",") if part.strip()]
                elif key == "protocols":
                    zone_info["protocols"] = [p.strip() for p in value.split(",") if p.strip()]
                elif key == "masquerade":
                    zone_info["masquerade"] = value == "yes"
                elif key == "forward-ports":
                    if value != "":
                        zone_info["forward_ports"] = [[p.strip() for p in part.split()] for part in value.split(",") if part.strip()]
                elif key == "source-ports":
                    zone_info["source_ports"] = [[p.strip() for p in part.split()] for part in value.split(",") if part.strip()]
                elif key == "icmp-blocks":
                    zone_info["icmp_blocks"] = [b.strip() for b in value.split(",") if b.strip()]
                elif key == "rich rules":
                    zone_info["rich_rules"] = [r.strip() for r in value.split(",") if r.strip()]

        # Parse ICMP block inversion
        inv_res = ctx.run(["firewall-cmd", "--zone=" + zone, "--query-icmp-block-inversion"], mutates=False)
        if inv_res.rc == 0:
            zone_info["icmp_block_inversion"] = True

        # Parse forward (requires firewall-cmd >= 0.9.0)
        fwd_res = ctx.run(["firewall-cmd", "--zone=" + zone, "--query-forward"], mutates=False)
        if fwd_res.rc == 0:
            zone_info["forward"] = True

        zones_info[zone] = zone_info

    # Return result
    result = {
        "changed": False,
        "active_zones": active_zones,
        "collected_zones": collect_zones,
        "undefined_zones": undefined_zones,
        "warnings": []  # Could add warning for undefined zones if needed
    }

    if zones_info:
        result["firewalld_info"] = {
            "version": version,
            "default_zone": default_zone_res.stdout.strip(),
            "zones": zones_info
        }
    else:
        result["firewalld_info"] = {
            "version": version,
            "default_zone": default_zone_res.stdout.strip(),
            "zones": {}
        }

    return result
