def main(ctx, params):
    # ----- Siemens S7 PLC CPU state check -----
    # Data source: SNMP query to the Siemens PLC special agent's CPU status OID.
    # The SIEMENS-S7-MIB defines s7CpuStatus at .1.3.6.1.4.1.231.2.10.1.5.1.0
    # which returns the CPU state as a named string (s7CpuStatusRun, etc.).
    # The special agent resolves the integer enum to the S7CpuStatus* strings.

    if params.get("_discover"):
        # Discovery: the CPU state service always applies when the PLC
        # responds to the SNMP query — one service per host.
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        oid = "1.3.6.1.4.1.231.2.10.1.5.1.0"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc == 127:
            # No snmpget installed — cannot reach the device.
            return {"changed": False, "msg": "snmpget not found", "data": {"discovery": []}}
        if res.rc != 0:
            # Cannot reach the PLC or OID not available.
            return {"changed": False, "msg": "no response from PLC", "data": {"discovery": []}}
        # Service always exists for this host — it monitors the single PLC's CPU.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    # ----- Check mode -----
    # Gather the CPU state via SNMP.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = "1.3.6.1.4.1.231.2.10.1.5.1.0"

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not installed — cannot query PLC",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query PLC CPU state: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # -Oqv returns the bare value; strip any surrounding quotes.
    state = res.stdout.strip().strip('"')

    if state == "S7CpuStatusRun":
        return {
            "changed": False,
            "msg": "CPU is running",
            "data": {"state": "OK", "metrics": {}, "details": state},
        }
    if state == "S7CpuStatusStop":
        return {
            "changed": False,
            "msg": "CPU is stopped",
            "data": {"state": "CRIT", "metrics": {}, "details": state},
        }
    return {
        "changed": False,
        "msg": "CPU is in unknown state: " + state,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": state},
    }