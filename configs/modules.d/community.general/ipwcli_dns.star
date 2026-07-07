def main(ctx, params):
    # Extract params with defaults
    dnsname = params["dnsname"]
    dnstype = params["type"]
    container = params["container"]
    address = params.get("address")
    ttl = params.get("ttl", 3600)
    state = params.get("state", "present")
    priority = params.get("priority", 10)
    weight = params.get("weight", 10)
    port = params.get("port")
    target = params.get("target")
    order = params.get("order")
    preference = params.get("preference")
    flags = params.get("flags")
    service = params.get("service")
    replacement = params.get("replacement")
    username = params["username"]
    password = params["password"]

    # Build record string based on type
    if dnstype == "NAPTR":
        if not (preference != None and order != None and service != None and replacement != None):
            fail("type=NAPTR requires preference, order, service, and replacement")
        record = ("naptrrecord %s -set ttl=%s;container=%s;order=%s;preference=%s;flags=\"%s\";service=\"%s\";replacement=\"%s\""
                  % (dnsname, ttl, container, order, preference, flags, service, replacement))
    elif dnstype == "SRV":
        if not (port != None and target != None):
            fail("type=SRV requires port and target")
        record = ("srvrecord %s -set ttl=%s;container=%s;priority=%s;weight=%s;port=%s;target=%s"
                  % (dnsname, ttl, container, priority, weight, port, target))
    elif dnstype in ("A", "AAAA"):
        if address == None:
            fail("type=" + dnstype + " requires address")
        if dnstype == "AAAA":
            record = "aaaarecord %s %s -set ttl=%s;container=%s" % (dnsname, address, ttl, container)
        else:
            record = "arecord %s %s -set ttl=%s;container=%s" % (dnsname, address, ttl, container)
    else:
        fail("unsupported record type: " + dnstype)

    # Build search command for list_record equivalent
    search = "list %s" % record.replace(";", "&&").replace("set", "where")
    cmd = [ctx.get_bin_path("ipwcli", True), "-user=" + username, "-password=" + password]
    res = ctx.run(cmd, data=search)

    if "Invalid username or password" in res.stdout:
        fail("access denied at ipwcli login: Invalid username or password")

    found = False
    if "ARecord " + dnsname in res.stdout:
        found = True
    elif "SRVRecord " + dnsname in res.stdout:
        found = True
    elif "NAPTRRecord " + dnsname in res.stdout:
        found = True

    # Check mode logic
    if ctx.check_mode:
        if (state == "absent" and found) or (state == "present" and not found):
            return {"changed": True, "msg": "would " + ("delete" if state == "absent" else "create") + " record", "data": {"record": record}}
        else:
            return {"changed": False, "msg": "record already in desired state", "data": {"record": record}}

    # Actual state changes
    if state == "absent" and found:
        stdin = "delete %s" % record.replace(";", "&&").replace("set", "where")
        res = ctx.run(cmd, data=stdin, mutates=True)
        if res.rc != 0 or "1 object(s) were updated." not in res.stdout:
            fail("record deletion failed: " + res.stdout)
        return {"changed": True, "msg": "record deleted", "data": {"record": record}}

    if state == "present" and not found:
        stdin = "create %s" % record
        res = ctx.run(cmd, data=stdin, mutates=True)
        if res.rc != 0:
            fail("record creation failed: " + res.stdout)
        if "1 object(s) created." not in res.stdout:
            fail("record creation failed: " + res.stdout)
        return {"changed": True, "msg": "record created", "data": {"record": record}}

    return {"changed": False, "msg": "record already exists and desired state is present", "data": {"record": record}}
