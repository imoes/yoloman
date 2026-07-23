def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["call_legs"]
                    }
                ]
            }
        }

    # Probe SNMP for cisco_srst_call_legs
    # OID: .1.3.6.1.4.1.9.9.441.1.3.3.0
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        "1.3.6.1.4.1.9.9.441.1.3.3.0"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse output: "iso.3.6.1.4.1.9.9.441.1.3.3.0 = INTEGER: 123"
    output = res.stdout.strip()
    parts = output.split()
    if len(parts) < 4 or parts[-2] != "=" or parts[-1].startswith("INTEGER:"):
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    value_str = parts[-1].split(":", 1)[-1].strip()
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "SNMP value is not an integer",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    call_legs = int(value_str)
    
    return {
        "changed": False,
        "msg": "%d call legs routed through the Cisco device since going active" % call_legs,
        "data": {
            "state": "OK",
            "metrics": {"call_legs": call_legs},
            "details": ""
        }
    }
