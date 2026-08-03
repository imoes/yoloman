# CheckMK check: salesforce_instances -> read-only Starlark check module.
# Data source: the public Salesforce status endpoint (network). No CheckMK,
# no local host stand-in. Monitored service is reached over the network.

_STATUS_MAP = {
    "OK": ("OK", "OK"),
    "MAJOR_INCIDENT_CORE": ("CRIT", "major incident core"),
    "MINOR_INCIDENT_CORE": ("WARN", "minor incident core"),
    "MAINTENANCE_CORE": ("OK", "maintenance core"),
    "INFORMATIONAL_CORE": ("OK", "informational core"),
    "MAJOR_INCIDENT_NONCORE": ("CRIT", "major incident noncore"),
    "MINOR_INCIDENT_NONCORE": ("WARN", "minor incident noncore"),
    "MAINTENANCE_NONCORE": ("OK", "maintenance noncore"),
    "INFORMATIONAL_NONCORE": ("OK", "informational noncore"),
}


def _fetch_json(ctx, url):
    # curl is read-only: never mutates, runs even in check_mode.
    res = ctx.run(
        ["curl", "-sS", "-L", "--fail", "--max-time", "15", url],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return None
    # The public endpoint emits well-formed JSON; decode surfaces any real
    # malformation as a hard abort rather than a mis-parsed value.
    return json.decode(res.stdout)


def _is_active(data):
    # Mirrors the source section's "isActive" discovery gating.
    return bool(data.get("isActive")) if data else False


def main(ctx, params):
    host = params.get("host", "status.salesforce.com")

    # The CheckMK agent plugin publishes a single JSON array of instance
    # objects under one section. Here we gather that same payload directly
    # from the public status endpoint.
    root = _fetch_json(ctx, "https://%s/index.json" % host)

    if params.get("_discover"):
        if root == None:
            return {"changed": False,
                    "msg": "salesforce status unreachable",
                    "data": {"discovery": [], "host_labels": {}}}
        entries = {}
        if type(root) == "list":
            for entry in root:
                if type(entry) == "dict" and entry.get("key") and _is_active(entry):
                    entries[entry["key"]] = entry
        elif type(root) == "dict":
            for instance, data in root.items():
                if _is_active(data):
                    d = dict(data)
                    d["key"] = instance
                    entries[instance] = d
        discovery = []
        for instance in entries:
            discovery.append({
                "item": instance,
                "params": {},
                "metrics": ["status"],
            })
        return {"changed": False,
                "msg": "discovered %d instances" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    item = params.get("item", "")

    if root == None:
        return {"changed": False,
                "msg": "salesforce status unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Same per-instance selection used at discovery time.
    data = None
    if type(root) == "list":
        for entry in root:
            if type(entry) == "dict" and entry.get("key") == item and _is_active(entry):
                data = entry
                break
    elif type(root) == "dict":
        d = root.get(item)
        if _is_active(d):
            data = dict(d)
            data["key"] = item

    if data == None:
        # Not active / not present -> UNKNOWN, never a synthesised name.
        return {"changed": False,
                "msg": "no active salesforce instance: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = data.get("status")
    mapped = _STATUS_MAP.get(status, ("UNKNOWN", "unknown[%s]" % status))
    state, state_readable = mapped
    details = []
    for key, title in [
        ("environment", "Environment"),
        ("releaseNumber", "Release Number"),
        ("releaseVersion", "Release Version"),
    ]:
        if data.get(key):
            details.append("%s: %s" % (title, data[key]))

    return {"changed": False,
            "msg": "Status: %s" % state_readable,
            "data": {
                "state": state,
                "metrics": {"status": 0},
                "details": "\n".join(details),
            }}