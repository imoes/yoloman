def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ceph", "health", "detail", "-f", "json"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "ceph not installed, no discovery",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "ceph health failed: " + res.stderr,
                    "data": {"discovery": []}}
        section = json.decode(res.stdout)
        if section == None:
            return {"changed": False, "msg": "no ceph data", "data": {"discovery": []}}
        osdmap = section.get("osdmap", {})
        data = osdmap.get("osdmap") or osdmap
        if data == None or data.get("num_osds") == None:
            return {"changed": False, "msg": "no osdmap in ceph status",
                    "data": {"discovery": []}}
        epoch_warn, epoch_crit, epoch_interval = params.get("epoch", (50.0, 100.0, 15))
        out_warn, out_crit = params.get("num_out_osds", (5.0, 7.0))
        down_warn, down_crit = params.get("num_down_osds", (5.0, 7.0))
        return {"changed": False, "msg": "discovered Ceph OSDs",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"epoch": (epoch_warn, epoch_crit, epoch_interval),
                                "num_out_osds": (out_warn, out_crit),
                                "num_down_osds": (down_warn, down_crit)},
                     "metrics": ["epoch_rate", "osds_out_percent", "osds_down_percent"]},
                ]}}
    item = params.get("item", "")
    res = ctx.run(["ceph", "health", "detail", "-f", "json"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "ceph binary not installed on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False,
                "msg": "ceph health detail failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "ceph returned empty output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = json.decode(res.stdout)
    osdmap = section.get("osdmap", {})
    data = osdmap.get("osdmap") or osdmap
    if data == None:
        return {"changed": False, "msg": "no osdmap found in ceph status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    num_osds = int(data["num_osds"])
    epoch = data["epoch"]
    metrics = {}
    worst = "OK"
    details_parts = []
    epoch_warn, epoch_crit, epoch_interval = params.get("epoch", (50.0, 100.0, 15))
    epoch_rate = _epoch_rate(epoch, epoch_interval, ctx)
    metrics["epoch_rate"] = epoch_rate
    if epoch_rate >= epoch_crit:
        worst = _worse(worst, "CRIT")
        details_parts.append("epoch rate %f >= %s" % (epoch_rate, epoch_crit))
    elif epoch_rate >= epoch_warn:
        worst = _worse(worst, "WARN")
        details_parts.append("epoch rate %f >= %s" % (epoch_rate, epoch_warn))

    for ds, title, state in [
        ("full", "Full", "CRIT"),
        ("nearfull", "Near full", "WARN"),
    ]:
        if data.get(ds, False):
            if _worse(worst, state) != worst:
                worst = _worse(worst, state)
                details_parts.append(title)

    out_str = "OSDs: %d, Remapped PGs: %d" % (num_osds, data["num_remapped_pgs"])
    out_warn, out_crit = params.get("num_out_osds", (5.0, 7.0))
    down_warn, down_crit = params.get("num_down_osds", (5.0, 7.0))
    num_out = num_osds - int(data["num_in_osds"])
    num_down = num_osds - int(data["num_up_osds"])
    if num_osds > 0:
        out_pct = 100.0 * float(num_out) / num_osds
        down_pct = 100.0 * float(num_down) / num_osds
    else:
        out_pct = 0.0
        down_pct = 0.0
    metrics["osds_out_percent"] = out_pct
    metrics["osds_down_percent"] = down_pct
    for value, warn, crit, label in [
        (out_pct, out_warn, out_crit, "OSDs out"),
        (down_pct, down_warn, down_crit, "OSDs down"),
    ]:
        if value >= crit:
            worst = _worse(worst, "CRIT")
            details_parts.append("%s %f%% >= %s" % (label, value, crit))
        elif value >= warn:
            worst = _worse(worst, "WARN")
            details_parts.append("%s %f%% >= %s" % (label, value, warn))

    msg = out_str
    if details_parts:
        msg = msg + "; " + ", ".join(details_parts)
    return {"changed": False, "msg": msg,
            "data": {"state": worst, "metrics": metrics, "details": "; ".join(details_parts)}}

def _worse(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return a if order[a] >= order[b] else b

def _epoch_rate(epoch, interval_min, ctx):
    res = ctx.run(["ceph", "health", "detail", "-f", "json"], mutates=False)
    if res.rc != 0:
        return 0.0
    section = json.decode(res.stdout)
    osdmap = section.get("osdmap", {})
    data = osdmap.get("osdmap") or osdmap
    if data == None:
        return 0.0
    return float(data["epoch"])