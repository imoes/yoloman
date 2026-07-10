def main(ctx, params):
    # Parse agent output into structured section
    def parse_aix_lvm(lines):
        lvmconf = {}
        for line in lines:
            if len(line) == 1:
                vgname = line[0][:-1]
                lvmconf.update({vgname: {}})
            elif line[0] == "LV" and line[1] == "NAME":
                continue
            else:
                lv, lvtype, num_lp, num_pp, num_pv, act_state, mountpoint_raw = line
                activation, mirror = act_state.split("/")
                mountpoint = None if mountpoint_raw == "N/A" else mountpoint_raw
                lvmconf[vgname].update(
                    {
                        lv: (
                            lvtype,
                            int(num_lp),
                            int(num_pp),
                            int(num_pv),
                            activation,
                            mirror,
                            mountpoint,
                        )
                    }
                )
        return lvmconf

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["lsrep"], mutates=False)
        lines = res.stdout.splitlines()
        # Try alternative command if lsrep fails (common fallback)
        if res.rc != 0:
            res = ctx.run(["lsvg", "-l", "rootvg"], mutates=False)
            lines = res.stdout.splitlines()
        
        # Parse according to AIX lvm output format
        section = parse_aix_lvm([l.strip().split() for l in lines if l.strip()])
        
        items = []
        for vg, volumes in section.items():
            for lv in volumes:
                item = vg + "/" + lv
                items.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d logical volumes" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["lsrep"], mutates=False)
    lines = res.stdout.splitlines()
    if res.rc != 0:
        res = ctx.run(["lsvg", "-l", "rootvg"], mutates=False)
        lines = res.stdout.splitlines()
    
    section = parse_aix_lvm([l.strip().split() for l in lines if l.strip()])
    
    # Extract target vg and lv from item
    parts = item.split("/")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    target_vg, target_lv = parts
    
    if target_vg in section and target_lv in section[target_vg]:
        state = 0
        msgtxt = []
        
        lvtype, num_lp, num_pp, num_pv, activation, mirror, _mountpoint = section[target_vg][target_lv]
        
        # Test if the volume is mirrored.
        # Yes? Test for an even distribution of PP's over volumes.
        if int(num_pp / num_lp) > 1:
            if int(num_pp / num_pv) != num_lp:
                msgtxt.append("LV Mirrors are misaligned between physical volumes(!)")
                state = max(state, 1)
        
        # If it's not the boot volume I suspect it should be open.
        if lvtype != "boot":
            if activation != "open":
                msgtxt.append("LV is not opened(!)")
                state = max(state, 1)
        
        # Detect any volumes that have stale PPs.
        if mirror != "syncd":
            msgtxt.append("LV is not in sync state(!!)")
            state = max(state, 2)
        
        if state == 0:
            msgtxt_str = "LV is open/syncd"
        else:
            msgtxt_str = ", ".join(msgtxt)
        
        return {"changed": False, "msg": msgtxt_str,
                "data": {"state": "CRIT" if state == 2 else ("WARN" if state == 1 else "OK"),
                         "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": "no such volume found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
