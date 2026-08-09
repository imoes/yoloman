def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "discovery not applicable without SNMP target",
                "data": {"discovery": []}}
    return {"changed": False, "msg": "SNMP target required for akcp_sensor_temp",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}