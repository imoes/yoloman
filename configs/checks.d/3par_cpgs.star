
def main(ctx, params):
    if params.get("_discover"):
        # Discovery: fetch CPGs and emit services for each CPG and its usage types
        res = ctx.run(["curl", "-s", "-k", "-H", "Authorization: Basic %s" % params.get("credentials", ""),
                       "https://%s/api/v1/storageSystem" % params.get("host", "localhost")], mutates=False)
        if res.rc != 0:
            fail("failed to fetch CPG data: " + res.stderr)
        data = json.decode(res.stdout)
        cpgs = data.get("members", [])
        discovery = []
        for cpg in cpgs:
            name = cpg.get("name", "")
            if not name:
                continue
            num_vvs = (cpg.get("numFPVVs", 0) + cpg.get("numTDVVs", 0) + cpg.get("numTPVVs", 0))
            if num_vvs > 0:
                # CPG state check service
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
                # CPG usage services
                for fs in ["SAUsage", "SDUsage", "UsrUsage"]:
                    discovery.append({
                        "item": name + " " + fs,
                        "params": params.get("levels", (80.0, 90.0)),
                        "metrics": ["used_percent"]
                    })
        return {"changed": False, "msg": "discovered %d CPGs" % len([d for d in discovery if " " not in d["item"]]),
                "data": {"discovery": discovery}}

    # Check mode: parse item, extract data, compute state
    item = params.get("item", "")
    # Determine whether this is a CPG state check or a usage check
    if item.endswith(" SAUsage") or item.endswith(" SDUsage") or item.endswith(" UsrUsage"):
        # Usage check
        parts = item.rsplit(" ", 1)
        if len(parts) != 2:
            return {"changed": False, "msg": "invalid item format",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        cpg_name = parts[0]
        usage_type = parts[1]
        res = ctx.run(["curl", "-s", "-k", "-H", "Authorization: Basic %s" % params.get("credentials", ""),
                       "https://%s/api/v1/storageSystem" % params.get("host", "localhost")], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch CPG data: " + res.stderr,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        data = json.decode(res.stdout)
        cpg = None
        for c in data.get("members", []):
            if c.get("name") == cpg_name:
                cpg = c
                break
        if cpg == None:
            return {"changed": False, "msg": "CPG not found: " + cpg_name,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        usage = cpg.get(usage_type, {})
        total_mib = usage.get("totalMiB", 0.0)
        used_mib = usage.get("usedMiB", 0.0)
        free_mib = total_mib - used_mib
        warn, crit = params.get("levels", (80.0, 90.0))
        if total_mib <= 0:
            return {"changed": False, "msg": "total size is zero",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        used_pct = (used_mib / total_mib) * 100.0
        state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")
        return {"changed": False, "msg": "Size: %f MiB, Used: %f MiB (%f%%)" % (total_mib, used_mib, used_pct),
                "data": {"state": state, "metrics": {"used_percent": used_pct}, "details": ""}}
    else:
        # CPG state check
        res = ctx.run(["curl", "-s", "-k", "-H", "Authorization: Basic %s" % params.get("credentials", ""),
                       "https://%s/api/v1/storageSystem" % params.get("host", "localhost")], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch CPG data: " + res.stderr,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        data = json.decode(res.stdout)
        cpg = None
        for c in data.get("members", []):
            if c.get("name") == item:
                cpg = c
                break
        if cpg == None:
            return {"changed": False, "msg": "CPG not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state_code = cpg.get("state", 1)
        state_map = {1: ("OK", "Normal"), 2: ("WARN", "Degraded"), 3: ("CRIT", "Failed")}
        state_label, state_text = state_map.get(state_code, ("UNKNOWN", "Unknown"))
        num_vvs = cpg.get("numFPVVs", 0) + cpg.get("numTDVVs", 0) + cpg.get("numTPVVs", 0)
        return {"changed": False, "msg": "%s, %d VVs" % (state_text, num_vvs),
                "data": {"state": state_label, "metrics": {}, "details": ""}}