def main(ctx, params):
    url = params.get("url", "http://127.0.01:4567")
    check = params.get("check")
    creator = params.get("creator")
    expire = params.get("expire")
    expire_on_resolve = params.get("expire_on_resolve")
    reason = params.get("reason")
    subscription = params["subscription"]
    state = params.get("state", "present")

    base_url = url.rstrip("/") + "/silenced"

    def _get_silences():
        # Build query payload as JSON manually
        payload = '{"subscription": "%s"}' % subscription
        if check != None:
            payload = '{"subscription": "%s", "check": "%s"}' % (subscription, check)
        
        res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", "-d", payload, base_url])
        if res.rc != 0:
            fail("Failed to query silence for " + subscription + ": " + res.stderr)
        
        # Parse response manually
        out = res.stdout.strip()
        if out == "":
            return []
        
        # Handle array case
        if out.startswith("[") and out.endswith("]"):
            out = out[1:-1]
        else:
            out = "[" + out + "]"
        
        # Split by },{ pattern
        parts = out.split("},{")
        silences = []
        
        for part in parts:
            # Ensure braces
            if not part.startswith("{"):
                part = "{" + part
            if not part.endswith("}"):
                part = part + "}"
            
            item = {}
            
            # Extract subscription
            idx = part.find('"subscription"')
            if idx != -1:
                start = part.find('"', idx + 14) + 1
                end = part.find('"', start)
                if end != -1:
                    item["subscription"] = part[start:end]
            
            # Extract check
            idx = part.find('"check"')
            if idx != -1:
                start = part.find('"', idx + 7) + 1
                end = part.find('"', start)
                if end != -1:
                    item["check"] = part[start:end]
            
            # Extract creator
            idx = part.find('"creator"')
            if idx != -1:
                start = part.find('"', idx + 9) + 1
                end = part.find('"', start)
                if end != -1:
                    item["creator"] = part[start:end]
            
            # Extract reason
            idx = part.find('"reason"')
            if idx != -1:
                start = part.find('"', idx + 8) + 1
                end = part.find('"', start)
                if end != -1:
                    item["reason"] = part[start:end]
            
            # Extract expire (numeric)
            idx = part.find('"expire"')
            if idx != -1:
                start = part.find(":", idx + 8)
                if start != -1:
                    start += 1
                    num_str = ""
                    while start < len(part) and part[start] in "0123456789-":
                        num_str += part[start]
                        start += 1
                    if num_str != "":
                        item["expire"] = int(num_str)
            
            # Extract expire_on_resolve
            idx = part.find('"expire_on_resolve"')
            if idx != -1:
                start = part.find(":", idx + 19)
                if start != -1:
                    start += 1
                    remaining = part[start:start+5].strip()
                    if remaining.startswith("true"):
                        item["expire_on_resolve"] = True
                    elif remaining.startswith("false"):
                        item["expire_on_resolve"] = False
            
            silences.append(item)
        
        return silences

    def _clear_silence():
        payload = '{"subscription": "%s"}' % subscription
        if check != None:
            payload = '{"subscription": "%s", "check": "%s"}' % (subscription, check)
        
        # Clear endpoint
        res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", payload, url.rstrip("/") + "/silenced/clear"], mutates=True)
        if res.rc != 0:
            fail("Failed to clear silence for " + subscription + ": " + res.stderr)
        return True

    # Check current state
    silences = _get_silences()
    found = False

    for item in silences:
        sub_match = item.get("subscription", "") == subscription
        check_match = check == None or item.get("check", "") == check
        creator_match = creator == None or item.get("creator", "") == creator
        reason_match = reason == None or item.get("reason", "") == reason
        expire_match = expire == None or item.get("expire") == expire
        expire_resolve_match = expire_on_resolve == None or item.get("expire_on_resolve") == expire_on_resolve

        if sub_match and check_match and creator_match and reason_match and expire_match and expire_resolve_match:
            found = True
            break

    if state == "absent":
        if not found:
            return {"changed": False, "msg": "Silence entry not found, nothing to clear"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would clear silence for " + subscription}
        if not _clear_silence():
            fail("Failed to clear silence for " + subscription)
        return {"changed": True, "msg": "cleared silence for " + subscription}

    # state == "present"
    if found:
        return {"changed": False, "msg": "Silence entry already exists"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would create silence for " + subscription}

    # Create silence
    payload = '{"subscription": "%s"}' % subscription
    if check != None:
        payload = payload[:-1] + ', "check": "%s"}' % check
    if creator != None:
        payload = payload[:-1] + ', "creator": "%s"}' % creator
    if reason != None:
        payload = payload[:-1] + ', "reason": "%s"}' % reason
    if expire != None:
        payload = payload[:-1] + ', "expire": %d}' % expire
    if expire_on_resolve != None:
        val = "true" if expire_on_resolve else "false"
        payload = payload[:-1] + ', "expire_on_resolve": %s}' % val

    res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", payload, base_url], mutates=True)
    if res.rc != 201:
        fail("Failed to create silence for " + subscription + ": " + res.stderr)
    return {"changed": True, "msg": "created silence for " + subscription}
