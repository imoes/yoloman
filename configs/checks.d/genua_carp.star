def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    discover = params.get("_discover")

    # Constants defined at module top level (redundant, but required)
    CARP_STATE_NAMES = {
        "0": "init",
        "1": "backup",
        "2": "master",
    }

    LINK_STATE_NAMES = {
        "0": "unknown",
        "1": "down",
        "2": "up",
        "3": "hd",
        "4": "fd",
    }

    # OID base for GENUA carp section (both enterprise IDs supported)
    OID_BASE_1 = ".1.3.6.1.4.1.3137.2.1.2.1"
    OID_BASE_2 = ".1.3.6.1.4.1.3717.2.1.2.1"

    # SNMP OIDs to fetch: ifName (.2), ifLinkState (.4), ifCarpState (.7)
    OID_IFNAME = "2"
    OID_LINKSTATE = "4"
    OID_CARPSTATE = "7"

    # Discovery mode: enumerate carp interfaces
    if discover:
        section = _parse_section(ctx, community, host)
        inventory = []
        for ifName, _ifLinkState, ifCarpState in section[0] if section else []:
            # Check carp state validity
            if ifCarpState in ["0", "1", "2"]:
                inventory.append({
                    "item": ifName,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d carp interfaces" % len(inventory),
            "data": {"discovery": inventory}
        }

    # Check mode: analyze one carp interface
    item = params.get("item", "")
    section = _parse_section(ctx, community, host)
    # Filter empty sections
    section = [s for s in section if s]

    if not section or not section[0]:
        return {
            "changed": False,
            "msg": "Invalid Output from Agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # State variables
    state = 0  # OK
    nodes = len(section)
    masters = 0
    output = ""
    prefix = "Cluster test: " if nodes > 1 else "Node test: "

    # Loop over nodes (typically 1 unless cluster)
    for line in section:
        # Loop over interfaces on node
        for ifName, ifLinkState, ifCarpState in line:
            ifLinkStateStr = LINK_STATE_NAMES.get(str(ifLinkState), str(ifLinkState))
            ifCarpStateStr = CARP_STATE_NAMES.get(str(ifCarpState), str(ifCarpState))

            # Check if this is the inventoried interface
            if ifName == item:
                # Master check
                if ifCarpState == "2":
                    masters += 1
                    if masters == 1:
                        if nodes > 1:
                            output = "one "
                        output = output + "node in carp state %s with IfLinkState %s" % (ifCarpStateStr, ifLinkStateStr)
                        # Determine state based on link state
                        if ifLinkState == "2":
                            state = 0  # OK
                        elif ifLinkState == "1":
                            state = 2  # CRIT
                        elif ifLinkState in ["0", "3"]:
                            state = 1  # WARN
                        else:
                            state = 3  # UNKNOWN
                    else:
                        state = 2  # CRIT (multiple masters)
                        output = "%d nodes in carp state %s on cluster with %d nodes" % (masters, ifCarpStateStr, nodes)
                    # Non-master (only interesting if single-node)
                elif nodes == 1:
                    output = "node in carp state %s with IfLinkState %s" % (ifCarpStateStr, ifLinkStateStr)
                    # carp backup
                    if ifCarpState == "1" and ifLinkState == "1":
                        state = 0  # OK
                    else:
                        state = 1  # WARN

    # No masters found in cluster
    if nodes > 1 and masters == 0:
        state = 2  # CRIT
        output = "No master found on cluster with %d nodes" % nodes

    output = prefix + output

    # Map numeric state to Checkmk state names
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    final_state = state_map.get(state, "UNKNOWN")

    return {
        "changed": False,
        "msg": output,
        "data": {"state": final_state, "metrics": {}, "details": ""}
    }


def _parse_section(ctx, community, host):
    """Parse SNMP output into list of [ (ifName, ifLinkState, ifCarpState), ... ]."""
    # Constants
    OID_BASE_1 = ".1.3.6.1.4.1.3137.2.1.2.1"
    OID_BASE_2 = ".1.3.6.1.4.1.3717.2.1.2.1"
    OID_IFNAME = "2"
    OID_LINKSTATE = "4"
    OID_CARPSTATE = "7"

    all_data = []
    for base in [OID_BASE_1, OID_BASE_2]:
        # Get all OIDs
        names = _snmpwalk(ctx, community, host, base, OID_IFNAME)
        linkstates = _snmpwalk(ctx, community, host, base, OID_LINKSTATE)
        carpstates = _snmpwalk(ctx, community, host, base, OID_CARPSTATE)

        # Build map from OID suffix to value
        name_map = {}
        for oid, val in names:
            suffix = oid.rsplit(".", 1)[-1] if "." in oid else oid
            name_map[suffix] = val.strip('"')

        linkstate_map = {}
        for oid, val in linkstates:
            suffix = oid.rsplit(".", 1)[-1] if "." in oid else oid
            linkstate_map[suffix] = val.strip()

        carpstate_map = {}
        for oid, val in carpstates:
            suffix = oid.rsplit(".", 1)[-1] if "." in oid else oid
            carpstate_map[suffix] = val.strip()

        # Join by suffix
        suffixes = set(name_map.keys()) & set(linkstate_map.keys()) & set(carpstate_map.keys())
        for suffix in suffixes:
            all_data.append((name_map.get(suffix, ""), linkstate_map.get(suffix, ""), carpstate_map.get(suffix, "")))

    # Return as list of lists (to mimic section)
    return [all_data] if all_data else []


def _snmpwalk(ctx, community, host, base_oid, sub_oid):
    """Perform snmpwalk on base_oid + '.' + sub_oid, return list of OID-value pairs."""
    full_oid = base_oid + "." + sub_oid
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    out = []
    for line in lines:
        if "=" in line:
            parts = line.strip().split("=", 1)
            if len(parts) == 2:
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                # Extract last component of OID for indexing
                out.append((oid_part, value_part))
    return out
