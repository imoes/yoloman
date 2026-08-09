def main(ctx, params):
    discover = params.get("_discover")
    if discover:
        return _do_discovery(ctx, params)
    return _do_check(ctx, params)

def _asm_data(ctx):
    probe = ctx.run(["asmcmd", "lsdg"], mutates=False)
    if probe.rc == 127:
        return {"diskgroups": {}, "found_deprecated": False, "absent": True}
    if probe.rc != 0:
        return {"diskgroups": {}, "found_deprecated": False, "absent": False}
    return _parse_lsdg(probe.stdout)

def _parse_lsdg(stdout):
    diskgroups = {}
    found_deprecated = False
    lines = stdout.splitlines()
    for idx in range(len(lines)):
        line = lines[idx]
        if line.startswith("State") and "Name" in line:
            continue
        parts = line.split()
        n_parts = len(parts)
        if n_parts == 0:
            continue
        dgstate = parts[0]
        if dgstate == "DISMOUNTED":
            dgtype = None
            index = 1
            if n_parts == 14:
                index = 2
        elif dgstate == "MOUNTED":
            dgtype = parts[1] if n_parts > 1 else None
            index = 2
        else:
            continue
        stripped = parts[index:]
        n = len(stripped)
        if n == 10 or n == 11:
            total_mb = stripped[4]
            free_mb = stripped[5]
            req_mir_free_mb = stripped[6]
            offline_disks = stripped[8]
            dgname = stripped[9]
            voting_files = "N" if n == 10 else stripped[9]
            dgname = dgname.rstrip("/")
            diskgroups.setdefault(dgname, {
                "dgstate": dgstate,
                "dgtype": dgtype,
                "total_mb": _try_int(total_mb),
                "free_mb": _try_int(free_mb),
                "req_mir_free_mb": _try_int(req_mir_free_mb),
                "offline_disks": _try_int(offline_disks),
                "voting_files": voting_files,
                "fail_groups": [],
            })
        elif n == 12:
            # new format with failgroup details
            # state type dgname block au req_mir_free_mb total_mb free_mb fg_name voting_files fg_type offline_disks fg_min_repair_time fg_disks
            dgname = stripped[0]
            # re-map fields to match new format ordering
            _block = stripped[1]
            _au = stripped[2]
            req_mir_free_mb = stripped[3]
            total_mb = stripped[4]
            free_mb = stripped[5]
            fg_name = stripped[6]
            voting_files = stripped[7]
            fg_type = stripped[8]
            offline_disks = stripped[9]
            fg_min_repair_time = stripped[10]
            fg_disks = stripped[11]
            if _is_deprecated(fg_min_repair_time, fg_disks):
                found_deprecated = True
                continue
            dgname_clean = dgname.rstrip("/")
            fg = {
                "fg_name": fg_name,
                "fg_voting_files": voting_files,
                "fg_type": fg_type,
                "fg_free_mb": _try_int(free_mb),
                "fg_total_mb": _try_int(total_mb),
                "fg_disks": _try_int(fg_disks),
                "fg_min_repair_time": _try_int(fg_min_repair_time),
            }
            if dgname_clean in diskgroups:
                diskgroups[dgname_clean]["fail_groups"].append(fg)
            else:
                diskgroups.setdefault(dgname_clean, {
                    "dgstate": dgstate,
                    "dgtype": dgtype,
                    "total_mb": _try_int(total_mb),
                    "free_mb": _try_int(free_mb),
                    "req_mir_free_mb": _try_int(req_mir_free_mb),
                    "offline_disks": _try_int(offline_disks),
                    "voting_files": voting_files,
                    "fail_groups": [fg],
                })
    return {"diskgroups": diskgroups, "found_deprecated": found_deprecated, "absent": False}

def _try_int(v):
    if v == None:
        return None
    s = str(v).strip()
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    if s.isdigit():
        val = 0
        for ch in s:
            val = val * 10 + (ord(ch) - 48)
        return val if not neg else -val
    return None

def _is_deprecated(repair_time, num_disks):
    if num_disks == None or repair_time == None:
        return False
    nd = str(num_disks)
    rt = str(repair_time)
    if not nd.isdigit():
        return True
    if rt == "N":
        return True
    return False

def _do_discovery(ctx, params):
    data = _asm_data(ctx)
    if data["absent"]:
        return {"changed": False, "msg": "oracle asmcmd not installed",
                "data": {"discovery": []}}
    out = []
    for name in sorted(data["diskgroups"].keys()):
        dg = data["diskgroups"][name]
        if dg["dgstate"] in ["MOUNTED", "DISMOUNTED"]:
            out.append({"item": name, "params": {"req_mir_free": False},
                        "metrics": ["used_percent"]})
    return {"changed": False, "msg": "discovered %d asm diskgroups" % len(out),
            "data": {"discovery": out}}

