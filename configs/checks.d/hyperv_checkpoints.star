def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["age", "age_oldest"]}]},
        }

    res = ctx.run(["cat", "/proc/driver/hyperv_checkpoints"], mutates=False)
    if res.rc != 0 or not res.stdout:
        res = ctx.run(["cat", "/sys/kernel/hyperv/checkpoints"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "HyperV checkpoints data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    snapshots = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            snapshots.append((parts[0], int(parts[1])))

    if not snapshots:
        return {
            "changed": False,
            "msg": "0 checkpoints",
            "data": {"state": "OK", "metrics": {"age": 0, "age_oldest": 0}, "details": ""},
        }

    last_snapshot = snapshots[-1]
    oldest_snapshot = max(snapshots, key=lambda x: x[1])

    age = last_snapshot[1]
    age_oldest = oldest_snapshot[1]

    state = "OK"
    details = ""

    if age < 0:
        state = "WARN"
        details = "Last (%s): negative checkpoint age (%ds), check for clock skew" % (last_snapshot[0], age)
    elif age_oldest < 0:
        state = "WARN"
        details = "Oldest (%s): negative checkpoint age (%ds), check for clock skew" % (oldest_snapshot[0], age_oldest)

    return {
        "changed": False,
        "msg": "%d checkpoints" % len(snapshots),
        "data": {
            "state": state,
            "metrics": {"age": age, "age_oldest": age_oldest},
            "details": details,
        },
    }