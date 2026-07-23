# Module for checkmk.hp_eml_sum (HP EML Summary Status) - read-only Starlark check

_STATUS_MAP = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("OK", "unused"),
    "3": ("OK", "ok"),
    "4": ("WARN", "warning"),
    "5": ("CRIT", "critical"),
    "6": ("CRIT", "nonrecoverable"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always yield exactly one service if the section exists
        # (the SNMP table exists if the host matches the detection OID)
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode (single service, item is always "")
    res = ctx.run(["snmpget", "-Oqv", "-v2c", "-c", "public", "localhost",
                   ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.3",  # opStatus
                   ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.7",  # manufacturer
                   ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.9",  # model
                   ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.10", # serial
                   ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.11", # version
                  ], mutates=False)

    lines = res.stdout.splitlines()
    if len(lines) < 5:
        return {
            "changed": False,
            "msg": "Summary status information missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    op_status = lines[0].strip() if lines[0].strip() else "0"
    manufacturer = lines[1].strip() if len(lines) > 1 else ""
    model = lines[2].strip() if len(lines) > 2 else ""
    serial = lines[3].strip() if len(lines) > 3 else ""
    version = lines[4].strip() if len(lines) > 4 else ""

    state_txt = _STATUS_MAP.get(op_status, ("UNKNOWN", "unhandled op_status (" + op_status + ")"))
    state = state_txt[0]
    status_txt = state_txt[1]

    summary = 'Summary State is "' + status_txt + '", Manufacturer: ' + manufacturer + \
              ', Model: ' + model + ', Serial: ' + serial + ', Version: ' + version

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
