def main(ctx, params):
    # Required: auth_token (or env PACKET_API_TOKEN) and project_id
    # Selector: id, name, or description (exactly one)
    # State: present (create if missing) or absent (delete if exists)

    # --- Validation ---
    auth_token = params.get("auth_token")
    if auth_token == None:
        fail("if Packet API token is not in environment variable PACKET_API_TOKEN, the auth_token parameter is required")

    project_id = params.get("project_id")
    if project_id == None:
        fail("project_id must be specified")

    selectors = 0
    if params.get("id") != None:
        selectors += 1
    if params.get("name") != None:
        selectors += 1
    if params.get("description") != None:
        selectors += 1
    if selectors != 1:
        fail("exactly one of id, name, or description must be specified")

    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")

    if params.get("plan") != None and params.get("plan") not in ["storage_1", "storage_2"]:
        fail("plan must be 'storage_1' or 'storage_2'")
    plan = params.get("plan", "storage_1")

    if params.get("billing_cycle") != None and params.get("billing_cycle") not in ["hourly", "monthly"]:
        fail("billing_cycle must be 'hourly' or 'monthly'")
    billing_cycle = params.get("billing_cycle", "hourly")

    # --- Build selector function (id, name, or description) ---
    def match_volume(vol):
        if params.get("id") != None:
            return vol.get("id") == params.get("id")
        elif params.get("name") != None:
            return vol.get("name") == params.get("name")
        else:  # description
            return vol.get("description") == params.get("description")

    # --- Get volumes via API (projects/{id}/storage) ---
    api_path = "projects/" + project_id + "/storage"
    res = ctx.run(["curl", "-sS", "-X", "GET",
                   "-H", "Accept: application/json",
                   "-H", "Authorization: packet " + auth_token,
                   "https://api.packet.com/v1/" + api_path])
    if res.rc != 0:
        fail("failed to list volumes: " + res.stderr)

    # Manual JSON parsing without stdlib json
    stdout = res.stdout.strip()
    if not (stdout.startswith("{") and stdout.endswith("}")):
        fail("invalid JSON from volume list: " + stdout)

    # Extract volumes array manually
    # Find "volumes" key and parse the array
    volumes_str = ""
    idx = stdout.find('"volumes"')
    if idx == -1:
        fail("missing 'volumes' key in JSON response")
    # Move past '"volumes" : ['
    idx = stdout.find('[', idx)
    if idx == -1:
        fail("missing array in 'volumes' response")
    # Find matching ]
    depth = 0
    end_idx = idx
    while end_idx < len(stdout):
        c = stdout[end_idx]
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                break
        end_idx += 1
    if depth != 0:
        fail("malformed array in 'volumes' response")
    volumes_str = stdout[idx:end_idx+1]

    # Parse individual volume objects
    all_volumes = []
    # Split by '}, {' but handle nested structures
    # Instead, use simple scanning to split JSON objects
    def extract_json_objects(s):
        objs = []
        depth = 0
        start = -1
        i = 0
        while i < len(s):
            c = s[i]
            if c == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0 and start != -1:
                    objs.append(s[start:i+1])
                    start = -1
            i += 1
        return objs

    volume_strs = extract_json_objects(volumes_str)
    for vs in volume_strs:
        vol = parse_volume_json(vs)
        if vol != None:
            all_volumes.append(vol)

    matching_volumes = [v for v in all_volumes if match_volume(v)]

    # --- State: present ---
    if state == "present":
        if len(matching_volumes) == 0:
            # Create volume
            # Required fields for creation: description, size, plan, facility, locked, billing_cycle
            for req in ["description", "size", "facility"]:
                if params.get(req) == None:
                    fail(req + " must be specified for new volume")

            locked = params.get("locked", False)
            if type(locked) == "string":
                locked = locked == "true"

            snapshot_policy = params.get("snapshot_policy")
            payload = {
                "description": params.get("description"),
                "size": params.get("size"),
                "plan": plan,
                "facility": params.get("facility"),
                "locked": locked,
                "billing_cycle": billing_cycle,
            }
            if snapshot_policy != None:
                payload["snapshot_policies"] = snapshot_policy

            payload_str = build_json_string(payload)
            res = ctx.run(["curl", "-sS", "-X", "POST",
                           "-H", "Content-Type: application/json",
                           "-H", "Accept: application/json",
                           "-H", "Authorization: packet " + auth_token,
                           "-d", payload_str,
                           "https://api.packet.com/v1/" + api_path], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would create volume"}

            if res.rc != 0:
                fail("failed to create volume: " + res.stderr)

            created = parse_volume_json(res.stdout.strip())
            if created == None:
                fail("failed to parse JSON from volume create")

            return {"changed": True,
                    "id": created.get("id"),
                    "name": created.get("name"),
                    "description": created.get("description")}

        else:
            # Already exists — return first match
            vol = matching_volumes[0]
            return {"changed": False,
                    "id": vol.get("id"),
                    "name": vol.get("name"),
                    "description": vol.get("description")}

    # --- State: absent ---
    if state == "absent":
        if len(matching_volumes) == 0:
            return {"changed": False}
        if len(matching_volumes) > 1:
            fail("more than one volume matches in absent state: " + str(matching_volumes))

        vol_id = matching_volumes[0].get("id")
        res = ctx.run(["curl", "-sS", "-X", "DELETE",
                       "-H", "Accept: application/json",
                       "-H", "Authorization: packet " + auth_token,
                       "https://api.packet.com/v1/storage/" + vol_id], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete volume"}

        if res.rc != 0:
            fail("failed to delete volume " + vol_id + ": " + res.stderr)

        return {"changed": True,
                "id": vol_id,
                "name": matching_volumes[0].get("name"),
                "description": matching_volumes[0].get("description")}


def parse_volume_json(s):
    # Simple parser for a single volume object
    s = s.strip()
    if not (s.startswith("{") and s.endswith("}")):
        return None

    # Extract key-value pairs manually
    result = {}
    inner = s[1:-1].strip()
    if inner == "":
        return result

    # Tokenize by finding quoted strings
    i = 0
    while i < len(inner):
        # Skip whitespace and commas
        while i < len(inner) and (inner[i] == ' ' or inner[i] == ','):
            i += 1
        if i >= len(inner):
            break

        # Expect key
        if inner[i] != '"':
            return None
        i += 1
        key_end = inner.find('"', i)
        if key_end == -1:
            return None
        key = inner[i:key_end]
        i = key_end + 1

        # Skip whitespace and colon
        while i < len(inner) and inner[i] == ' ':
            i += 1
        if i >= len(inner) or inner[i] != ':':
            return None
        i += 1
        while i < len(inner) and inner[i] == ' ':
            i += 1

        # Parse value
        if i >= len(inner):
            return None

        c = inner[i]
        if c == '"':
            i += 1
            value_end = inner.find('"', i)
            if value_end == -1:
                return None
            value = inner[i:value_end]
            i = value_end + 1
        elif c == 't':
            value = True
            i += 4  # true
        elif c == 'f':
            value = False
            i += 5  # false
        elif c.isdigit() or (c == '-' and i+1 < len(inner) and inner[i+1].isdigit()):
            j = i
            if c == '-':
                j += 1
            while j < len(inner) and inner[j].isdigit():
                j += 1
            value = int(inner[i:j])
            i = j
        elif c == 'n':
            value = None
            i += 4  # null
        else:
            return None

        result[key] = value

    return result


def build_json_string(d):
    # Build a minimal JSON string for payload
    items = []
    for k in sorted(d.keys()):
        v = d.get(k)
        if type(v) == "string":
            items.append('"%s":"%s"' % (k, v))
        elif type(v) == "bool":
            items.append('"%s":%s' % (k, "true" if v else "false"))
        elif v == None:
            items.append('"%s":null' % k)
        elif type(v) == "int":
            items.append('"%s":%d' % (k, v))
        elif type(v) == "dict":
            items.append('"%s":%s' % (k, build_json_string(v)))
        else:
            items.append('"%s":"%s"' % (k, str(v)))
    return "{" + ",".join(items) + "}"
