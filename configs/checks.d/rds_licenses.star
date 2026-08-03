# Checkmk check: rds_licenses (Windows Remote Desktop Services licenses)
# Translated to a read-only Starlark check module for the yolo-man agent.

VERSION_ID_MAP = {
    "8": "Windows Server 2025",
    "7": "Windows Server 2022",
    "6": "Windows Server 2019",
    "5": "Windows Server 2016",
    "4": "Windows Server 2012",
    "3": "Windows Server 2008 R2",
    "2": "Windows Server 2008",
}


def _license_levels(total, levels_param):
    if levels_param == None:
        return None, None
    if type(levels_param) == "list" and len(levels_param) >= 2:
        warn_count = levels_param[0]
        crit_count = levels_param[1]
        warn_val = None
        crit_val = None
        if warn_count != None:
            warn_val = float(max(0, total - int(warn_count)))
        if crit_count != None:
            crit_val = float(max(0, total - int(crit_count)))
        return warn_val, crit_val
    return None, None


def _fetch_rds_licenses(ctx):
    res = ctx.run([
        "powershell",
        "-NoProfile",
        "-Command",
        "Get-WmiObject -Class Win32_RDS_LicenseKeyPack -Namespace root\\cimv2\\terminalservices -ErrorAction SilentlyContinue | ForEach-Object { $pack = $_; '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f $pack.KeyPackId,$pack.Description,$pack.KeyPackType,$pack.ProductType,$pack.ProductVersion,$pack.ProductVersionID,$pack.TotalLicenses,$pack.IssuedLicenses,$pack.AvailableLicenses,$pack.ExpirationDate }",
    ], mutates=False)
    return res


def _parse_licenses(res):
    if res.rc != 0 or not res.stdout or res.skipped:
        return {}
    parsed = {}
    headers = None
    for line in res.stdout.splitlines():
        fields = line.split(",")
        if headers == None:
            headers = fields
            continue
        if not headers:
            continue
        data = {}
        for i, field in enumerate(fields):
            if i < len(headers):
                data[headers[i]] = field
        version_id = data.get("ProductVersionID", "")
        if version_id not in VERSION_ID_MAP:
            continue
        version = VERSION_ID_MAP[version_id]
        if version not in parsed:
            parsed[version] = []
        parsed[version].append(data)
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        facts = ctx.facts()
        if facts.get("os_family") != "windows":
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        res = _fetch_rds_licenses(ctx)
        parsed = _parse_licenses(res)
        if not parsed:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        discovery = []
        for version in sorted(parsed.keys()):
            discovery.append({
                "item": version,
                "params": {"levels": [None, None]},
                "metrics": ["licenses"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    facts = ctx.facts()
    if facts.get("os_family") != "windows":
        return {
            "changed": False,
            "msg": "not a Windows host: no RDS license data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = _fetch_rds_licenses(ctx)
    parsed = _parse_licenses(res)
    if not parsed:
        return {
            "changed": False,
            "msg": "no RDS license data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = parsed.get(item)
    if not data:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = 0
    used = 0
    for pack in data:
        pack_total = int(pack.get("TotalLicenses", "0") or "0")
        pack_issued = int(pack.get("IssuedLicenses", "0") or "0")
        total += pack_total
        used += pack_issued

    levels = params.get("levels", [None, None])
    warn, crit = _license_levels(total, levels)

    if used <= total:
        summary = "used %d out of %d licenses" % (used, total)
    else:
        summary = "used %d licenses, but you have only %d" % (used, total)

    state = "OK"
    if warn != None and crit != None:
        if used >= crit:
            state = "CRIT"
        elif used >= warn:
            state = "WARN"
        if state != "OK":
            summary = summary + " (warn/crit at %d/%d)" % (int(warn), int(crit))

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"licenses": float(used)},
            "details": "",
        },
    }