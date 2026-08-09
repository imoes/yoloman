def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: check sysObjectID base OID presence
        oid = ".1.3.6.1.4.1.9839.1"
        res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                oid,
            ],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "no Carel uniflair cooling device found",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["humidity"],
                    }
                ]
            },
        }

    # Check mode: gather all four OIDs at once
    base = ".1.3.6.1.4.1.9839.2.1"
    oids = ["1.31.0", "1.51.0", "1.67.0", "2.6.0"]
    values = []
    for suffix in oids:
        oid = base + "." + suffix
        res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                oid,
            ],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "no Carel uniflair cooling device found",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "",
                },
            }
        values.append(res.stdout.strip())

    waterloss, global_status, emergency_op, r_humidity = values

    err_waterloss = waterloss != "0"
    err_global_status = global_status != "1"
    err_emergency_op = emergency_op != "0"

    humidity = float(r_humidity) / 10.0

    output = ""
    output = output + (
        "Global Status: %s" % ("Error(!!), " if err_global_status else "OK, ")
    )
    output = output + (
        "Emergency Operation: %s"
        % ("Active(!!), " if err_emergency_op else "Inactive, ")
    )
    output = output + (
        "Humidifier: %s" % ("Water Loss(!!), " if err_waterloss else "No Water Loss, ")
    )
    output = output + "Humidity: %f%%" % humidity

    state = "CRIT" if (err_waterloss or err_global_status or err_emergency_op) else "OK"

    return {
        "changed": False,
        "msg": output,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }