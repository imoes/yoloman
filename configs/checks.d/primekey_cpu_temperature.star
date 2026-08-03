DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_VALUE = ".1.3.6.1.4.1.8072.3.2.10"
CPU_TEMP_BASE = ".1.3.6.1.4.1.22408.1.1.2.1.3.99.112.117"
CPU_TEMP_OID = CPU_TEMP_BASE + ".1"

def _is_primekey(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, DETECT_OID], mutates=False)
    if res.rc == 127 or res.rc == 1:
        return False
    if res.rc != 0:
        return False
    return res.stdout.strip() == DETECT_VALUE

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        if not _is_primekey(ctx, host, community):
            return {"changed": False, "msg": "no PrimeKey device found", "data": {"discovery": []}}
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, CPU_TEMP_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no PrimeKey CPU temperature found", "data": {"discovery": []}}
        raw = res.stdout.strip()
        if raw == "":
            return {"changed": False, "msg": "no PrimeKey CPU temperature found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items", "data": {"discovery": [{"item": "CPU", "params": {"warn": 20.0, "crit": 50.0}, "metrics": ["temperature"]}]}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _is_primekey(ctx, host, community):
        return {"changed": False, "msg": "no PrimeKey device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "PrimeKey device not present or not reachable"}}
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, CPU_TEMP_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no PrimeKey CPU temperature found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not fetch CPU temperature OID"}}
    raw = res.stdout.strip()
    if raw == "":
        return {"changed": False, "msg": "no PrimeKey CPU temperature found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Empty CPU temperature value"}}

    temperature = float(raw) if raw.lstrip("-").replace(".", "", 1).isdigit() else None
    if temperature == None:
        return {"changed": False, "msg": "invalid temperature value", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not parse CPU temperature: %s" % raw}}

    warn = params.get("warn", 20.0)
    crit = params.get("crit", 50.0)
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "CPU temperature: %f C" % temperature, "data": {"state": state, "metrics": {"temperature": temperature}, "details": "PrimeKey %s Temperature" % item}}