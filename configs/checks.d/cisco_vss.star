def main(ctx, params):
    if params.get("_discover"):
        # Discovery: yield one service if any chassis has role active(2) or standby(3)
        chassis = ctx.run([
            "snmpwalk", "-On", "-c", "public", "-v", "2c",
            "localhost", ".1.3.6.1.4.1.9.9.388.1.2.2.1.2"
        ], mutates=False)
        for line in chassis.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 2:
                role = parts[-1].strip()
                if role in ("2", "3"):
                    return {
                        "changed": False,
                        "msg": "discovered VSS service",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
                    }
        return {"changed": False, "msg": "no VSS chassis found", "data": {"discovery": []}}

    # Check mode: gather chassis and VSL data
    chassis = ctx.run([
        "snmpwalk", "-On", "-c", "public", "-v", "2c",
        "localhost", ".1.3.6.1.4.1.9.9.388.1.2.2.1"
    ], mutates=False)
    ports = ctx.run([
        "snmpwalk", "-On", "-c", "public", "-v", "2c",
        "localhost", ".1.3.6.1.4.1.9.9.388.1.3.1.1"
    ], mutates=False)

    # Parse chassis section: .1.3.6.1.4.1.9.9.388.1.2.2.1.<index>.2 (chassisRole)
    chassis_data = []
    for line in chassis.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0].endswith(".2"):
            idx_part = parts[0].rsplit(".", 1)[0].split(".")[-1]
            switch_id = parts[0].split(".")[-2]  # chassisSwitchID is .1, chassisRole is .2
            role = parts[-1].strip()
            chassis_data.append((switch_id, role))

    # Parse ports section: VSL entries (.1.3.6.1.4.1.9.9.388.1.3.1.1.<index>.<oid>)
    # We need to group by index. Extract: coreSwitchID(.2), operStatus(.3), configuredPortCount(.5), operationalPortCount(.6)
    port_data = {}
    for line in ports.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            oid_parts = parts[0].split(".")
            if len(oid_parts) >= 9:
                base_idx = ".".join(oid_parts[-5:-1])  # e.g. "1.3.1.1"
                suffix = oid_parts[-1]
                if suffix in ("2", "3", "5", "6"):
                    # Get index from oid_parts[9] (e.g., 41, 42, 1000, etc.)
                    idx = oid_parts[9]
                    if idx not in port_data:
                        port_data[idx] = {}
                    port_data[idx][suffix] = parts[-1].strip()

    # Build port entries: coreSwitchID, operStatus, conf_portcount, op_portcount
    port_entries = []
    for idx, vals in port_data.items():
        core_switch_id = vals.get("2", "")
        operstatus = vals.get("3", "")
        conf_portcount = vals.get("5", "")
        op_portcount = vals.get("6", "")
        # Only include if core_switch_id is set
        if core_switch_id:
            port_entries.append((core_switch_id, operstatus, conf_portcount, op_portcount))

    # Generate check results
    details_parts = []
    state = "OK"
    role_names = {"1": "standalone", "2": "active", "3": "standby"}
    operstatus_names = {"1": "up", "2": "down"}

    for switch_id, chassis_role in chassis_data:
        if chassis_role == "1":
            state = "CRIT"
        elif state != "CRIT":
            state = "OK"
        details_parts.append("chassis %s: %s" % (switch_id, role_names.get(chassis_role, chassis_role)))

    details_parts.append("%d VSL connections configured" % len(port_entries))

    for core_switch_id, operstatus, conf_portcount, op_portcount in port_entries:
        if operstatus == "1":
            if state == "OK":
                state = "OK"
        else:
            state = "CRIT"
        details_parts.append("core switch %s: VSL %s" % (core_switch_id, operstatus_names.get(operstatus, operstatus)))

        if conf_portcount.isdigit() and op_portcount.isdigit():
            if conf_portcount != op_portcount:
                state = "CRIT"
            details_parts.append("%s/%s ports operational" % (op_portcount, conf_portcount))
        else:
            details_parts.append("%s/%s ports operational" % (op_portcount, conf_portcount))

    msg = "; ".join(details_parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
