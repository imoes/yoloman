MTR_DEFAULT_PL = (10, 25)
MTR_DEFAULT_RTA = (150, 250)
MTR_DEFAULT_RTSTDDEV = (150, 250)

def _is_float(s):
    if not s:
        return False
    parts = s.split(".")
    if len(parts) == 1:
        return parts[0].lstrip("-").isdigit()
    if len(parts) == 2:
        intpart = parts[0].lstrip("-")
        fracpart = parts[1]
        if intpart == "" and fracpart == "":
            return False
        if not intpart.isdigit() and intpart != "":
            return False
        if not fracpart.isdigit():
            return False
        return True
    return False

def _grade_upper(value, warn, crit):
    if value == None:
        return "UNKNOWN"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _parse_section(res):
    section = []
    if not res.stdout:
        return section
    lines = res.stdout.splitlines()
    for line in lines:
        if not line or line.startswith("**ERROR**"):
            continue
        fields = line.split()
        if len(fields) < 3:
            continue
        hostname = fields[0]
        hopcount_str = fields[2]
        if not _is_float(hopcount_str):
            continue
        hopcount = int(float(hopcount_str))
        rest = fields[3:]
        hops = []
        for hopnum in range(hopcount):
            base = 8 * hopnum
            if base + 7 >= len(rest):
                break
            hname = rest[base]
            pl_str = rest[base + 1].replace("%", "").rstrip()
            pl = float(pl_str) if _is_float(pl_str) else 0.0
            rt = float(rest[base + 3]) / 1000 if _is_float(rest[base + 3]) else 0.0
            rta = float(rest[base + 4]) / 1000 if _is_float(rest[base + 4]) else 0.0
            rtmin = float(rest[base + 5]) / 1000 if _is_float(rest[base + 5]) else 0.0
            rtmax = float(rest[base + 6]) / 1000 if _is_float(rest[base + 6]) else 0.0
            rtstddev = float(rest[base + 7]) / 1000 if _is_float(rest[base + 7]) else 0.0
            hops.append({
                "name": hname,
                "pl": pl,
                "response_time": rt,
                "rta": rta,
                "rtmin": rtmin,
                "rtmax": rtmax,
                "rtstddev": rtstddev,
            })
        section.append({"hostname": hostname, "hops": hops})
    return section

def _run_probe(ctx):
    return ctx.run(["mtr", "-r", "-w"], mutates=False)

def main(ctx, params):
    if params.get("_discover"):
        res = _run_probe(ctx)
        if res.rc != 0:
            if res.rc == 127:
                return {"changed": False, "msg": "mtr not installed", "data": {"discovery": [], "host_labels": {}}}
            return {"changed": False, "msg": "mtr probe failed", "data": {"discovery": [], "host_labels": {}}}
        section = _parse_section(res)
        discovery = []
        host_labels = {}
        for entry in section:
            hostname = entry["hostname"]
            hops = entry["hops"]
            metric_names = []
            if len(hops) > 0:
                metric_names.append("hops")
                for i in range(1, len(hops)):
                    metric_names.append("hop_%d_rta" % i)
                    metric_names.append("hop_%d_rtmin" % i)
                    metric_names.append("hop_%d_rtmax" % i)
                    metric_names.append("hop_%d_rtstddev" % i)
                    metric_names.append("hop_%d_response_time" % i)
                    metric_names.append("hop_%d_pl" % i)
            discovery.append({
                "item": hostname,
                "params": {
                    "pl": MTR_DEFAULT_PL,
                    "rta": MTR_DEFAULT_RTA,
                    "rtstddev": MTR_DEFAULT_RTSTDDEV,
                },
                "metrics": metric_names,
            })
        return {"changed": False, "msg": "discovered %d hosts" % len(discovery), "data": {"discovery": discovery, "host_labels": host_labels}}
    
    item = params.get("item", "")
    res = _run_probe(ctx)
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "mtr not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "mtr probe failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(res)
    hops = None
    for entry in section:
        if entry["hostname"] == item:
            hops = entry["hops"]
            break
    if hops == None:
        return {"changed": False, "msg": "no mtr data for host " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not hops:
        return {"changed": False, "msg": "Insufficient data: No hop information available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    pl_level = params.get("pl", MTR_DEFAULT_PL)
    rta_level = params.get("rta", MTR_DEFAULT_RTA)
    rtstddev_level = params.get("rtstddev", MTR_DEFAULT_RTSTDDEV)
    
    metrics = {}
    metrics["hops"] = len(hops)
    for idx in range(1, len(hops)):
        hop = hops[idx - 1]
        metrics["hop_%d_rta" % idx] = hop["rta"]
        metrics["hop_%d_rtmin" % idx] = hop["rtmin"]
        metrics["hop_%d_rtmax" % idx] = hop["rtmax"]
        metrics["hop_%d_rtstddev" % idx] = hop["rtstddev"]
        metrics["hop_%d_response_time" % idx] = hop["response_time"]
        metrics["hop_%d_pl" % idx] = hop["pl"]
    
    last_hop = hops[-1]
    last_idx = len(hops)
    metrics["hop_%d_rta" % last_idx] = last_hop["rta"]
    metrics["hop_%d_rtmin" % last_idx] = last_hop["rtmin"]
    metrics["hop_%d_rtmax" % last_idx] = last_hop["rtmax"]
    metrics["hop_%d_rtstddev" % last_idx] = last_hop["rtstddev"]
    metrics["hop_%d_response_time" % last_idx] = last_hop["response_time"]
    metrics["hop_%d_pl" % last_idx] = last_hop["pl"]
    
    pl_state = _grade_upper(last_hop["pl"], pl_level[0], pl_level[1])
    rta_state = _grade_upper(last_hop["rta"], rta_level[0] / 1000, rta_level[1] / 1000)
    rtstddev_state = _grade_upper(last_hop["rtstddev"], rtstddev_level[0] / 1000, rtstddev_level[1] / 1000)
    
    states = [s for s in [pl_state, rta_state, rtstddev_state] if s != "OK" and s != "UNKNOWN"]
    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"
    
    details_lines = []
    for idx, hop in enumerate(hops):
        details_lines.append("Hop %d: %s" % (idx + 1, hop["name"]))
    details = "\n".join(details_lines)
    
    msg = "Number of Hops: %d" % len(hops)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}