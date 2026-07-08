def main(ctx, params):
    api_key = params["api_key"]
    domain = params["domain"]
    record = params["record"]
    state = params.get("state", "present")
    ttl = params.get("ttl")
    rec_type = params["type"]
    values = params.get("values", [])

    # Validate required parameters
    if state == "present":
        if ttl == None:
            fail("ttl is required when state is present")
        if len(values) == 0:
            fail("values is required when state is present")

    # Construct the API endpoint
    base_url = "https://dns.api.gandi.net/api/v5/domains/%s/records/%s/%s" % (domain, record, rec_type)

    # Helper function to call the API
    def api_call(path, method="GET", data=None):
        url = "https://dns.api.gandi.net/api/v5" + path
        argv = ["curl", "-s", "-X", method, "-H", "Authorization: apikey " + api_key, "-H", "Content-Type: application/json"]
        if data != None:
            argv.extend(["-d", data])
        argv.append(url)
        res = ctx.run(argv)
        if res.rc != 0:
            fail("API call failed: %s" % res.stderr)
        return res.stdout if res.stdout != "" else "{}"

    # Helper to parse JSON (simple parser for known structure)
    def parse_json_simple(text):
        # Very basic parser for { "key": value, ... } structures
        result = {}
        text = text.strip()
        if not text.startswith("{") or not text.endswith("}"):
            return result
        content = text[1:-1].strip()
        if content == "":
            return result
        # Split by commas not inside quotes (simplified)
        # We assume values are simple strings/numbers and no nested structures
        pairs = []
        current = ""
        in_quote = False
        for i in range(len(content)):
            ch = content[i]
            if ch == '"' and (len(current) == 0 or current[-1] != '\\'):
                in_quote = not in_quote
            if ch == ',' and not in_quote:
                pairs.append(current.strip())
                current = ""
                continue
            current += ch
        if current.strip() != "":
            pairs.append(current.strip())

        for pair in pairs:
            idx = pair.find(":")
            if idx <= 0:
                continue
            key = pair[:idx].strip().strip('"')
            val = pair[idx+1:].strip()
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            elif val.isdigit():
                val = int(val)
            result[key] = val
        return result

    # Get current record state
    res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Authorization: apikey " + api_key, "-H", "Content-Type: application/json", base_url], mutates=False)
    current = res.stdout if res.stdout != "" else "{}"
    current_data = parse_json_simple(current)

    if state == "present":
        # Ensure record exists with correct values
        desired_ttl = int(ttl)
        desired_values = values

        # Check if current matches desired
        if current_data != {}:
            current_ttl = int(current_data.get("ttl", 0))
            current_values = current_data.get("rrset_values", [])
            if type(current_values) == "string":
                current_values = [current_values]
            if current_ttl == desired_ttl and sorted(current_values) == sorted(desired_values):
                return {
                    "changed": False,
                    "msg": "Record %s.%s already exists with correct values" % (record, domain),
                    "record": {
                        "domain": domain,
                        "record": record,
                        "type": rec_type,
                        "ttl": current_ttl,
                        "values": current_values
                    }
                }

        # Build payload
        payload_str = '{"rrset_ttl": %d, "rrset_values": [' % desired_ttl
        for i in range(len(desired_values)):
            if i > 0:
                payload_str += ", "
            payload_str += '"%s"' % str(desired_values[i])
        payload_str += "]}"

        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would update record %s.%s" % (record, domain)
            }

        res = ctx.run([
            "curl", "-s", "-X", "PUT", "-H", "Authorization: apikey " + api_key,
            "-H", "Content-Type: application/json", "-d", payload_str, base_url
        ], mutates=True)
        if res.rc != 0:
            fail("Failed to create/update record: %s" % res.stderr)

        # Return updated record info
        info = ctx.run([
            "curl", "-s", "-X", "GET", "-H", "Authorization: apikey " + api_key,
            "-H", "Content-Type: application/json", base_url
        ], mutates=False)

        data = parse_json_simple(info.stdout if info.stdout != "" else "{}")
        return_values = data.get("rrset_values", [])
        if type(return_values) == "string":
            return_values = [return_values]
        return {
            "changed": True,
            "msg": "Record %s.%s updated" % (record, domain),
            "record": {
                "domain": domain,
                "record": record,
                "type": rec_type,
                "ttl": int(data.get("ttl", 0)),
                "values": return_values
            }
        }

    else:  # state == "absent"
        if current_data == {}:
            return {
                "changed": False,
                "msg": "Record %s.%s does not exist" % (record, domain)
            }

        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would delete record %s.%s" % (record, domain)
            }

        res = ctx.run([
            "curl", "-s", "-X", "DELETE", "-H", "Authorization: apikey " + api_key,
            "-H", "Content-Type: application/json", base_url
        ], mutates=True)
        if res.rc != 0:
            fail("Failed to delete record: %s" % res.stderr)

        return {
            "changed": True,
            "msg": "Record %s.%s deleted" % (record, domain)
        }
