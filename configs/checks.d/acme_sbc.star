def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []},
                ]
            },
        }

    res = ctx.run(["show", "health"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve health information",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    states = {}
    settings = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) == 2:
            for what in ["Health", "State"]:
                if parts[0] == what:
                    states[what] = parts[1]
        elif len(parts) == 3 and parts[1] == "Synchronized":
            settings[parts[0]] = parts[2]

    health = states.get("Health", "0")
    state_val = states.get("State", "Unknown")

    health_num = int(health)

    if health_num == 100:
        state = "OK"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "Health at %d %% (State: %s)" % (health_num, state_val),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
