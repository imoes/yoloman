def _parse_hpux_lvm(lines):
    section = {}
    vg_name = ""
    lv_name = ""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("vg_name"):
            parts = stripped.split("=", 1)
            if len(parts) == 2:
                vg_name = parts[1].strip()
        elif stripped.startswith("lv_name"):
            parts = stripped.split("=", 1)
            if len(parts) == 2:
                lv_name = parts[1].strip()
        elif stripped.startswith("state") and lv_name != "":
            state_part = stripped.split("=", 1)
            if len(state_part) == 2:
                states_str = state_part[1].strip()
                states = states_str.split(",")
                section[lv_name] = {
                    "group": vg_name,
                    "name": lv_name,
                    "states": states
                }
    return section


def _compute_state(observed_states):
    ok_states = ["available", "syncd", "snapshot", "space_efficient"]
    non_ok = []
    for s in observed_states:
        found = False
        for ok in ok_states:
            if s.strip() == ok:
                found = True
                break
        if not found:
            non_ok.append(s.strip())
    return "CRIT" if len(non_ok) > 0 else "OK"


def main(ctx, params):
    if params.get("_discover") == True:
        res = ctx.run(["lvm", "display", "-v"], mutates=False)
        section = _parse_hpux_lvm(res.stdout.splitlines())
        items = []
        for item in section:
            items.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d logical volumes" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    res = ctx.run(["lvm", "display", "-v"], mutates=False)
    section = _parse_hpux_lvm(res.stdout.splitlines())
    
    volume = section.get(item)
    if volume == None:
        return {
            "changed": False,
            "msg": "logical volume not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = _compute_state(volume["states"])
    state_str = "OK" if state == "OK" else ("CRIT" if state == "CRIT" else "WARN")
    
    return {
        "changed": False,
        "msg": "Status: %s, Volume group: %s" % (",".join(volume["states"]), volume["group"]),
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }