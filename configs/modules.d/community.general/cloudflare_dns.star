def main(ctx, params):
    # Authentication validation
    api_token = params.get("api_token")
    account_api_key = params.get("account_api_key")
    account_email = params.get("account_email")

    if not api_token and not (account_api_key and account_email):
        fail("Either api_token or account_api_key and account_email params are required.")

    # Normalize inputs
    zone = params["zone"].lower()
    record = params.get("record", "@")
    if record == "@":
        record = zone
    else:
        record = record.lower()

    rec_type = params["type"]
    value = params.get("value")
    port = params.get("port")
    proto = params.get("proto")
    service = params.get("service")
    weight = params.get("weight")
    priority = params.get("priority", 1)

    # Normalize record values
    if rec_type in ["CNAME", "NS", "MX", "SRV"]:
        if value:
            value = value.rstrip(".").lower()

    if rec_type == "AAAA" and value:
        value = value.lower()

    # Normalize SRV/TLSA formatting
    search_record = record
    search_value = value
    if rec_type == "SRV":
        if proto and not proto.startswith("_"):
            proto = "_" + proto
        if service and not service.startswith("_"):
            service = "_" + service
        search_record = service + "." + proto + "." + record if service and proto else record
        search_value = str(weight) + "\t" + str(port) + "\t" + value if weight and port else None
        # Required params check
        for attr in [port, priority, proto, service, weight, value]:
            if attr == None or attr == "":
                fail("You must provide port, priority, proto, service, weight and a value to create this record type")
    elif rec_type == "TLSA":
        if proto and not proto.startswith("_"):
            proto = "_" + proto
        if port:
            port = "_" + str(port)
        search_record = port + "." + proto + "." + record if port and proto else record
        search_value = str(params.get("cert_usage", 0)) + "\t" + str(params.get("selector", 0)) + "\t" + str(params.get("hash_type", 0)) + "\t" + value if value else None
        for attr in [port, proto, params.get("cert_usage"), params.get("selector"), params.get("hash_type"), value]:
            if attr == None or attr == "":
                fail("You must provide port, proto, cert_usage, selector, hash_type and a value to create this record type")
    elif rec_type == "DS":
        search_value = str(params.get("key_tag", 0)) + "\t" + str(params.get("algorithm", 0)) + "\t" + str(params.get("hash_type", 0)) + "\t" + value if value else None
        for attr in [params.get("key_tag"), params.get("algorithm"), params.get("hash_type"), value]:
            if attr == None or attr == "":
                fail("You must provide key_tag, algorithm, hash_type and a value to create this record type")
    elif rec_type == "SSHFP":
        search_value = str(params.get("algorithm", 0)) + " " + str(params.get("hash_type", 0)) + " " + (value.upper() if value else "") if value else None
        for attr in [params.get("algorithm"), params.get("hash_type"), value]:
            if attr == None or attr == "":
                fail("You must provide algorithm, hash_type and a value to create this record type")
    elif rec_type == "CAA":
        search_value = None
        for attr in [params.get("flag"), params.get("tag"), value]:
            if attr == None or attr == "":
                fail("You must provide flag, tag and a value to create this record type")
    elif rec_type in ["MX"]:
        if priority == None or (value == None or value == ""):
            fail("You must provide priority and a value to create this record type")

    # Solo + state constraint
    solo = params.get("solo", False)
    state = params.get("state", "present")
    if solo and state == "absent":
        fail("solo=true can only be used with state=present")

    # Get zone ID
    zone = params["zone"].lower()
    res = ctx.run(["curl", "-sS", "-H", "Content-Type: application/json",
                   "https://api.cloudflare.com/client/v4/zones?name=" + zone], mutates=False)
    if res.skipped:
        return {"changed": True, "msg": "would get zones"}
    if res.rc != 0:
        fail("Failed to fetch zones: " + res.stderr)
    # Parse simple JSON manually (expect single-element array with 'id')
    zone_id = None
    lines = res.stdout.strip().split("\n")
    for line in lines:
        line = line.strip()
        if line.startswith('"id"'):
            # Simple extraction: find first string after colon
            parts = line.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip().strip('"')
                zone_id = val
                break

    if not zone_id:
        fail("No zone found with name " + params["zone"])

    # Get DNS records
    query_parts = []
    if rec_type:
        query_parts.append("type=" + rec_type)
    if search_record:
        query_parts.append("name=" + search_record)
    if search_value:
        query_parts.append("content=" + search_value)
    api_path = "/zones/" + zone_id + "/dns_records"
    if query_parts:
        api_path += "?" + "&".join(query_parts)

    res = ctx.run(["curl", "-sS", "-H", "Content-Type: application/json",
                   "https://api.cloudflare.com/client/v4" + api_path], mutates=False)
    if res.skipped:
        return {"changed": True, "msg": "would get records"}
    if res.rc != 0:
        fail("Failed to fetch DNS records: " + res.stderr)

    # Parse records list manually (simple extraction of 'id' and 'content'/'data')
    records = []
    # Expect JSON array structure — parse line by line
    stdout = res.stdout.strip()
    if not stdout.startswith("[") or not stdout.endswith("]"):
        # If response not array, try to detect empty
        if "result" in stdout and "errors" in stdout:
            fail("Cloudflare API error: " + stdout)
        fail("Unexpected Cloudflare response format")

    # Strip outer brackets
    inner = stdout[1:-1].strip()
    if not inner:
        records = []
    else:
        # Naive split on },{ to separate records
        # This is fragile, but the only JSON-safe approach in Starlark
        brace_count = 0
        current = ""
        for c in inner:
            if c == '{':
                brace_count += 1
            elif c == '}':
                brace_count -= 1
            current += c
            if c == '}' and brace_count == 0:
                obj_str = current.strip()
                obj = parse_json_object(obj_str)
                if obj:
                    records.append(obj)
                current = ""
        # Handle single-object case (no comma splitting needed)
        if not records and inner.startswith("{") and inner.endswith("}"):
            obj = parse_json_object(inner)
            if obj:
                records.append(obj)

    # Build desired record
    new_record = None
    ttl = params.get("ttl", 1)

    if rec_type in ["A", "AAAA", "CNAME", "TXT", "NS"]:
        if not value:
            fail("You must provide a non-empty value to create this record type")
        new_record = {
            "type": rec_type,
            "name": search_record,
            "content": value,
            "ttl": int(ttl) if ttl else 1
        }
        if rec_type in ["A", "AAAA", "CNAME"]:
            new_record["proxied"] = params.get("proxied", False)
    elif rec_type == "MX":
        new_record = {
            "type": rec_type,
            "name": search_record,
            "content": value,
            "priority": int(priority),
            "ttl": int(ttl) if ttl else 1
        }
    elif rec_type == "SRV":
        srv_data = {
            "target": value,
            "port": int(port),
            "weight": int(weight),
            "priority": int(priority),
            "name": search_record,
            "proto": proto,
            "service": service
        }
        new_record = {"type": rec_type, "ttl": int(ttl) if ttl else 1, "data": srv_data}
    elif rec_type == "DS":
        ds_data = {
            "key_tag": int(params.get("key_tag")),
            "algorithm": int(params.get("algorithm")),
            "digest_type": int(params.get("hash_type")),
            "digest": value
        }
        new_record = {"type": rec_type, "name": search_record, "data": ds_data, "ttl": int(ttl) if ttl else 1}
    elif rec_type == "SSHFP":
        sshfp_data = {
            "fingerprint": value.upper(),
            "type": int(params.get("hash_type")),
            "algorithm": int(params.get("algorithm")),
        }
        new_record = {"type": rec_type, "name": search_record, "data": sshfp_data, "ttl": int(ttl) if ttl else 1}
    elif rec_type == "TLSA":
        tlsa_data = {
            "usage": int(params.get("cert_usage")),
            "selector": int(params.get("selector")),
            "matching_type": int(params.get("hash_type")),
            "certificate": value
        }
        new_record = {"type": rec_type, "name": search_record, "data": tlsa_data, "ttl": int(ttl) if ttl else 1}
    elif rec_type == "CAA":
        caa_data = {
            "flags": int(params.get("flag")),
            "tag": params.get("tag"),
            "value": value
        }
        new_record = {"type": rec_type, "name": search_record, "data": caa_data, "ttl": int(ttl) if ttl else 1}

    # Determine action
    changed = False
    if state == "present":
        # Solo mode: delete others
        if solo:
            for rec in records:
                if rec.get("name") == search_record and rec.get("type") == rec_type:
                    # Check if this record is NOT the one we want to keep
                    if rec.get("content") != value:
                        changed = True
                        if not ctx.check_mode:
                            delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                  "-H", "Content-Type: application/json",
                                                  "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                 mutates=True)
                            if delete_res.skipped:
                                return {"changed": True, "msg": "would delete conflicting record " + rec.get("id")}
                            if delete_res.rc != 0:
                                fail("Failed to delete record " + rec.get("id") + ": " + delete_res.stderr)
                    elif rec_type == "SRV":
                        # For SRV, compare structured data if available
                        if rec.get("data") and new_record.get("data"):
                            if not compare_data(rec.get("data"), new_record.get("data")):
                                changed = True
                                if not ctx.check_mode:
                                    delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                          "-H", "Content-Type: application/json",
                                                          "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                         mutates=True)
                                    if delete_res.skipped:
                                        return {"changed": True, "msg": "would delete conflicting SRV record"}
                                    if delete_res.rc != 0:
                                        fail("Failed to delete SRV record: " + delete_res.stderr)
                    elif rec_type == "DS":
                        if rec.get("data") and new_record.get("data"):
                            if not compare_data(rec.get("data"), new_record.get("data")):
                                changed = True
                                if not ctx.check_mode:
                                    delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                          "-H", "Content-Type: application/json",
                                                          "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                         mutates=True)
                                    if delete_res.skipped:
                                        return {"changed": True, "msg": "would delete conflicting DS record"}
                                    if delete_res.rc != 0:
                                        fail("Failed to delete DS record: " + delete_res.stderr)
                    elif rec_type == "SSHFP":
                        if rec.get("data") and new_record.get("data"):
                            if not compare_data(rec.get("data"), new_record.get("data")):
                                changed = True
                                if not ctx.check_mode:
                                    delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                          "-H", "Content-Type: application/json",
                                                          "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                         mutates=True)
                                    if delete_res.skipped:
                                        return {"changed": True, "msg": "would delete conflicting SSHFP record"}
                                    if delete_res.rc != 0:
                                        fail("Failed to delete SSHFP record: " + delete_res.stderr)
                    elif rec_type == "TLSA":
                        if rec.get("data") and new_record.get("data"):
                            if not compare_data(rec.get("data"), new_record.get("data")):
                                changed = True
                                if not ctx.check_mode:
                                    delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                          "-H", "Content-Type: application/json",
                                                          "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                         mutates=True)
                                    if delete_res.skipped:
                                        return {"changed": True, "msg": "would delete conflicting TLSA record"}
                                    if delete_res.rc != 0:
                                        fail("Failed to delete TLSA record: " + delete_res.stderr)
                    elif rec_type == "CAA":
                        if rec.get("data") and new_record.get("data"):
                            if not compare_data(rec.get("data"), new_record.get("data")):
                                changed = True
                                if not ctx.check_mode:
                                    delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                                          "-H", "Content-Type: application/json",
                                                          "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                                         mutates=True)
                                    if delete_res.skipped:
                                        return {"changed": True, "msg": "would delete conflicting CAA record"}
                                    if delete_res.rc != 0:
                                        fail("Failed to delete CAA record: " + delete_res.stderr)

        # Check if record already exists and needs update
        record_to_update = None
        for rec in records:
            if rec.get("type") == rec_type and rec.get("name") == search_record:
                # CAA records must be compared fully by data
                if rec_type == "CAA":
                    if rec.get("data") and new_record.get("data"):
                        if compare_data(rec.get("data"), new_record.get("data")):
                            record_to_update = rec
                            break
                # SRV must be compared fully by data
                elif rec_type == "SRV":
                    if rec.get("data") and new_record.get("data"):
                        if compare_data(rec.get("data"), new_record.get("data")):
                            record_to_update = rec
                            break
                elif rec_type == "DS":
                    if rec.get("data") and new_record.get("data"):
                        if compare_data(rec.get("data"), new_record.get("data")):
                            record_to_update = rec
                            break
                elif rec_type == "SSHFP":
                    if rec.get("data") and new_record.get("data"):
                        if compare_data(rec.get("data"), new_record.get("data")):
                            record_to_update = rec
                            break
                elif rec_type == "TLSA":
                    if rec.get("data") and new_record.get("data"):
                        if compare_data(rec.get("data"), new_record.get("data")):
                            record_to_update = rec
                            break
                # Standard record type: compare content and other attributes
                elif rec.get("content") == new_record.get("content"):
                    # Check TTL, proxied, priority
                    if int(rec.get("ttl", 0)) == int(new_record.get("ttl", 1)):
                        if rec_type in ["A", "AAAA", "CNAME"]:
                            if rec.get("proxied") == new_record.get("proxied"):
                                record_to_update = rec
                                break
                        elif rec_type == "MX":
                            if rec.get("priority") == new_record.get("priority"):
                                record_to_update = rec
                                break
                        else:
                            record_to_update = rec
                            break

        if record_to_update:
            # Already exists and matches — no change
            return {"changed": False, "msg": "record already exists with expected configuration"}
        else:
            # Create or update
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would create or update record"}
            else:
                res = ctx.run(["curl", "-sS", "-X", "POST",
                               "-H", "Content-Type: application/json",
                               "-d", json_dump(new_record),
                               "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records"],
                              mutates=True)
                if res.rc != 0:
                    fail("Failed to create record: " + res.stderr)
                return {"changed": True, "msg": "record created or updated"}
    else:  # state == "absent"
        # Delete matching records
        if not records:
            return {"changed": False, "msg": "no matching records to delete"}
        for rec in records:
            changed = True
            if ctx.check_mode:
                continue
            delete_res = ctx.run(["curl", "-sS", "-X", "DELETE",
                                  "-H", "Content-Type: application/json",
                                  "https://api.cloudflare.com/client/v4/zones/" + zone_id + "/dns_records/" + rec.get("id")],
                                 mutates=True)
            if delete_res.skipped:
                continue  # handled above in check_mode
            if delete_res.rc != 0:
                fail("Failed to delete record " + rec.get("id") + ": " + delete_res.stderr)
        return {"changed": True, "msg": "record(s) deleted"}

    return {"changed": False, "msg": "no changes needed"}


