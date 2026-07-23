def main(ctx, params):
    # Discovery mode: emit one service with default thresholds
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "opttxTempValue": [60, 80],
                            "chassisTempValue": [60, 70],
                            "chassisFrontScreenTempValue": [40, 55],
                            "optrxTempValue": [50, 60],
                            "apmodTempValue": [60, 70],
                        },
                        "metrics": [
                            "opttxTempValue", "chassisTempValue",
                            "chassisFrontScreenTempValue", "optrxTempValue", "apmodTempValue",
                            "chassisFrontScreenTempStatus", "chassisHeatingStatus",
                            "chassisTempStatus", "chassisFan1Status", "chassisFan2Status",
                            "psStatus48V", "psStatus230V", "psStatus5V", "psStatus3V3",
                            "psStatus2V5", "apmodTempStatus", "opttxStatusTemp", "optrxStatusTemp"
                        ]
                    }
                ]
            },
        }

    # Check mode: fetch the single self-test SNMP row only (base .1.3.6.1.4.1.2800.2.1, OID 3)
    res = ctx.run(
        [
            "snmpget", "-On", "-Ov", "-v2c", "-c", "public", "localhost",
            "1.3.6.1.4.1.2800.2.1.3.0"
        ],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    val = res.stdout.strip()
    # Normalize value string to digits only
    if val.startswith("\"") and val.endswith("\""):
        val = val[1:-1]
    if val not in ["1", "2", "3", "4"]:
        return {
            "changed": False,
            "msg": "Unknown data from agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if val == "1":
        return {
            "changed": False,
            "msg": "Airlaser: normal operation",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    if val == "2":
        return {
            "changed": False,
            "msg": "Airlaser: testing mode",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }
    if val == "3":
        return {
            "changed": False,
            "msg": "Airlaser: warning condition",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }
    if val == "4":
        return {
            "changed": False,
            "msg": "Airlaser: a component has failed self-tests",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": "Unknown data from agent",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
