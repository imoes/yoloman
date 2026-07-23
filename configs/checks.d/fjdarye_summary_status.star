# Module: checkmk.fjdarye_summary_status
# Read-only Starlark check for Fujitsu storage system summary status

FJDARYE_SUM_STATUS = {
    "1": {"state": "CRIT", "summary": "Status: unknown"},
    "2": {"state": "CRIT", "summary": "Status: unused"},
    "3": {"state": "OK", "summary": "Status: ok"},
    "4": {"state": "WARN", "summary": "Status: warning"},
    "5": {"state": "CRIT", "summary": "Status: failed"},
}

def main(ctx, params):
    # Discovery mode: check for the presence of the SNMP section
    if params.get("_discover"):
        # Probe device OID .1.3.6.1.2.1.1.2.0 (sysObjectID) to detect supported Fujitsu devices
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}
        
        sysoid = res.stdout.strip().split(" = ")[-1].strip()
        
        supported_oids = [
            ".1.3.6.1.4.1.211.1.21.1.60",   # fjdarye60
            ".1.3.6.1.4.1.211.1.21.1.100",  # fjdarye100
            ".1.3.6.1.4.1.211.1.21.1.101",  # fjdarye101
            ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
            ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
        ]
        
        discovered = []
        for supported_oid in supported_oids:
            if sysoid == supported_oid:
                discovered.append({"item": "", "params": {}, "metrics": []})
                break
        
        return {"changed": False, "msg": "discovered %d services" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode: fetch the summary status
    # For FJDARY-E devices, the status is at .1.3.6.1.4.1.211.1.21.1.X.6.0 for each device type X
    status = None
    device_oids = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.100",
        ".1.3.6.1.4.1.211.1.21.1.101",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]
    
    for device_oid in device_oids:
        # Query status OID: <device_oid>.6.0
        oid = device_oid + ".6.0"
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", oid], mutates=False)
        if res.rc == 0:
            output = res.stdout.strip()
            # Parse output like: OID = INTEGER: 3
            if output.find(" = ") != -1:
                parts = output.split(" = ")
                if len(parts) == 2:
                    value = parts[-1].strip()
                    # Extract numeric status value (e.g., "3" from "INTEGER: 3" or just "3")
                    if value.startswith("INTEGER: "):
                        value = value[11:].strip()
                    # Check if value is numeric
                    if value.isdigit():
                        status = value
                        break
    
    if status == None:
        return {"changed": False, "msg": "Summary Status unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    summary_info = FJDARYE_SUM_STATUS.get(status, {"state": "UNKNOWN", "summary": "Status: unknown"})
    state = summary_info["state"]
    summary = summary_info["summary"]
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
