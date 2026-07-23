def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    port = int(params.get("port") or 5000)
    service = params.get("uniserv_service") or ""
    check_mode = params.get("check_mode") or "version"

    argv = ["check_uniserv", host, str(port), service]

    if check_mode == "version":
        argv.append("VERSION")
    else:
        street = params.get("street") or ""
        street_no = int(params.get("street_no") or 0)
        city = params.get("city") or ""
        search_regex = params.get("search_regex") or ""
        argv = argv + ["ADDRESS", street, str(street_no), city, search_regex]

    result = ctx.run(argv, ok_codes=[0, 1, 2, 3])
    rc = result.rc
    out = (result.stdout or "").strip()
    if not out:
        out = (result.stderr or "").strip()

    if rc == 0:
        state = "OK"
    elif rc == 1:
        state = "WARN"
    elif rc == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    details = out or ("check_uniserv rc=%d" % rc)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": {}, "details": details}}
