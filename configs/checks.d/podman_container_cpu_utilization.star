# Checkmk check: podman_container_cpu_utilization — CPU utilization of podman containers.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    # Probe for the real thing: podman binary must exist
    probe = ctx.run(["podman", "--version"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {"changed": False, "msg": "podman not found", "data": {"discovery": []}}

    # Gather all running container names via standard CLI
    res = ctx.run(
        ["podman", "ps", "--format", "{{.Names}}"],
        mutates=False,
    )
    if res.rc != 0 or res.rc == 127:
        return {"changed": False, "msg": "podman not available", "data": {"discovery": []}}

    containers = []
    for line in res.stdout.splitlines():
        name = line.strip()
        if name:
            containers.append(name)

    if not containers:
        # No running containers — discovery returns empty list
        return {"changed": False, "msg": "no running podman containers", "data": {"discovery": []}}

    # Single-service check per container; the source yields Service() (one item, "")
    # But we need per-container items to mirror the source's per-container intent
    discovery = []
    for c in containers:
        discovery.append({
            "item": c,
            "params": {
                "util": (70.0, 80.0),  # check_default_parameters
            },
            "metrics": ["cpu_util"],
        })

    return {
        "changed": False,
        "msg": "discovered %d podman container(s)" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    item = params.get("item", "")
    util_levels = params.get("util", (70.0, 80.0))

    # Probe podman binary
    probe = ctx.run(["podman", "--version"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {
            "changed": False,
            "msg": "podman not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Get CPU utilization for the specific container
    # Use --no-stream with format to get CPU % directly
    res = ctx.run(
        ["podman", "stats", "--no-stream", "--format", "{{.CPUPerc}}", item],
        mutates=False,
    )

    if res.rc != 0 or res.rc == 127:
        return {
            "changed": False,
            "msg": "no such podman container: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if not raw:
        return {
            "changed": False,
            "msg": "no data for container: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # podman stats CPUPerc outputs like "12.34%"
    cpu_str = raw.rstrip("%")
    # Guard against non-numeric
    cleaned = ""
    for ch in cpu_str:
        if ch.isdigit() or ch == "." or ch == "-":
            cleaned = cleaned + ch
    if cleaned == "" or cleaned == ".":
        return {
            "changed": False,
            "msg": "could not parse CPU utilization for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    util = float(cleaned)

    # Apply threshold logic: warn/crit from params
    warn = util_levels[0] if type(util_levels) == "list" or type(util_levels) == "tuple" else 70.0
    crit = util_levels[1] if type(util_levels) == "list" or type(util_levels) == "tuple" else 80.0

    state = "CRIT" if util >= crit else ("WARN" if util >= warn else "OK")

    # Also gather per-container stats for details (using --format json would be ideal,
    # but we keep it simple with text parsing of CPUPerc)
    return {
        "changed": False,
        "msg": "CPU utilization %f%% (%s)" % (util, item),
        "data": {
            "state": state,
            "metrics": {"cpu_util": util},
            "details": "Container %s CPU: %f%% (warn: %s%%, crit: %s%%)" % (item, util, str(warn), str(crit)),
        },
    }