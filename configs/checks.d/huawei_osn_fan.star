def main(ctx, params):
    if params.get("_discover"):
        oid_sys = ".1.3.6.1.2.1.1.2.0"
        res_detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                              "-Oqv", "-OQv", params.get("host", "localhost"), oid_sys],
                             mutates=False)
        if res_detect.rc != 0:
            return {"changed": False, "msg": "not a Huawei OSN device (sysObjectID not present)",
                    "data": {"discovery": []}}
        sysobj = res_detect.stdout.strip()
        if sysobj.find(".1.3.6.1.4.1.2011.2.25.1") == -1:
            return {"changed": False, "msg": "not a Huawei OSN device",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.2011.2.25.4.70.20.10.10.1"
        res_walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-Oqn", "-OQn", params.get("host", "localhost"), base + ".1"],
                           mutates=False)
        if res_walk.rc != 0:
            return {"changed": False, "msg": "walk of fan table failed",
                    "data": {"discovery": []}}

        items = []
        for line in res_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            full_oid = parts[0]
            idx = full_oid[len(base + ".1") + 1:]
            items.append({"item": idx, "params": {}, "metrics": ["fan_speed"]})

        return {"changed": False, "msg": "discovered %d fans" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.2011.2.25.4.70.20.10.10.1"
    oid_speed = base + ".2." + item
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-Oqv", "-OQv", params.get("host", "localhost"), oid_speed],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "fan " + item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    speed = res.stdout.strip()
    if len(speed) == 0:
        return {"changed": False, "msg": "fan " + item + " returned empty speed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, readable = _translate(speed)
    metrics = _speed_to_metric(speed)
    return {"changed": False,
            "msg": "Speed: " + readable,
            "data": {"state": state, "metrics": metrics, "details": ""}}


_FAN_STATES = {
    "0": ("WARN", "stop"),
    "1": ("OK", "low"),
    "2": ("OK", "mid-low"),
    "3": ("OK", "mid"),
    "4": ("OK", "mid-high"),
    "5": ("WARN", "high"),
}


def _translate(speed):
    if speed in _FAN_STATES:
        s, r = _FAN_STATES[speed]
        return (s, r)
    return ("UNKNOWN", "unknown (" + speed + ")")


def _speed_to_metric(speed):
    if speed.isdigit():
        v = int(speed)
        return {"fan_speed": v}
    return {"fan_speed": 0}