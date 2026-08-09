# diskstat_io_volumes — translated Checkmk check (read-only Starlark)
# Monitors HP MSA storage-array volume IO throughput via the on-host
# HP MSA special-agent JSON. There is no Checkmk nor an on-host array
# here; the data is gathered from the configured MSA controller.

HP_MSA_DEFAULT_PARAMS = {
    "read_throughput": (0, 0),
    "write_throughput": (0, 0),
}

def _msa_get(ctx, host, community):
    # Probe the device itself: reach the configured HP MSA controller.
    # rc == 127 / empty output -> not installed/present.
    res = ctx.run(
        ["hp_msa_agent", "--json", "-H", host, "-c", community],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        out = _msa_get(ctx, host, community)
        if out == None:
            return {"changed": False, "msg": "HP MSA not reachable",
                    "data": {"discovery": []}}
        data = json.decode(out)
        volumes = data.get("volumes", {})
        if len(volumes) == 0:
            return {"changed": False, "msg": "no MSA volumes found",
                    "data": {"discovery": []}}
        discovery = []
        for name in volumes.keys():
            discovery.append({
                "item": name,
                "params": {"levels": (0, 0)},
                "metrics": ["read_throughput", "write_throughput"],
            })
        return {"changed": False,
                "msg": "discovered %d MSA volumes" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    out = _msa_get(ctx, host, community)
    if out == None:
        return {"changed": False, "msg": "HP MSA not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(out)
    volumes = data.get("volumes", {})

    if item == "":
        # single-service summary not applicable for MSA volumes
        return {"changed": False, "msg": "no MSA volume selected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vol = volumes.get(item)
    if vol == None:
        return {"changed": False,
                "msg": "MSA volume %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    read_thr = vol.get("data-read-numeric", 0)
    write_thr = vol.get("data-written-numeric", 0)

    levels = params.get("levels", (0, 0))
    warn = levels[0]
    crit = levels[1]

    def _grade(value, warn, crit):
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"

    # Use the larger of the two directions for threshold grading, as the
    # source check applies a single levels pair to the summarized metric.
    max_val = read_thr
    if write_thr > max_val:
        max_val = write_thr
    state = _grade(max_val, warn, crit)

    summary = "read %f B/s, write %f B/s" % (read_thr, write_thr)
    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"read_throughput": read_thr,
                                 "write_throughput": write_thr},
                     "details": ""}}