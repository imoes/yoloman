def _collect_lvm(ctx):
    vgs_res = ctx.run(["lsvg"], mutates=False, ok_codes=[0, 1])
    if vgs_res.rc != 0 or not vgs_res.stdout.strip():
        return {}
    lvmconf = {}
    for vg in [v.strip() for v in vgs_res.stdout.splitlines() if v.strip()]:
        lv_res = ctx.run(["lsvg", "-l", vg], mutates=False, ok_codes=[0, 1])
        if lv_res.rc != 0:
            continue
        lvmconf[vg] = {}
        for line in lv_res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 7:
                continue
            if parts[0] == "LV" and parts[1] == "NAME":
                continue
            if not (parts[2].isdigit() and parts[3].isdigit() and parts[4].isdigit()):
                continue
            act_parts = parts[5].split("/")
            if len(act_parts) != 2:
                continue
            mountpoint = "" if parts[6] == "N/A" else parts[6]
            lvmconf[vg][parts[0]] = {
                "lvtype": parts[1],
                "num_lp": int(parts[2]),
                "num_pp": int(parts[3]),
                "num_pv": int(parts[4]),
                "activation": act_parts[0],
                "mirror": act_parts[1],
                "mountpoint": mountpoint,
            }
    return lvmconf


def main(ctx, params):
    lvmconf = _collect_lvm(ctx)

    if params.get("_discover"):
        items = []
        for vg, volumes in lvmconf.items():
            for lv in volumes:
                items.append({
                    "item": vg + "/" + lv,
                    "params": {},
                    "metrics": ["num_lp", "num_pp", "num_pv"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    slash = item.find("/")
    if slash < 0:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_vg = item[:slash]
    target_lv = item[slash + 1:]

    vg_data = lvmconf.get(target_vg)
    if vg_data == None:
        return {
            "changed": False,
            "msg": "no such volume found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lv_data = vg_data.get(target_lv)
    if lv_data == None:
        return {
            "changed": False,
            "msg": "no such volume found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lvtype = lv_data["lvtype"]
    num_lp = lv_data["num_lp"]
    num_pp = lv_data["num_pp"]
    num_pv = lv_data["num_pv"]
    activation = lv_data["activation"]
    mirror = lv_data["mirror"]

    msgs = []
    state = 0

    if num_lp > 0 and (num_pp // num_lp) > 1:
        if num_pv > 0 and (num_pp // num_pv) != num_lp:
            msgs.append("LV Mirrors are misaligned between physical volumes(!)")
            state = 1

    if lvtype != "boot" and activation != "open":
        msgs.append("LV is not opened(!)")
        if state < 1:
            state = 1

    if mirror != "syncd":
        msgs.append("LV is not in sync state(!!)")
        if state < 2:
            state = 2

    if state == 0:
        summary = "LV is open/syncd"
    else:
        summary = ", ".join(msgs)

    state_names = {0: "OK", 1: "WARN", 2: "CRIT"}
    state_str = state_names.get(state, "UNKNOWN")

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {"num_lp": num_lp, "num_pp": num_pp, "num_pv": num_pv},
            "details": "",
        },
    }