# Checkmk check: safenet_ntls_clients → read-only Starlark check module.
#
# Monitors SafeNet NTLS (network-attached HSM/luna) clients via SNMP.
# Data source: SNMP subtree 1.3.6.1.4.1.12383.3.1.2 on the target host.
# Discovery only yields services when the SafeNet NTLS product is present
# (SysObjectID begins with .1.3.6.1.4.1.12383).

# SNMP base OID for the SafeNet NTLS section.
BASE_OID = "1.3.6.1.4.1.12383.3.1.2"
# Individual column OIDs under BASE_OID.
OID_OPERATION_STATUS = "1"
OID_CONNECTED_CLIENTS = "2"
OID_LINKS = "3"
OID_SUCCESSFUL_CONNECTIONS = "4"
OID_FAILED_CONNECTIONS = "5"
OID_EXPIRATION_DATE = "6"

# Checkmk detection prefixes for sysObjectID.
SAFE_NET_PREFIX = ".1.3.6.1.4.1.12383"
NET_SNMP_PREFIX = ".1.3.6.1.4.1.8072"


def _snmp_get(ctx, params, oid):
    res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _detect_safenet(ctx, params):
    value = _snmp_get(ctx, params, ".1.3.6.1.2.1.1.2.0")
    if value == None:
        return False
    return value.startswith(SAFE_NET_PREFIX) or value.startswith(NET_SNMP_PREFIX)


def _fetch_section(ctx, params):
    operation_status = _snmp_get(ctx, params, BASE_OID + "." + OID_OPERATION_STATUS)
    if operation_status == None:
        return None

    connected_clients = _snmp_get(ctx, params, BASE_OID + "." + OID_CONNECTED_CLIENTS)
    links = _snmp_get(ctx, params, BASE_OID + "." + OID_LINKS)
    successful_connections = _snmp_get(ctx, params, BASE_OID + "." + OID_SUCCESSFUL_CONNECTIONS)
    failed_connections = _snmp_get(ctx, params, BASE_OID + "." + OID_FAILED_CONNECTIONS)
    expiration_date = _snmp_get(ctx, params, BASE_OID + "." + OID_EXPIRATION_DATE)

    if connected_clients == None or links == None or successful_connections == None or failed_connections == None or expiration_date == None:
        return None

    if not connected_clients.lstrip("-").isdigit() or not links.lstrip("-").isdigit() or not successful_connections.lstrip("-").isdigit() or not failed_connections.lstrip("-").isdigit():
        return None

    return {
        "operation_status": operation_status,
        "connected_clients": int(connected_clients),
        "links": int(links),
        "successful_connections": int(successful_connections),
        "failed_connections": int(failed_connections),
        "expiration_date": expiration_date,
    }


def _grade_levels(value, levels):
    if levels == None:
        return "OK"
    warn = None
    crit = None
    if len(levels) >= 1:
        warn = levels[0]
    if len(levels) >= 2:
        crit = levels[1]
    if warn != None and value >= warn:
        return "WARN"
    if crit != None and value >= crit:
        return "CRIT"
    return "OK"


def main(ctx, params):
    if not _detect_safenet(ctx, params):
        return {
            "changed": False,
            "msg": "SafeNet NTLS not detected on this host (sysObjectID mismatch)",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        section = _fetch_section(ctx, params)
        discovery = []
        if section != None:
            discovery = [
                {"item": "connected clients", "params": {}, "metrics": ["connections"]},
                {"item": "links", "params": {"levels": ("no_levels", None)}, "metrics": ["connections"]},
                {"item": "operation status", "params": {}, "metrics": []},
                {"item": "expiration date", "params": {}, "metrics": []},
            ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _fetch_section(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "SafeNet NTLS data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if item == "connected clients":
        value = section["connected_clients"]
        levels = params.get("levels", ("no_levels", None))
        state = _grade_levels(value, levels)
        return {
            "changed": False,
            "msg": "%d connected clients" % value,
            "data": {
                "state": state,
                "metrics": {"connections": value},
                "details": "",
            },
        }

    if item == "links":
        value = section["links"]
        levels = params.get("levels", ("no_levels", None))
        state = _grade_levels(value, levels)
        return {
            "changed": False,
            "msg": "%d links" % value,
            "data": {
                "state": state,
                "metrics": {"connections": value},
                "details": "",
            },
        }

    if item == "operation status":
        operation_status = section["operation_status"]
        if operation_status == "1":
            return {
                "changed": False,
                "msg": "Running",
                "data": {"state": "OK", "metrics": {}, "details": ""},
            }
        if operation_status == "2":
            return {
                "changed": False,
                "msg": "Down",
                "data": {"state": "CRIT", "metrics": {}, "details": ""},
            }
        if operation_status == "3":
            return {
                "changed": False,
                "msg": "Unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return {
            "changed": False,
            "msg": "Unknown operation status: %s" % operation_status,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if item == "expiration date":
        expiration = section["expiration_date"]
        return {
            "changed": False,
            "msg": "The NTLS server certificate expires on " + expiration,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "Unknown item: %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }