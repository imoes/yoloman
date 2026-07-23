# raid state mappings: Checkmk state from arc_raid_status
RAID_STATE_MAP = {
    "Checking": "OK",
    "Normal": "OK",
    "Rebuilding": "WARN",
    "Degrade": "CRIT",
    "Incompleted": "CRIT",
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/arc_raid_status"], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 8:
                continue
            # Format: <idx> Raid Set # <num> ... <n_disks> ... <state>
            # We only care about first field (array number) and last field (state)
            # Extract array number: line format starts with index (e.g. "1"), then "Raid Set #", then number
            array_num = parts[0]
            # Guard before converting n_disks
            n_disks_str = parts[-5]
            if not n_disks_str.isdigit():
                continue
            n_disks = int(n_disks_str)
            out.append({"item": array_num, "params": {"n_disks": n_disks},
                        "metrics": []})
        return {"changed": False, "msg": "discovered %d raid arrays" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/arc_raid_status"], mutates=False)
    lines = res.stdout.splitlines()
    data_line = None
    for line in lines:
        parts = line.split()
        if len(parts) < 8:
            continue
        if parts[0] == item:
            data_line = parts
            break

    if data_line == None:
        return {"changed": False, "msg": "raid array %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raid_state = data_line[-1]
    state_str = RAID_STATE_MAP.get(raid_state, "CRIT")
    state = state_str if state_str in ("OK", "WARN", "CRIT", "UNKNOWN") else "CRIT"

    # Check disk count
    n_disks_str = data_line[-5]
    if not n_disks_str.isdigit():
        return {"changed": False,
                "msg": raid_state.title() + ", disk count invalid",
                "data": {"state": state, "metrics": {}, "details": ""}}

    i_disks = params.get("n_disks", 0)
    c_disks = int(n_disks_str)

    msg_parts = [raid_state.title()]
    if i_disks != c_disks:
        msg_parts.append("Number of disks has changed from %d to %d" % (i_disks, c_disks))

    return {"changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}}
