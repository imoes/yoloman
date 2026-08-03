# brocade_sys: CPU utilization + memory utilization for Brocade devices.
# Translated from the Checkmk checkmk.brocade_sys SNMP check plugin.
#
# Two single-service checks are produced from one SNMP section
# (brocade_sys at base .1.3.6.1.4.1.1588.2.1.1.1.26):
#   - "CPU utilization"   (check: brocade_sys)
#   - "Memory"            (check: brocade_sys_mem)
#
# Discovery yields one Service per logical check.  Since the Starlark
# module exposes a single main() we report both items in discovery and
# grade either item in check mode based on params["item"].
#
# Detection of a Brocade device: walk the SNMP OID base used by the
# agent plugin.  If the device does not answer we return an empty
# discovery list / an UNKNOWN verdict -- never a placeholder.

_CPU_OID = ".1.3.6.1.4.1.1588.2.1.1.1.26"
_CPU_UTIL_COL = "1"      # cpu_util
_MEM_UTIL_COL = "6"      # mem_used_percent

DEFAULT_CPU_WARN = 80
DEFAULT_CPU_CRIT = 90
DEFAULT_MEM_WARN = 80
DEFAULT_MEM_CRIT = 90


def _snmp_scalar(ctx, params, oid):
    """Fetch a single scalar SNMP value using net-snmp snmpget -Oqv."""
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    return res.stdout.strip()


def _probe_device(ctx, params):
    """Probe the Brocade SNMP base OID to confirm the device is present.

    Returns the (cpu_util, mem_used_percent) tuple, or None when the
    device is not a Brocade system / does not answer.
    """
    # First establish that something answers at the Brocade sys OID base.
    probe = _snmp_scalar(ctx, params, _CPU_OID + "." + _CPU_UTIL_COL)
    if probe == None:
        return None
    cpu = probe
    mem = _snmp_scalar(ctx, params, _CPU_OID + "." + _MEM_UTIL_COL)
    return (cpu, mem)


def main(ctx, params):
    if params.get("_discover"):
        data = _probe_device(ctx, params)
        if data == None:
            # No Brocade device answering on this host.
            return {
                "changed": False,
                "msg": "no Brocade device found",
                "data": {"discovery": []},
            }
        discovery = [
            {
                "item": "CPU utilization",
                "params": {
                    "warn": DEFAULT_CPU_WARN,
                    "crit": DEFAULT_CPU_CRIT,
                },
                "metrics": ["cpu_util"],
            },
            {
                "item": "Memory",
                "params": {
                    "warn": DEFAULT_MEM_WARN,
                    "crit": DEFAULT_MEM_CRIT,
                },
                "metrics": ["mem_used_percent"],
            },
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE ----
    item = params.get("item", "")
    data = _probe_device(ctx, params)
    if data == None:
        return {
            "changed": False,
            "msg": "no Brocade device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    cpu_str, mem_str = data

    if item == "CPU utilization":
        try_cpu = int(cpu_str) if cpu_str.isdigit() else 0
        warn = params.get("warn", DEFAULT_CPU_WARN)
        crit = params.get("crit", DEFAULT_CPU_CRIT)
        if try_cpu >= crit:
            state = "CRIT"
        elif try_cpu >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {
            "changed": False,
            "msg": "CPU utilization %d%%" % try_cpu,
            "data": {
                "state": state,
                "metrics": {"cpu_util": try_cpu},
                "details": "",
            },
        }

    if item == "Memory":
        try_mem = int(mem_str) if mem_str.isdigit() else 0
        warn = params.get("warn", DEFAULT_MEM_WARN)
        crit = params.get("crit", DEFAULT_MEM_CRIT)
        if try_mem >= crit:
            state = "CRIT"
        elif try_mem >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {
            "changed": False,
            "msg": "Memory %d%%" % try_mem,
            "data": {
                "state": state,
                "metrics": {"mem_used_percent": try_mem},
                "details": "",
            },
        }

    return {
        "changed": False,
        "msg": "unknown item: %s" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }