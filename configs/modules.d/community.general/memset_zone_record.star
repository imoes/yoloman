def main(ctx, params):
    api_key = params.get("api_key")
    zone = params.get("zone")
    record = params.get("record", "")
    address = params.get("address")
    record_type = params.get("type")
    state = params.get("state", "present")
    ttl = params.get("ttl", 0)
    priority = params.get("priority", 0)
    relative = params.get("relative", False)

    # Validation: address max 250 chars
    if len(address) > 250:
        fail("Address must be less than 250 characters in length.")
    # Validation: record max 63 chars
    if record and len(record) > 63:
        fail("Record must be less than 63 characters in length.")
    # Validation: priority 0-999
    if (priority < 0) or (priority > 999):
        fail("Priority must be in the range 0 > 999 (inclusive).")
    # Validation: relative only for CNAME/MX/NS/SRV
    if relative and record_type not in ["CNAME", "MX", "NS", "SRV"]:
        fail("Relative is only valid for CNAME, MX, NS and SRV record types.")

    # Get zone list
    res = ctx.run([
        "curl", "-s", "-X", "POST", "https://api.memset.com/v1/dns.zone_list",
        "-d", "api_key=" + api_key
    ], mutates=False)
    if res.rc != 0:
        fail("Failed to fetch DNS zones: " + res.stderr)
    zones = res.stdout

    # Parse JSON manually (simple list of dicts with 'domain' and 'zone_id')
    zone_list = []
    i = 0
    while i < len(zones):
        if zones[i:i+10] == '"domain"' and i + 10 < len(zones):
            i += 10
            # Skip to value
            while i < len(zones) and zones[i] != '"':
                i += 1
            i += 1
            domain_end = zones.find('"', i)
            domain = zones[i:domain_end]
            i = domain_end + 1
            # Skip to zone_id
            i = zones.find('"zone_id"', i)
            if i == -1:
                break
            i += 10
            while i < len(zones) and zones[i] != '"':
                i += 1
            i += 1
            zone_id_end = zones.find('"', i)
            zone_id = zones[i:zone_id_end]
            zone_list.append({"domain": domain, "zone_id": zone_id})
            i = zone_id_end
        i += 1

    # Find matching zone
    zone_ids = [z for z in zone_list if z["domain"] == zone]
    if len(zone_ids) == 0:
        fail("DNS zone " + zone + " does not exist.")
    if len(zone_ids) > 1:
        fail(zone + " matches multiple zones.")
    zone_id = zone_ids[0]["zone_id"]

    # Get all records
    res = ctx.run([
        "curl", "-s", "-X", "POST", "https://api.memset.com/v1/dns.zone_record_list",
        "-d", "api_key=" + api_key
    ], mutates=False)
    if res.rc != 0:
        fail("Failed to fetch DNS records: " + res.stderr)
    records_raw = res.stdout

    # Parse records list
    records = []
    i = 0
    while i < len(records_raw):
        if records_raw[i] == '{':
            # Find matching '}'
            brace_count = 1
            j = i + 1
            while j < len(records_raw) and brace_count > 0:
                if records_raw[j] == '{':
                    brace_count += 1
                elif records_raw[j] == '}':
                    brace_count -= 1
                j += 1
            obj_str = records_raw[i:j]
            record_obj = {}
            for field in ["id", "record", "type", "zone_id", "address", "priority", "ttl", "relative"]:
                key = '"' + field + '":'
                idx = obj_str.find(key)
                if idx != -1:
                    start = obj_str.find('"', idx + len(key))
                    if start != -1:
                        end = obj_str.find('"', start + 1)
                        if end != -1:
                            record_obj[field] = obj_str[start+1:end]
                        else:
                            val_str = obj_str[idx+len(key):].strip()
                            if val_str.startswith('"'):
                                end = val_str.find('"', 1)
                                record_obj[field] = val_str[1:end]
                            elif val_str.startswith('true') or val_str.startswith('false'):
                                record_obj[field] = val_str.startswith('true')
                            else:
                                # parse integer directly (no try/except allowed)
                                val_str = val_str.split(',')[0].split('}')[0].strip()
                                if val_str != "":
                                    record_obj[field] = int(val_str)
                                else:
                                    record_obj[field] = 0
            if len(record_obj) > 0:
                records.append(record_obj)
            i = j
        else:
            i += 1

    # Filter matching records
    matching = []
    for r in records:
        if (r.get("zone_id") == zone_id and
            r.get("record") == record and
            r.get("type") == record_type):
            matching.append(r)

    # Relative handling: add zone domain to address for certain types
    def normalize_address(addr, rtype, rel):
        if rel and rtype in ["CNAME", "MX", "NS", "SRV"]:
            return addr + "." + zone
        return addr

    normalized_address = normalize_address(address, record_type, relative)

    if state == "present":
        # Check if record already matches
        for r in matching:
            if (r.get("address") == normalized_address and
                int(r.get("priority", 0)) == priority and
                int(r.get("ttl", 0)) == ttl and
                bool(r.get("relative", False)) == relative):
                return {"changed": False, "msg": "Record already exists", "data": r}

        # Create or update
        if len(matching) > 0:
            api_method = "dns.zone_record_update"
        else:
            api_method = "dns.zone_record_create"

        if ctx.check_mode:
            new_record = {
                "id": matching[0]["id"] if len(matching) > 0 else "new",
                "zone_id": zone_id,
                "record": record,
                "type": record_type,
                "address": normalized_address,
                "priority": priority,
                "ttl": ttl,
                "relative": relative
            }
            return {"changed": True, "msg": "Would " + api_method.split('.')[2] + " record", "data": new_record}

        # Build POST payload
        payload = "api_key=" + api_key
        payload += "&zone_id=" + zone_id
        payload += "&record=" + record
        payload += "&type=" + record_type
        payload += "&address=" + normalized_address
        payload += "&priority=" + str(priority)
        payload += "&ttl=" + str(ttl)
        payload += "&relative=" + ("1" if relative else "0")
        if len(matching) > 0:
            payload += "&id=" + matching[0]["id"]

        res = ctx.run([
            "curl", "-s", "-X", "POST", "https://api.memset.com/v1/" + api_method,
            "-d", payload
        ], mutates=True)

        if res.rc != 0:
            fail("API call " + api_method + " failed: " + res.stderr)

        # Parse response (simplified JSON)
        response = res.stdout
        result = {}
        if response.startswith('{'):
            for field in ["id", "record", "type", "zone_id", "address", "priority", "ttl", "relative"]:
                key = '"' + field + '":'
                idx = response.find(key)
                if idx != -1:
                    start = response.find('"', idx + len(key))
                    if start != -1:
                        end = response.find('"', start + 1)
                        if end != -1:
                            result[field] = response[start+1:end]
                        else:
                            val_str = response[idx+len(key):].strip()
                            if val_str.startswith('true') or val_str.startswith('false'):
                                result[field] = val_str.startswith('true')
                            else:
                                val_str = val_str.split(',')[0].split('}')[0].strip()
                                if val_str != "":
                                    result[field] = int(val_str)
                                else:
                                    result[field] = 0

        return {"changed": True, "msg": "Record " + api_method.split('.')[2] + "ed", "data": result}

    elif state == "absent":
        if len(matching) == 0:
            return {"changed": False, "msg": "Record does not exist"}

        if ctx.check_mode:
            return {"changed": True, "msg": "Would delete record", "data": matching[0]}

        # Delete record
        payload = "api_key=" + api_key + "&id=" + matching[0]["id"]
        res = ctx.run([
            "curl", "-s", "-X", "POST", "https://api.memset.com/v1/dns.zone_record_delete",
            "-d", payload
        ], mutates=True)

        if res.rc != 0:
            fail("Failed to delete record: " + res.stderr)

        return {"changed": True, "msg": "Record deleted", "data": matching[0]}

    else:
        fail("Unsupported state: " + state)
