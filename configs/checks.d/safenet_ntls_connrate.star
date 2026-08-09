# Checkmk check: checkmk.safenet_ntls_connrate
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This is an SNMP-based Checkmk check. The on-host source is a network device
# (Safenet NTLS appliance) queried via SNMP. We probe the same OIDs the
# Checkmk SimpleSNMPSection would fetch.
#
# SNMP base OID: .1.3.6.1.4.1.12383.3.1.2
# OIDs (relative to base): 1=operation_status, 2=connected_clients,
#                          3=links, 4=successful_connections,
#                          5=failed_connections, 6=expiration_date

BASE_OID = ".1.3.6.1.4.1.12383.3.1.2"

OID_OP_STATUS  = "1"
OID_CLIENTS    = "2"
OID_LINKS      = "3"
OID_SUCCESS    = "4"
OID_FAILED     = "5"
OID_EXPIRATION = "6"

def _fetch_section(ctx, host, community):
    oids = [
        BASE_OID + "." + OID_OP_STATUS,
        BASE_OID + "." + OID_CLIENTS,
        BASE_OID + "." + OID_LINKS,
        BASE_OID + "." + OID_SUCCESS,
        BASE_OID + "." + OID_FAILED,
        BASE_OID + "." + OID_EXPIRATION,
    ]
    values = []
    for oid in oids:
        r = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                community,
                "-Oqv",
                host,
                oid,
            ],
            mutates=False,
        )
        if r.rc != 0:
            return None
        val = r.stdout.strip()
        values.append(val)
    if len(values) != 6:
        return None
    op_status = values[0]
    connected_clients = int(values[1]) if values[1].isdigit() else 0
    links = int(values[2]) if values[2].isdigit() else 0
    successful_connections = int(values[3]) if values[3].isdigit() else 0
    failed_connections = int(values[4]) if values[4].isdigit() else 0
    expiration_date = values[5]
    return {
        "operation_status": op_status,
        "connected_clients": connected_clients,
        "links": links,
        "successful_connections": successful_connections,
        "failed_connections": failed_connections,
        "expiration_date": expiration_date,
    }

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        section = _fetch_section(ctx, host, community)
        if section == None:
            return {
                "changed": False,
                "msg": "Safenet NTLS device not reachable or no data",
                "data": {"discovery": []},
            }
        discovery = [
            {"item": "successful", "params": {}, "metrics": ["connections_rate"]},
            {"item": "failed", "params": {}, "metrics": ["connections_rate"]},
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _fetch_section(ctx, host, community)
    if section == None:
        return {
            "changed": False,
            "msg": "Safenet NTLS device not reachable or no data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no safenet_ntls section available",
            },
        }

    if item == "successful":
        item_data = section["successful_connections"]
    elif item == "failed":
        item_data = section["failed_connections"]
    else:
        return {
            "changed": False,
            "msg": "unknown item: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    connections_rate = float(item_data)
    return {
        "changed": False,
        "msg": "%f connections/s" % connections_rate,
        "data": {
            "state": "OK",
            "metrics": {"connections_rate": connections_rate},
            "details": "",
        },
    }