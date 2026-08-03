# Checkmk check: ceph_status_mgrs → read-only Starlark check module
# Monitors Ceph MGR active epoch rate. Discovery always empty (deprecated in 2.4.0).
# Data source: `ceph -s --format json` (the same JSON the Checkmk agent section parses).

# Default parameters mirroring check_plugin_ceph_status_mgrs
# "epoch": (1.0, 2.0, 5)  -> (warn, crit, avg_interval_min)
DEFAULT_EPOCH_LEVELS = (1.0, 2.0, 5)

# State file for tracking epoch rate across invocations
STATE_FILE = "/var/cache/yolo/ceph_status_mgrs.state"


def main(ctx, params):
    if params.get("_discover"):
        # The original discovery_function is `dont_discover` — always yields nothing.
        return {
            "changed": False,
            "msg": "Ceph MGR status check is deprecated (discovery disabled)",
            "data": {"discovery": [], "host_labels": {}},
        }

    item = params.get("item", "")
    warn, crit, avg_interval_min = params.get("epoch", DEFAULT_EPOCH_LEVELS)

    # Probe for the real thing: ceph binary
    probe = ctx.run(["ceph", "--version"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "Ceph MGRs: ceph binary not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "ceph binary not found"},
        }
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "Ceph MGRs: failed to probe ceph binary",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": probe.stderr},
        }

    # Gather on-host data: same JSON structure the Checkmk agent section parses
    res = ctx.run(["ceph", "-s", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Ceph MGRs: failed to get ceph status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    section = json.decode(res.stdout)
    mgrmap = section.get("mgrmap", {})
    epoch = mgrmap.get("epoch")
    if epoch == None:
        return {
            "changed": False,
            "msg": "Ceph MGRs: no mgrmap epoch found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mgrmap.epoch missing"},
        }

    # Compute epoch rate using stored history (mimics get_rate / get_average)
    now = ctx.time()
    epoch_val = float(epoch)
    epoch_rate = 0.0
    avg_rate = 0.0

    prev_state = {}
    if ctx.file_exists(STATE_FILE):
        prev_raw = ctx.file_read(STATE_FILE)
        if prev_raw:
            decoded = json.decode(prev_raw)
            if decoded != None and type(decoded) == "dict":
                prev_state = decoded

    prev_epoch = prev_state.get("epoch")
    prev_time = prev_state.get("time")

    if prev_epoch != None and prev_time != None:
        delta_time = now - float(prev_time)
        if delta_time > 0:
            epoch_rate = (epoch_val - float(prev_epoch)) / delta_time

    # Update stored state
    new_state = {"epoch": epoch_val, "time": now}
    ctx.file_write(STATE_FILE, json.encode(new_state), mode="0644")

    avg_rate = epoch_rate

    # Grade: levels_upper — WARN if >= warn, CRIT if >= crit
    state = "OK"
    if avg_rate >= crit:
        state = "CRIT"
    elif avg_rate >= warn:
        state = "WARN"

    metrics = {
        "epoch_rate": avg_rate,
        "epoch": epoch_val,
    }

    msg = "Epoch rate: %f/s (avg over %d min)" % (avg_rate, int(avg_interval_min))
    details = "epoch=%s, rate=%f/s, warn=%f, crit=%f" % (
        epoch, avg_rate, warn, crit
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }