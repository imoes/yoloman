# Checkmk check: checkmk.lsi_array — RAID array status (read-only Starlark translation)
# Reproduces the agent_based/lsi.py parse + discover + check logic using the
# on-host MegaCLI /storcli source that the Checkmk agent plugin reads.

def _parse_storcli(output):
    """Parse `storcli /c0 /v show` or `MegaCli -LDInfo -Lall -aALL` text into
    {arrays: {vol_id: status}, disks: {target_id: state}} mirroring parse_lsi."""
    arrays = {}
    disks = {}
    lines = output.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        low = line.lower()
        # Virtual Drive block: "Virtual Drive: 2 (Target Id: 1)"
        if "virtual drive" in low or "target id" in low:
            vol_id = ""
            target_id = ""
            # try to grab ids from this line
            parts = line.split()
            for p in parts:
                if p.isdigit():
                    vol_id = p
                    break
            # capture State line for this virtual drive
            j = i
            depth = 0
            state_val = ""
            while j < n and depth < 12:
                nl = lines[j].lower()
                if "state" in nl:
                    s = lines[j].split()
                    # find the value after "State :" 
                    idx = -1
                    for k in range(len(s)):
                        if s[k].lower() == "state" and k + 1 < len(s):
                            idx = k + 1
                            break
                    if idx >= 0:
                        state_val = s[idx]
                if vol_id != "" and state_val != "":
                    break
                j += 1
            if vol_id != "":
                arrays[vol_id] = state_val
        # Physical disk / Drive block: "Drive: 1" + "State: Onln"
        if low.startswith("drive") or "drive state" in low or "media type" in low:
            target_id = ""
            parts = line.split()
            for p in parts:
                if p.isdigit():
                    target_id = p
                    break
            j = i
            state_val = ""
            while j < n and (j - i) < 8:
                nl = lines[j].lower()
                if "state" in nl:
                    s = lines[j].split()
                    idx = -1
                    for k in range(len(s)):
                        if s[k].lower() == "state" and k + 1 < len(s):
                            idx = k + 1
                            break
                    if idx >= 0:
                        state_val = s[idx]
                if target_id != "" and state_val != "":
                    break
                j += 1
            if target_id != "":
                disks[target_id] = state_val
        i += 1
    return {"arrays": arrays, "disks": disks}


def _lsi_available(ctx):
    """Probe for the real source tool: MegaCli or storcli."""
    for tool in (["MegaCli", "-v"], ["storcli", "show"]):
        res = ctx.run(tool, mutates=False)
        if res.rc == 127:
            continue
        # rc 0 or any non-127 means the binary is present
        rc = res.rc
        if rc != 127:
            return tool[0]
    return None


def _run_storcli(ctx, tool):
    """Run the equivalent of the Checkmk lsi agent section."""
    # MegaCli: adapter 0, all virtual drives
    if tool == "MegaCli":
        res = ctx.run(["MegaCli", "-LDInfo", "-Lall", "-aALL"], mutates=False)
    else:
        res = ctx.run(["storcli", "/c0", "/v", "show"], mutates=False)
    return res


def main(ctx, params):
    # ---- DISCOVERY ----
    if params.get("_discover"):
        tool = _lsi_available(ctx)
        if tool == None:
            # Not present -> empty discovery, never a placeholder
            return {"changed": False, "msg": "no LSI/MegaRAID controller found",
                    "data": {"discovery": []}}
        res = _run_storcli(ctx, tool)
        if res.rc != 0 and res.stdout == "":
            return {"changed": False, "msg": "no LSI/MegaRAID controller found",
                    "data": {"discovery": []}}
        section = _parse_storcli(res.stdout)
        out = []
        for vol_id in section["arrays"].keys():
            out.append({"item": vol_id, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d RAID arrays" % len(out),
                "data": {"discovery": out}}

    # ---- CHECK (single item) ----
    item = params.get("item", "")
    tool = _lsi_available(ctx)
    if tool == None:
        return {"changed": False,
                "msg": "no LSI/MegaRAID controller found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = _run_storcli(ctx, tool)
    if res.rc != 0 and res.stdout == "":
        return {"changed": False,
                "msg": "no LSI/MegaRAID controller found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_storcli(res.stdout)
    arrays = section["arrays"]
    state_val = arrays.get(item)
    if state_val == None:
        return {"changed": False,
                "msg": "RAID volume %s not existing" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": "RAID volume %s not existing" % item}}
    # Replicate check_lsi_array: OK if 'Okay(OKY)' else CRIT
    if state_val == "Okay(OKY)":
        verdict = "OK"
    else:
        verdict = "CRIT"
    summary = "Status is '%s'" % state_val
    return {"changed": False,
            "msg": summary,
            "data": {"state": verdict, "metrics": {}, "details": summary}}