def _do_check(ctx, params):
    item = params.get("item", "")
    data = _asm_data(ctx)
    if data["absent"]:
        return {"changed": False, "msg": "oracle asmcmd not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dgs = data["diskgroups"]
    if item not in dgs:
        return {"changed": False, "msg": "diskgroup %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dg = dgs[item]
    if dg["dgstate"] == "DISMOUNTED":
        return {"changed": False, "msg": "Diskgroup %s dismounted" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    dgtype = dg["dgtype"]
    total_mb = 0
    free_mb = 0
    req_mir_free_mb = dg.get("req_mir_free_mb", 0)
    if req_mir_free_mb == None:
        req_mir_free_mb = 0
    offline_disks = dg.get("offline_disks", 0)
    if offline_disks == None:
        offline_disks = 0
    voting_files = dg.get("voting_files", "N")
    fail_groups = dg.get("fail_groups", [])
    if fail_groups == None:
        fail_groups = []
    add_text = ""
    dg_sizefactor = 0
    dg_disks = 0
    dg_votecount = 0
    dg_min_repair = 100 * 24 * 60 * 60
    fg_uniform_size = True
    last_total = -1
    if len(fail_groups) > 0:
        if dgtype == "EXTERN":
            dg_sizefactor = 1
        elif dgtype == "NORMAL":
            dg_sizefactor = 1 if len(fail_groups) == 1 else 2
        elif dgtype == "HIGH":
            dg_sizefactor = len(fail_groups) if len(fail_groups) <= 3 else 3
        elif dgtype == "FLEX":
            dg_sizefactor = 1
        else:
            dg_sizefactor = 2
        for fg in fail_groups:
            fd = fg.get("fg_disks", 0)
            if fd == None:
                fd = 0
            dg_disks += fd
            if fg.get("fg_voting_files") == "Y":
                dg_votecount += 1
            mt = fg.get("fg_min_repair_time", 0)
            if mt == None:
                mt = 0
            dg_min_repair = min(dg_min_repair, mt)
            ff = fg.get("fg_free_mb", 0)
            if ff == None:
                ff = 0
            free_mb += ff
            tf = fg.get("fg_total_mb", 0)
            if tf == None:
                tf = 0
            total_mb += tf
            lt = tf
            if last_total == -1:
                last_total = lt
            elif fg.get("fg_type") == "REGULAR" and fg.get("fg_voting_files") == "N":
                if lt * 95 < last_total * 100 or last_total * 100 > lt * 105:
                    pass
                if lt < last_total * 95 / 100 or lt > last_total * 105 / 100:
                    fg_uniform_size = False
    else:
        dgt = dg.get("total_mb")
        dgf = dg.get("free_mb")
        if not (dgt and dgf):
            return {"changed": False, "msg": "expected total/free mb but got none",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        total_mb = dgt
        free_mb = dgf
        if dgtype == "EXTERN":
            dg_sizefactor = 1
        elif dgtype == "NORMAL":
            if voting_files == "Y":
                dg_sizefactor = 3
            else:
                dg_sizefactor = 2
            add_text = ", old plug-in data, possible wrong used and free space"
        elif dgtype == "HIGH":
            if voting_files == "Y":
                dg_sizefactor = 5
            else:
                dg_sizefactor = 3
            add_text = ", old plug-in data, possible wrong used and free space"
        else:
            dg_sizefactor = 2
    if dg_sizefactor == 0:
        dg_sizefactor = 2
    total_mb = total_mb // dg_sizefactor
    free_space_mb = free_mb // dg_sizefactor
    if params.get("req_mir_free"):
        req_mir_free_mb = max(req_mir_free_mb, 0)
        add_text = ", required mirror free space used"
    warn = params.get("warn", 90)
    crit = params.get("crit", 95)
    used_pct = 0
    used_mb = 0
    if total_mb > 0:
        used_mb = total_mb - free_space_mb
        used_pct = int((used_mb * 100 + 0.5) / 1) // total_mb if total_mb > 0 else 0
        # compute pct with rounding: used_mb*100/total_mb
        raw = used_mb * 100.0 / total_mb
        used_pct = int(raw + 0.5)
    if used_pct >= crit:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"
    else:
        state = "OK"
    if offline_disks > 0:
        state = "CRIT"
    if data.get("found_deprecated"):
        if state == "OK":
            state = "WARN"
    infotext = ""
    if dgtype != None:
        infotext += "%s redundancy" % dgtype.lower()
        if len(fail_groups) > 0:
            infotext += ", %i disks" % dg_disks
            if dgtype != "EXTERN":
                infotext += " in %i failgroups" % len(fail_groups)
            if not fg_uniform_size:
                infotext += ", failgroups with unequal size"
            if dg_votecount > 0:
                votemarker = ""
                if dgtype == "HIGH" and dg_votecount < 5:
                    votemarker = ", not enough votings, 5 expected (!)"
                    if state == "OK":
                        state = "WARN"
                elif (dgtype == "NORMAL" and dg_votecount < 3) or (dgtype == "HIGH" and dg_votecount < 4):
                    state = "CRIT"
                    votemarker = ", not enough votings, 3 expected (!!)"
                infotext += ", %i votings" % dg_votecount
                infotext += votemarker
            if dg_min_repair < 8640000:
                infotext += ", disk repair timer for offline disks at %s (!)" % _render_timespan(dg_min_repair)
    infotext += add_text
    if offline_disks > 0:
        infotext += ", %d Offline disks found(!!)" % offline_disks
    details = "total_mb=%d free_mb=%d required_mirror_free=%d offline_disks=%d" % (total_mb, free_space_mb, req_mir_free_mb, offline_disks)
    if data.get("found_deprecated"):
        msg = "The deprecated Oracle Agent plug-in 'mk_oracle_asm' from Checkmk Version 1.2.6 is still executed on this host."
    else:
        msg = "%s: %s %d%% used (%s of %s MB free)" % (item, dgtype or "unknown", used_pct, str(free_space_mb), str(total_mb)) + infotext
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_pct, "used_mb": used_mb, "free_mb": free_space_mb, "total_mb": total_mb, "offline_disks": offline_disks},
                     "details": details}}

def _render_timespan(seconds):
    if seconds == None or seconds < 0:
        return "0s"
    days = seconds // 86400
    h = (seconds % 86400) // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if days > 0:
        return "%dd %dh %dm" % (days, h, m)
    if h > 0:
        return "%dh %dm" % (h, m)
    if m > 0:
        return "%dm %ds" % (m, s)
    return "%ds" % s