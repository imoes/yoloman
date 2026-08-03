PRINTER_MANUFACTURERS = [
    ".1.3.6.1.4.1.2435.2.3.9",
    ".1.3.6.1.4.1.1602",
    ".1.3.6.1.4.1.5502",
    ".1.3.6.1.4.1.25278",
    ".1.3.6.1.4.1.27748",
    ".1.3.6.1.4.1.11.2.3.9.1",
    ".1.3.6.1.4.1.18334",
    ".1.3.6.1.4.1.1347",
    ".1.3.6.1.4.1.2001.1",
    ".1.3.6.1.4.1.1129",
    ".1.3.6.1.4.1.367",
    ".1.3.6.1.4.1.236",
    ".1.3.6.1.4.1.253.8.62.1",
    ".1.3.6.1.4.1.3835",
    ".1.3.6.1.4.1.683.6",
    ".1.3.6.1.4.1.10642",
    ".1.3.6.1.4.1.674",
    ".1.3.6.1.4.1.345",
    ".1.3.6.1.4.1.1248",
    ".1.3.6.1.4.1.641.2",
    ".1.3.6.1.4.1.641.52",
    ".1.3.6.1.4.1.641.1",
    ".1.3.6.1.4.1.641.3",
    ".1.3.6.1.4.1.641.51",
    ".1.3.6.1.4.1.396",
    ".1.3.6.1.4.1.44932",
    ".1.3.6.1.4.1.1472",
    ".1.3.6.1.4.1.2385",
    ".1.3.6.1.4.1.186",
    ".1.3.6.1.4.1.33241",
    ".1.3.6.1.4.1.6345",
    ".1.3.6.1.4.1.2125",
    ".1.3.6.1.4.1.4228",
    ".1.3.6.1.4.1.314",
    ".1.3.6.1.4.1.16653",
    ".1.3.6.1.4.1.28959",
    ".1.3.6.1.4.1.28708",
    ".1.3.6.1.4.1.79",
    ".1.3.6.1.4.1.211",
    ".1.3.6.1.4.1.231",
    ".1.3.6.1.4.1.297",
    ".1.3.6.1.4.1.3369",
    ".1.3.6.1.4.1.116",
    ".1.3.6.1.4.1.2",
    ".1.3.6.1.4.1.28918",
    ".1.3.6.1.4.1.3793",
    ".1.3.6.1.4.1.11369",
    ".1.3.6.1.4.1.815",
    ".1.3.6.1.4.1.102",
    ".1.3.6.1.4.1.1552",
    ".1.3.6.1.4.1.279",
    ".1.3.6.1.4.1.10504",
    ".1.3.6.1.4.1.24807",
    ".1.3.6.1.4.1.42406",
    ".1.3.6.1.4.1.263",
    ".1.3.6.1.4.1.22624",
    ".1.3.6.1.4.1.25549",
    ".1.3.6.1.4.1.128",
    ".1.3.6.1.4.1.294",
    ".1.3.6.1.4.1.38191",
    ".1.3.6.1.4.1.950",
    ".1.3.6.1.4.1.25816",
    ".1.3.6.1.4.1.28878",
    ".1.3.6.1.4.1.40463",
    ".1.3.6.1.4.1.122",
    ".1.3.6.1.4.1.119",
]

def _is_printer(community, host, ctx):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "5", "-r", "1", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    if not sys_oid:
        return False
    for oid in PRINTER_MANUFACTURERS:
        if sys_oid.startswith(oid):
            return True
    return False

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        if not _is_printer(community, host, ctx):
            return {"changed": False, "msg": "no printer detected", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"warn": None, "crit": None}, "metrics": ["pages_total"]}]}}
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "5", "-r", "1", host, ".1.3.6.1.2.1.43.10.2.1.4.1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not retrieve pages: " + res.stderr.strip(), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = res.stdout.strip()
    if not val.isdigit():
        return {"changed": False, "msg": "invalid pages value: " + val, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pages = int(val)
    return {"changed": False, "msg": "total prints: %d" % pages, "data": {"state": "OK", "metrics": {"pages_total": pages}, "details": ""}}