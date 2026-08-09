def main(ctx, params):
    api_key = params["api_key"]
    name = params["name"]
    state = params["state"]
    ttl = params.get("ttl", 0)
    force = params.get("force", False)

    # Validate zone name length
    if len(name) > 250:
        fail("Zone name must be less than 250 characters in length.")

    # Helper to construct JSON manually (no json module)
    def json_escape(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    def build_json(obj):
        if type(obj) == "dict":
            items = []
            for k in sorted(obj.keys()):
                items.append('"%s": %s' % (json_escape(str(k)), build_json(obj[k])))
            return "{" + ", ".join(items) + "}"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int":
            return str(obj)
        elif type(obj) == "string":
            return '"%s"' % json_escape(obj)
        elif obj == None:
            return "null"
        else:
            fail("Unsupported JSON type: " + type(obj))

    # Get list of zones
    payload = {"api_key": api_key}
    payload_json = build_json(payload)
    res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                   "-d", payload_json,
                   "https://api.memset.com/v1/dns.zone_list"],
                  ok_codes=[0])
    if res.rc != 0:
        fail("Failed to retrieve zone list: " + res.stderr)

    # Parse zone list (simple manual parsing)
    zones = []
    zone = None
    in_zone = False
    lines = res.stdout.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line == "{" or line.startswith("{"):
            zone = {}
            in_zone = True
        elif in_zone and line.startswith('"nickname"'):
            idx = line.find(":")
            if idx != -1:
                nick = line[idx+1:].strip().strip('"')
                zone["nickname"] = nick
        elif in_zone and line.startswith('"id"'):
            idx = line.find(":")
            if idx != -1:
                zone["id"] = line[idx+1:].strip().strip('"')
        elif in_zone and line.startswith('"ttl"'):
            idx = line.find(":")
            if idx != -1:
                zone["ttl"] = int(line[idx+1:].strip().strip(','))
        elif in_zone and line.startswith('"domains"'):
            zone["domains"] = []
        elif in_zone and line.startswith('"records"'):
            zone["records"] = []
        elif in_zone and (line == "}" or line == "},"):
            in_zone = False
            if len(zone) > 0:
                zones.append(zone)
            zone = {}
        elif in_zone and line.startswith('"id":'):
            idx = line.find(":")
            zone["id"] = line[idx+1:].strip().strip(',')
        elif in_zone and line.startswith('"nickname":'):
            idx = line.find(":")
            zone["nickname"] = line[idx+1:].strip().strip(',')
        elif in_zone and line.startswith('"ttl":'):
            idx = line.find(":")
            zone["ttl"] = int(line[idx+1:].strip().strip(','))
        i = i + 1

    # Search for zone
    zone_exists, zone_id, zone = False, "", None
    for z in zones:
        if z.get("nickname") == name:
            zone_exists = True
            zone_id = z.get("id", "")
            zone = z
            break

    if state == "present":
        if not zone_exists:
            # Create new zone
            if ctx.check_mode:
                return {"changed": True, "msg": "would create zone " + name}
            payload = {
                "api_key": api_key,
                "nickname": name,
                "ttl": ttl
            }
            payload_json = build_json(payload)
            res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                           "-d", payload_json,
                           "https://api.memset.com/v1/dns.zone_create"],
                          ok_codes=[0])
            if res.rc != 0:
                fail("Failed to create zone: " + res.stderr)
            # Fetch zone list to get updated info
            payload = {"api_key": api_key}
            payload_json = build_json(payload)
            res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                           "-d", payload_json,
                           "https://api.memset.com/v1/dns.zone_list"],
                          ok_codes=[0])
            if res.rc != 0:
                fail("Failed to retrieve zone list after creation: " + res.stderr)

            # Re-parse zones
            zones = []
            zone = None
            in_zone = False
            lines = res.stdout.split("\n")
            i = 0
            while i < len(lines):
                line = lines[i].strip()
                if line == "{" or line.startswith("{"):
                    zone = {}
                    in_zone = True
                elif in_zone and line.startswith('"nickname"'):
                    idx = line.find(":")
                    if idx != -1:
                        nick = line[idx+1:].strip().strip('"')
                        zone["nickname"] = nick
                elif in_zone and line.startswith('"id"'):
                    idx = line.find(":")
                    if idx != -1:
                        zone["id"] = line[idx+1:].strip().strip('"')
                elif in_zone and line.startswith('"ttl"'):
                    idx = line.find(":")
                    if idx != -1:
                        zone["ttl"] = int(line[idx+1:].strip().strip(','))
                elif in_zone and line.startswith('"domains"'):
                    zone["domains"] = []
                elif in_zone and line.startswith('"records"'):
                    zone["records"] = []
                elif in_zone and (line == "}" or line == "},"):
                    in_zone = False
                    if len(zone) > 0:
                        zones.append(zone)
                    zone = {}
                elif in_zone and line.startswith('"id":'):
                    idx = line.find(":")
                    zone["id"] = line[idx+1:].strip().strip(',')
                elif in_zone and line.startswith('"nickname":'):
                    idx = line.find(":")
                    zone["nickname"] = line[idx+1:].strip().strip(',')
                elif in_zone and line.startswith('"ttl":'):
                    idx = line.find(":")
                    zone["ttl"] = int(line[idx+1:].strip().strip(','))
                i = i + 1

            for z in zones:
                if z.get("nickname") == name:
                    zone = z
                    break
            memset_api = {
                "id": zone.get("id", ""),
                "nickname": zone.get("nickname", ""),
                "ttl": zone.get("ttl", 0),
                "domains": zone.get("domains", []),
                "records": zone.get("records", [])
            }
            return {"changed": True, "msg": "zone %s created" % name, "data": {"memset_api": memset_api}}
        else:
            # Check if TTL needs update
            current_ttl = zone.get("ttl", 0)
            if current_ttl == ttl:
                return {"changed": False, "msg": "zone %s already exists with correct TTL" % name}
            else:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update TTL for zone " + name}
                payload = {
                    "api_key": api_key,
                    "id": zone_id,
                    "ttl": ttl
                }
                payload_json = build_json(payload)
                res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                               "-d", payload_json,
                               "https://api.memset.com/v1/dns.zone_update"],
                              ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to update zone TTL: " + res.stderr)
                # Fetch updated zone info
                payload = {"api_key": api_key}
                payload_json = build_json(payload)
                res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                               "-d", payload_json,
                               "https://api.memset.com/v1/dns.zone_info"],
                              ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to retrieve zone info after update: " + res.stderr)
                # Manual parse for zone_info
                zone_info = {}
                lines = res.stdout.split("\n")
                for line in lines:
                    line = line.strip()
                    if line.startswith('"id":'):
                        zone_info["id"] = line[6:].strip().strip(',')
                    elif line.startswith('"nickname":'):
                        zone_info["nickname"] = line[12:].strip().strip(',')
                    elif line.startswith('"ttl":'):
                        zone_info["ttl"] = int(line[7:].strip().strip(','))
                    elif line.startswith('"domains": ['):
                        zone_info["domains"] = []
                    elif line.startswith('"records": ['):
                        zone_info["records"] = []
                memset_api = {
                    "id": zone_info.get("id", ""),
                    "nickname": zone_info.get("nickname", ""),
                    "ttl": zone_info.get("ttl", 0),
                    "domains": zone_info.get("domains", []),
                    "records": zone_info.get("records", [])
                }
                return {"changed": True, "msg": "zone %s TTL updated" % name, "data": {"memset_api": memset_api}}

    elif state == "absent":
        if not zone_exists:
            return {"changed": False, "msg": "zone %s does not exist" % name}

        # Check if zone contains domains/records and force is not set
        domain_count = len(zone.get("domains", []))
        record_count = len(zone.get("records", []))
        if (domain_count > 0 or record_count > 0) and not force:
            fail("Zone contains domains or records and force was not used.")

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete zone " + name}

        payload = {
            "api_key": api_key,
            "id": zone_id
        }
        payload_json = build_json(payload)
        res = ctx.run(["curl", "-sS", "-X", "POST", "-H", "Content-Type: application/json",
                       "-d", payload_json,
                       "https://api.memset.com/v1/dns.zone_delete"],
                      ok_codes=[0])
        if res.rc != 0:
            fail("Failed to delete zone: " + res.stderr)
        return {"changed": True, "msg": "zone %s deleted" % name}
