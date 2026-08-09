def _split_line(line):
    """Split an lsvg/LVM agent line into fields, robust to double spaces."""
    return line.split()


def _parse_lvmconf(raw):
    """Parse `lsvg -p <vg>` style lines into {vg: {lv: tuple}}.

    We re-query the real AIX source via `lsvg -p` for each VG discovered,
    producing the same tuple layout the Checkmk agent plugin parses:
    (lvtype, num_lp, int, int, int, activation, mirror, mountpoint_or_None).
    """
    section = {}
    vgname = None
    for line in raw.splitlines():
        f = _split_line(line)
        if len(f) == 1 and f[0].endswith(":"):
            vgname = f[0][:-1]
            section[vgname] = {}
            continue
        if len(f) >= 7 and f[0] == "LV" and f[1] == "NAME":
            continue
        if vgname == None or len(f) < 7:
            continue
        lv = f[0]
        lvtype = f[1]
        num_lp = int(f[2])
        num_pp = int(f[3])
        num_pv = int(f[4])
        act_state = f[5]
        mountpoint_raw = f[6]
        parts = act_state.split("/")
        activation = parts[0]
        mirror = parts[1] if len(parts) > 1 else ""
        mountpoint = None if mountpoint_raw == "N/A" else mountpoint_raw
        section[vgname][lv] = (lvtype, num_lp, num_pp, num_pv, activation, mirror, mountpoint)
    return section


def main(ctx, params):
    # Probe for the real AIX LVM source: the `lsvg` binary.
    probe = ctx.run(["lsvg", "-o"], mutates=False)
    if probe.rc == 127:
        # AIX LVM tooling not present on this host.
        if params.get("_discover"):
            return {"changed": False, "msg": "lsvg not found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "no AIX LVM found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "lsvg not installed"},
        }

    # Discovery: enumerate VG/LV pairs from the on-host source.
    if params.get("_discover"):
        out = []
        # `lsvg -o` lists online volume groups, one per line.
        if probe.rc == 0:
            for vg in probe.stdout.splitlines():
                vg = vg.strip()
                if not vg:
                    continue
                # Re-query the real source for this VG's logical volumes.
                lvres = ctx.run(["lsvg", "-l", vg], mutates=False)
                if lvres.rc != 0:
                    continue
                section = _parse_lvmconf(lvres.stdout)
                for lv in section.get(vg, {}):
                    out.append({
                        "item": vg + "/" + lv,
                        "params": {},
                        "metrics": [],
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    # Check mode: grade one item.
    item = params.get("item", "")
    if "/" not in item:
        if item == "":
            return {
                "changed": False,
                "msg": "no such volume found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        parts = [item]
    else:
        parts = item.split("/")

    target_vg = parts[0]
    target_lv = parts[1]

    # Gather the VG's real LV data from the on-host source.
    lvres = ctx.run(["lsvg", "-l", target_vg], mutates=False)
    if lvres.rc != 0:
        return {
            "changed": False,
            "msg": "no such volume group: " + target_vg,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _parse_lvmconf(lvres.stdout)

    if target_vg in section and target_lv in section[target_vg]:
        msgtxt = []
        state = 0
        lvtype, num_lp, num_pp, num_pv, activation, mirror, _mountpoint = section[target_vg][target_lv]

        # Test if the volume is mirrored; if so, check even PP distribution.
        if num_lp > 0:
            if int(num_pp / num_lp) > 1:
                if num_pv > 0 and not (int(num_pp / num_pv) == num_lp):
                    msgtxt.append("LV Mirrors are misaligned between physical volumes(!)")
                    state = max(state, 1)

        # Non-boot volumes should be open.
        if lvtype != "boot":
            if activation != "open":
                msgtxt.append("LV is not opened(!)")
                state = max(state, 1)

        # Stale PPs (not in sync).
        if mirror != "syncd":
            msgtxt.append("LV is not in sync state(!!)")
            state = max(state, 2)

        if state == 0:
            msgtxt_str = "LV is open/syncd"
        else:
            msgtxt_str = ", ".join(msgtxt)

        st_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "CRIT"}
        return {
            "changed": False,
            "msg": msgtxt_str,
            "data": {"state": st_map.get(state, "UNKNOWN"), "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "no such volume found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }