def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # First, check if this is a Kentix device by probing sysObjectID
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "not a Kentix device", "data": {"discovery": []}}
        
        sys_oid = sys_oid_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.332.11.6"):
            return {"changed": False, "msg": "not a Kentix device", "data": {"discovery": []}}
        
        # Try primary SNMP tree
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.37954.2.1.2"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # Try secondary SNMP tree
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.37954.3.1.2"], mutates=False)
        
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no humidity data", "data": {"discovery": []}}
        
        return {"changed": False, "msg": "discovered Humidity", "data": {"discovery": [
            {"item": "", "params": {}, "metrics": ["humidity"]}
        ]}}
    
    # Check mode
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # ... fetch and check