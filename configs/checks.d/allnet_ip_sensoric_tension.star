def _safe_float(s):
    return float(s) if s.replace(".", "", 1).replace("-", "", 1).isdigit() else None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c",
                       params.get("community", "public"), "-Oqn",
                       params.get("host", "localhost"),
                       ".1.3.6.1.4.1.18900.1.2.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no allnet sensor data",
                    "data": {"discovery": []}}
        section = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            oid = f[0]
            val = "".join(f[1:])
            idx = oid.rsplit(".", 1)[-1]
            key = "sensor" + idx
            section.setdefault(key, {})["value_float"] = val
        out = []
        for sensor, sensor_data in section.items():
            func = sensor_data.get("function", "")
            unit = sensor_data.get("unit", "")
            if func == "12" or unit == "V":
                num = sensor.replace("sensor", "")
                nm = sensor_data.get("name", "")
                if nm != "":
                    item = "%s Sensor %s" % (nm, num)
                else:
                    item = "Sensor %s" % num
                out.append({"item": item, "params": {},
                            "metrics": ["tension"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    num = item.rsplit("Sensor ", 1)[-1] if "Sensor " in item else item
    sensor_id = "sensor" + num
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.18900.1.2.1"
    val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                       host, base + ".3." + num], mutates=False)
    if val_res.rc != 0:
        return {"changed": False,
                "msg": "no tension data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}
    value = _safe_float(val_res.stdout)
    if value == None:
        return {"changed": False,
                "msg": "bad value for " + item,
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}
    state = "OK" if value == 0 else "CRIT"
    summary = "%f%% of the normal level" % value
    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"tension": value},
                     "details": ""}}