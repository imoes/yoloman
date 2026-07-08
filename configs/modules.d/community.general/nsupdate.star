def main(ctx, params):
    server = params["server"]
    port = params.get("port", 53)
    key_name = params.get("key_name")
    key_secret = params.get("key_secret")
    key_algorithm = params.get("key_algorithm", "hmac-md5")
    zone = params.get("zone")
    record = params["record"]
    rtype = params.get("type", "A").upper()
    ttl = params.get("ttl", 3600)
    values = params.get("value")
    state = params.get("state", "present")
    protocol = params.get("protocol", "tcp").upper()

    # Validate required parameters
    if state == "present" and values == None:
        fail("value is required when state is present")

    # Normalize zone and record (must end with dot)
    if zone != None:
        if zone[-1] != ".":
            zone = zone + "."
    else:
        # Zone lookup via nslookup
        if record[-1] != ".":
            fail("record must be absolute when omitting zone parameter")
        # Simple zone lookup via nslookup
        parts = record.split(".")
        for i in range(len(parts)):
            candidate = ".".join(parts[i:]) + "."
            res = ctx.run(["nslookup", "-type=SOA", candidate, server], mutates=False)
            if res.rc == 0 and "auth" in res.stdout.lower():
                zone = candidate
                break
        if zone == None:
            fail("could not determine zone automatically")

    # Build fqdn
    if record[-1] != ".":
        fqdn = record + "." + zone
    else:
        fqdn = record

    # Handle TXT escaping if needed
    if rtype == "TXT" and values != None:
        processed_values = []
        for entry in values:
            if entry.startswith('"') and entry.endswith('"'):
                processed_values.append(entry)
            else:
                processed_values.append('"' + entry + '"')
        values = processed_values

    # Check current record state via nslookup
    def query_record():
        res = ctx.run(["nslookup", "-type=" + rtype, fqdn, server], mutates=False)
        if res.rc != 0:
            return []
        output = res.stdout.strip()
        records = []
        # Parse nslookup output: look for 'Name:', 'Address:', or 'canonical name'
        lines = output.split("\n")
        for line in lines:
            line = line.strip()
            if line.startswith(fqdn):
                parts = line.split()
                if len(parts) >= 4 and parts[1] == rtype:
                    records.append(parts[3])
                elif parts[1] == "CNAME":
                    records.append(parts[3].rstrip("."))
        # Fallback: extract from 'Address:' lines for simple A records
        if len(records) == 0 and rtype == "A":
            for line in lines:
                line = line.strip()
                if line.startswith("Address:"):
                    addr = line.split(":", 1)[1].strip()
                    # Skip IPv6 lines if looking for A
                    if addr.find(":") == -1:
                        records.append(addr)
        return records

    # nsupdate command helper
    def nsupdate_command(records):
        # Build records list for nsupdate
        if state == "absent" or len(records) == 0:
            add_cmd = ""
            del_cmd = "delete " + fqdn + " " + rtype
        else:
            add_lines = []
            for val in values:
                add_lines.append("add " + fqdn + " " + str(ttl) + " " + rtype + " " + str(val))
            add_cmd = "\n".join(add_lines)
            del_cmd = "delete " + fqdn + " " + rtype

        # TSIG auth
        auth = ""
        if key_name != None:
            if key_algorithm == "hmac-md5":
                algo = "HMAC-MD5.SIG-ALG.REG.INT"
            else:
                algo = key_algorithm
            auth = "server " + server + " " + str(port) + " " + algo + " " + key_name + " " + key_secret

        # Assemble nsupdate script
        script_lines = []
        if auth != "":
            script_lines.append(auth)
        script_lines.append("server " + server)
        script_lines.append("port " + str(port))
        if protocol == "TCP":
            script_lines.append("proto tcp")
        else:
            script_lines.append("proto udp")
        script_lines.append("zone " + zone)
        script_lines.append(del_cmd)
        if add_cmd != "":
            script_lines.append(add_cmd)
        script_lines.append("send")
        return "\n".join(script_lines)

    # Execute nsupdate via script
    def run_nsupdate(records):
        script = nsupdate_command(records)
        script_path = "/tmp/nsupdate_script_" + str(hash(script))[-6:]
        ctx.file_write(script_path, script)
        res = ctx.run(["nsupdate", script_path], mutates=True)
        ctx.run(["rm", "-f", script_path])
        return res

    # Check mode first
    if ctx.check_mode:
        current = query_record()
        changed = False
        if state == "absent":
            changed = len(current) > 0
        else:
            changed = set(current) != set(values)
        msg = "would " + ("remove" if state == "absent" else "update/create")
        return {"changed": changed, "msg": msg, "data": {
            "record": record,
            "zone": zone,
            "type": rtype,
            "ttl": ttl,
            "value": values
        }}

    # Actual state
    current = query_record()

    if state == "absent":
        if len(current) == 0:
            return {"changed": False, "msg": "record does not exist", "data": {
                "record": record, "zone": zone, "type": rtype, "ttl": ttl, "value": values
            }}
        res = run_nsupdate(current)
        if res.rc != 0:
            fail("failed to remove record: " + res.stderr)
        return {"changed": True, "msg": "record removed", "data": {
            "record": record, "zone": zone, "type": rtype, "ttl": ttl, "value": values
        }}

    # State == present
    if set(current) == set(values):
        # Check TTL as well (simplified: assume unchanged if values match)
        return {"changed": False, "msg": "record already present with correct values", "data": {
            "record": record, "zone": zone, "type": rtype, "ttl": ttl, "value": values
        }}

    res = run_nsupdate(current)
    if res.rc != 0:
        fail("failed to update record: " + res.stderr)
    return {"changed": True, "msg": "record updated", "data": {
        "record": record, "zone": zone, "type": rtype, "ttl": ttl, "value": values
    }}
