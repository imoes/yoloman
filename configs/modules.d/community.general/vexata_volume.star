def main(ctx, params):
    array = params["array"]
    name = params["name"]
    user = params.get("user")
    password = params.get("password")
    state = params.get("state", "present")
    size = params.get("size")
    validate_certs = params.get("validate_certs", False)

    if user == None:
        user = ctx.getenv("VEXATA_USER")
    if password == None:
        password = ctx.getenv("VEXATA_PASSWORD")

    if user == None or password == None:
        fail("user and password are required (or VEXATA_USER/VEXATA_PASSWORD env vars)")

    if state == "present" and size == None:
        fail("size is required when state is present")

    def size_to_MiB(size_str):
        if size_str == None:
            return 0
        size_str = size_str.strip().upper()
        if size_str.endswith("M"):
            return int(size_str[:-1])
        elif size_str.endswith("G"):
            return int(size_str[:-1]) * 1024
        elif size_str.endswith("T"):
            return int(size_str[:-1]) * 1024 * 1024
        else:
            fail("Invalid size unit. Use M, G, or T (e.g., 2T)")

    base_url = "https://" + array + "/api/v1"
    headers = ["-H", "Content-Type: application/json", "-u", user + ":" + password]
    if validate_certs == False:
        headers += ["-k"]

    res = ctx.run(["curl", "-s", "-X", "GET"] + headers + [base_url + "/volumes"], mutates=False)
    if res.rc != 0:
        fail("Failed to list volumes: " + res.stderr)

    raw = res.stdout.strip()
    if raw == "":
        raw = "[]"
    if not (raw.startswith("[") and raw.endswith("]")):
        fail("Unexpected API response format")
    inner = raw[1:-1].strip()
    if inner == "":
        volumes = []
    else:
        parts = []
        depth = 0
        current = ""
        for ch in inner:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
            if ch == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
            else:
                current += ch
        parts.append(current.strip())
        volumes = []
        for p in parts:
            if p == "":
                continue
            name_field = '"name"'
            id_field = '"id"'
            size_field = '"volSize"'

            def extract_str(line, key):
                idx = line.find(key)
                if idx == -1:
                    return ""
                start = line.find('"', idx + len(key))
                if start == -1:
                    return ""
                start += 1
                end = line.find('"', start)
                if end == -1:
                    return ""
                return line[start:end]

            def extract_int(line, key):
                idx = line.find(key)
                if idx == -1:
                    return 0
                start = line.find(':', idx + len(key))
                if start == -1:
                    return 0
                while start < len(line) and line[start] in " \t":
                    start += 1
                end = start
                while end < len(line) and line[end].isdigit():
                    end += 1
                if end == start:
                    return 0
                return int(line[start:end])

            volumes.append({
                "name": extract_str(p, name_field),
                "id": extract_str(p, id_field),
                "volSize": extract_int(p, size_field)
            })

    volume = None
    for v in volumes:
        if v.get("name") == name:
            volume = v
            break

    def volume_json(size_MiB):
        return '{"name":"%s","description":"Ansible volume","volSize":%d}' % (name, size_MiB)

    if state == "present":
        if volume == None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create volume " + name}
            size_MiB = size_to_MiB(size)
            res = ctx.run(["curl", "-s", "-X", "POST"] + headers + ["-d", volume_json(size_MiB), base_url + "/volumes"], mutates=True)
            if res.rc != 0:
                fail("Failed to create volume: " + res.stderr)
            return {"changed": True, "msg": "created volume " + name}
        else:
            size_MiB = size_to_MiB(size)
            if size_MiB <= volume.get("volSize", 0):
                return {"changed": False, "msg": "volume " + name + " already at desired size"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would expand volume " + name}
            res = ctx.run(["curl", "-s", "-X", "PUT"] + headers + ["-d", volume_json(size_MiB), base_url + "/volumes/" + volume["id"]], mutates=True)
            if res.rc != 0:
                fail("Failed to expand volume: " + res.stderr)
            return {"changed": True, "msg": "expanded volume " + name}

    elif state == "absent":
        if volume != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete volume " + name}
            res = ctx.run(["curl", "-s", "-X", "DELETE"] + headers + [base_url + "/volumes/" + volume["id"]], mutates=True)
            if res.rc != 0:
                fail("Failed to delete volume: " + res.stderr)
            return {"changed": True, "msg": "deleted volume " + name}
        else:
            return {"changed": False, "msg": "volume " + name + " does not exist"}

    fail("unsupported state: " + state)