# Helper functions (pure Starlark — no external calls, simple parsing)
def parse_json_object(obj_str):
    result = {}
    obj_str = obj_str.strip()
    if not obj_str.startswith("{") or not obj_str.endswith("}"):
        return result
    inner = obj_str[1:-1].strip()
    if not inner:
        return result
    # Split on commas, but skip commas inside quotes or braces
    parts = split_json_parts(inner)
    for part in parts:
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            continue
        k, v = part.split(":", 1)
        k = k.strip().strip('"')
        v = v.strip()
        # Unwrap string values
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        elif v == "true":
            v = True
        elif v == "false":
            v = False
        elif v == "null":
            v = None
        # Try to parse numbers
        elif v.lstrip("-").isdigit():
            v = int(v)
        result[k] = v
    return result


def split_json_parts(s):
    parts = []
    current = ""
    depth = 0
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if not in_string:
            if c == '"':
                in_string = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            elif c == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
                i += 1
                continue
        else:
            if c == '\\' and i + 1 < len(s):
                current += c
                i += 1
                current += s[i]
                i += 1
                continue
            elif c == '"':
                in_string = False
        current += c
        i += 1
    if current.strip():
        parts.append(current.strip())
    return parts


def compare_data(a, b):
    if type(a) != type(b):
        return False
    if type(a) == dict:
        if len(a) != len(b):
            return False
        for k in a:
            if k not in b:
                return False
            if not compare_data(a[k], b[k]):
                return False
        return True
    else:
        return a == b


def json_dump(obj):
    if type(obj) == dict:
        items = []
        for k in obj:
            v = obj[k]
            if type(v) == str:
                items.append('"' + k + '":"' + v + '"')
            elif type(v) == bool:
                items.append('"' + k + '":' + ("true" if v else "false"))
            elif type(v) == int:
                items.append('"' + k + '":' + str(v))
            elif type(v) == dict:
                items.append('"' + k + '":' + json_dump(v))
            else:
                items.append('"' + k + '":null')
        return "{" + ",".join(items) + "}"
    else:
        return str(obj)
