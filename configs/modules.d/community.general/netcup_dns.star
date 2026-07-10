def main(ctx, params):
    api_key = params["api_key"]
    api_password = params["api_password"]
    customer_id = params["customer_id"]
    domain = params["domain"]
    record = params.get("record", "@")
    record_type = params["type"]
    value = params["value"]
    priority = params.get("priority")
    solo = params.get("solo", False)
    state = params.get("state", "present")
    timeout = params.get("timeout", 5)

    if record_type == "MX" and priority == None:
        fail("record type MX requires the 'priority' argument")

    # Build the record string to match (same format as nc-dnsapi)
    rec_str = record + " " + record_type + " " + value
    if priority != None:
        rec_str += " " + str(priority)

    # Call nc-dnsapi CLI tool via ctx.run
    # List all records
    res_list = ctx.run([
        "nc-dnsapi", "-c", str(customer_id), "-k", api_key, "-p", api_password,
        "-d", domain, "-t", str(timeout), "list"
    ])
    if res_list.rc != 0:
        fail("failed to list DNS records: " + res_list.stderr)

    # Parse records from stdout
    # Format: "hostname type destination [priority] [id]"
    lines = res_list.stdout.strip().split("\n") if res_list.stdout.strip() else []
    records = []
    for line in lines:
        if line.strip() == "":
            continue
        parts = line.strip().split()
        if len(parts) < 4:
            fail("unexpected record line format: " + line)
        hostname = parts[0]
        rtype = parts[1]
        dest = parts[2]
        prio = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
        rec_id = int(parts[4]) if len(parts) > 4 and parts[4].isdigit() else None
        records.append({
            "hostname": hostname,
            "type": rtype,
            "destination": dest,
            "priority": prio,
            "id": rec_id,
            "str": hostname + " " + rtype + " " + dest + (" " + str(prio) if prio != None else "")
        })

    # Check if desired record already exists
    record_exists = False
    for r in records:
        if r["str"] == rec_str:
            record_exists = True
            break

    changed = False
    msg = ""

    if state == "present":
        if solo:
            # Delete other records with same name and type but different destination
            obsolete = []
            for r in records:
                if r["hostname"] == record and r["type"] == record_type and r["str"] != rec_str:
                    obsolete.append(r)
            if obsolete:
                if ctx.check_mode:
                    changed = True
                    msg = "would delete " + str(len(obsolete)) + " obsolete record(s)"
                else:
                    ids = [str(r["id"]) for r in obsolete]
                    res_del = ctx.run([
                        "nc-dnsapi", "-c", str(customer_id), "-k", api_key, "-p", api_password,
                        "-d", domain, "-t", str(timeout), "delete", "--ids"] + ids
                    )
                    if res_del.rc != 0:
                        fail("failed to delete obsolete records: " + res_del.stderr)
                    changed = True
                    msg = "deleted " + str(len(obsolete)) + " obsolete record(s); "

        if not record_exists:
            if ctx.check_mode:
                changed = True
                msg += "would create record"
            else:
                # Build command: record type value [priority]
                cmd = [
                    "nc-dnsapi", "-c", str(customer_id), "-k", api_key, "-p", api_password,
                    "-d", domain, "-t", str(timeout), "create"
                ]
                args = [record, record_type, value]
                if priority != None:
                    args.append(str(priority))
                res_create = ctx.run(cmd + args)
                if res_create.rc != 0:
                    fail("failed to create record: " + res_create.stderr)
                changed = True
                msg += "created record"

    elif state == "absent":
        if record_exists:
            if ctx.check_mode:
                changed = True
                msg = "would delete record"
            else:
                # Find record id and delete by id
                rec_id = None
                for r in records:
                    if r["str"] == rec_str:
                        rec_id = r["id"]
                        break
                if rec_id == None:
                    fail("record exists in list but id not found")
                res_del = ctx.run([
                    "nc-dnsapi", "-c", str(customer_id), "-k", api_key, "-p", api_password,
                    "-d", domain, "-t", str(timeout), "delete", "--ids", str(rec_id)
                ])
                if res_del.rc != 0:
                    fail("failed to delete record: " + res_del.stderr)
                changed = True
                msg = "deleted record"

    # Re-fetch records for return data
    if changed or ctx.check_mode:
        res_list = ctx.run([
            "nc-dnsapi", "-c", str(customer_id), "-k", api_key, "-p", api_password,
            "-d", domain, "-t", str(timeout), "list"
        ])
        if res_list.rc == 0:
            lines = res_list.stdout.strip().split("\n") if res_list.stdout.strip() else []
            records = []
            for line in lines:
                if line.strip() == "":
                    continue
                parts = line.strip().split()
                if len(parts) < 4:
                    continue
                hostname = parts[0]
                rtype = parts[1]
                dest = parts[2]
                prio = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
                rec_id = int(parts[4]) if len(parts) > 4 and parts[4].isdigit() else None
                records.append({
                    "name": hostname,
                    "type": rtype,
                    "value": dest,
                    "priority": prio,
                    "id": rec_id
                })
        else:
            records = []

    return {"changed": changed, "msg": msg, "data": {"records": records}}
