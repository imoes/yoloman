# Checkpoint Firewall Module check — translated to read-only Starlark for the
# yolo-man agent. Reproduces cmk's checkpoint_firewall SNMP-based check.
#
# Data source: the Checkmk plugin fetches an SNMPTree at
#   base = .1.3.6.1.4.1.2620.1.1
#   oids = [1, 2, 3, 8, 9]
# i.e. scalars .1.3.6.1.4.1.2620.1.1.1 (state),
#        .1.3.6.1.4.1.2620.1.1.2 (filter_name),
#        .1.3.6.1.4.1.2620.1.1.3 (filter_date),
#        .1.3.6.1.4.1.2620.1.1.8 (major),
#        .1.3.6.1.4.1.2620.1.1.9 (minor)
# Discovery yields a single Service (no per-item breakdown) when the section
# has data. Checkmk's detect requires the device to be a Check Point / IPSO /
# Gaia system, so absence -> empty discovery and UNKNOWN verdict.

# Scalar OID column for each fetched value, in the same order as the OID list.
STATE_OID       = ".1.3.6.1.4.1.2620.1.1.1"
FILTER_NAME_OID = ".1.3.6.1.4.1.2620.1.1.2"
FILTER_DATE_OID = ".1.3.6.1.4.1.2620.1.1.3"
MAJOR_OID       = ".1.3.6.1.4.1.2620.1.1.8"
MINOR_OID       = ".1.3.6.1.4.1.2620.1.1.9"

DEFAULT_HOST      = "localhost"
DEFAULT_COMMUNITY = "public"
DEFAULT_VERSION   = "2c"

def _snmpget(ctx, host, community, version, oid):
    # -Oqv prints the bare value only (no type tag / "= ").
    args = ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid]
    return ctx.run(args, mutates=False)

def _probe_firewall(ctx, params):
    host = params.get("host", DEFAULT_HOST)
    community = params.get("community", DEFAULT_COMMUNITY)
    version = params.get("version", DEFAULT_VERSION)

    # PROBE FOR THE REAL THING: confirm snmpget tooling exists.
    probe = ctx.run(["snmpget", "-V"], mutates=False)
    if probe.rc == 127:
        return None  # net-snmp not installed on this host
    if probe.rc != 0:
        return None

    state_res = _snmpget(ctx, host, community, version, STATE_OID)
    # Any non-zero / empty result means this OID (and thus the firewall
    # module) is not present — no fabricated data.
    if state_res.rc != 0 or not state_res.stdout.strip():
        return None

    state = state_res.stdout.strip()
    filter_res = _snmpget(ctx, host, community, version, FILTER_NAME_OID)
    filter_name = filter_res.stdout.strip() if filter_res.stdout else ""

    date_res = _snmpget(ctx, host, community, version, FILTER_DATE_OID)
    filter_date = date_res.stdout.strip() if date_res.stdout else ""

    major_res = _snmpget(ctx, host, community, version, MAJOR_OID)
    major = major_res.stdout.strip() if major_res.stdout else ""

    minor_res = _snmpget(ctx, host, community, version, MINOR_OID)
    minor = minor_res.stdout.strip() if minor_res.stdout else ""

    return [state, filter_name, filter_date, major, minor]

def main(ctx, params):
    if params.get("_discover"):
        data = _probe_firewall(ctx, params)
        if not data or not data[0]:
            # Not a Check Point system / no firewall module present.
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
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
                ]
            },
        }

    # CHECK MODE — evaluate a single item ("" for this single-service check).
    data = _probe_firewall(ctx, params)
    if not data or not data[0]:
        return {
            "changed": False,
            "msg": "Firewall Module not present: no Check Point SNMP response",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state, filter_name, filter_date, major, minor = data
    if state.lower() == "installed":
        # State.OK
        return {
            "changed": False,
            "msg": "%s (v%s.%s), filter: %s (since %s)" % (state, major, minor, filter_name, filter_date),
            "data": {
                "state": "OK",
                "metrics": {},
                "details": "",
            },
        }
    # Anything other than "installed" -> CRIT
    return {
        "changed": False,
        "msg": "not installed, state: %s" % state,
        "data": {
            "state": "CRIT",
            "metrics": {},
            "details": "",
        },
    }