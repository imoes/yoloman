# Top-level constants for state mapping
ADMIN_STATES_OK = ["CLEAN", "ACTIVE"]
KERNEL_STATES_OK = ["ENABLED", "DISABLED"]

def main(ctx, params):
    # Discovery mode: enumerate disk groups with volumes
    if params.get("_discover"):
        res = ctx.run(["/usr/bin/vxprint", "-ht"], mutates=False, ok_codes=[0, 1])
        # Parse vxprint output for volume lines: type dg_name name admin_state kernel_state
        groups = {}
        for line in res.stdout.splitlines():
            fields = line.split()
            # Look for 'v' type lines: v <dg_name> <vol_name> ... <admin_state> <kernel_state>
            if len(fields) >= 7 and fields[0] == "v":
                dg_name = fields[1]
                vol_name = fields[2]
                # Try to find admin_state and kernel_state at the end (they are usually last two fields)
                admin_state = fields[-2] if len(fields) >= 7 else ""
                kernel_state = fields[-1] if len(fields) >= 7 else ""
                # Validate states are non-empty
                if admin_state and kernel_state:
                    if dg_name not in groups:
                        groups[dg_name] = []
                    groups[dg_name].append([vol_name, admin_state, kernel_state])
        discovery_items = []
        for group in groups:
            discovery_items.append({
                "item": group,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d volume groups" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode: validate volumes in given group (item)
    item = params.get("item", "")
    res = ctx.run(["/usr/bin/vxprint", "-ht"], mutates=False, ok_codes=[0, 1])
    
    # Parse same as discovery
    groups = {}
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 7 and fields[0] == "v":
            dg_name = fields[1]
            vol_name = fields[2]
            admin_state = fields[-2] if len(fields) >= 7 else ""
            kernel_state = fields[-1] if len(fields) >= 7 else ""
            if admin_state and kernel_state:
                if dg_name not in groups:
                    groups[dg_name] = []
                groups[dg_name].append([vol_name, admin_state, kernel_state])

    volumes = groups.get(item)
    if volumes != None:
        state = "OK"
        messages = []
        for vol_name, admin_state, kernel_state in volumes:
            text_parts = []
            is_error = False
            if admin_state not in ADMIN_STATES_OK:
                state = "CRIT"
                text_parts.append("%s: Admin state is %s(!!)" % (vol_name, admin_state))
                is_error = True
            if kernel_state not in KERNEL_STATES_OK:
                state = "CRIT"
                text_parts.append("%s: Kernel state is %s(!!)" % (vol_name, kernel_state))
                is_error = True
            if not is_error:
                text_parts.append("%s: OK" % vol_name)
            messages.append(", ".join(text_parts))
        summary = ", ".join(messages)
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }

    # Group not found
    return {
        "changed": False,
        "msg": "Group not found",
        "data": {
            "state": "CRIT",
            "metrics": {},
            "details": ""
        }
    }