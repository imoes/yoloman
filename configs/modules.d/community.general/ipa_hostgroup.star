def main(ctx, params):
    # Extract parameters
    name = params["cn"]
    state = params.get("state", "present")
    host = params.get("host")  # list or None
    hostgroup = params.get("hostgroup")  # list or None
    append = params.get("append", False)
    
    # Build IPA API base URL and headers
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass", "")
    ipa_timeout = params.get("ipa_timeout", 10)
    
    # Construct base URL
    base_url = "%s://%s:%d/ipa/session/json" % (ipa_prot, ipa_host, ipa_port)
    
    # Helper to perform IPA JSON POST requests
    def ipa_post(method, item=None, name=None):
        payload = {"method": method, "params": [[name] if name else [], item if item else {}]}
        res = ctx.run(
            ["curl", "-s", "-k", "--max-time", str(ipa_timeout)],
            input_data=payload,
            headers={
                "Content-Type": "application/json",
                "Referer": "%s://%s:%d/ipa/ui/" % (ipa_prot, ipa_host, ipa_port)
            },
            mutates=True
        )
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        result = res.stdout
        # Extract result from IPA response using string operations
        if '"result"' not in result:
            fail("IPA response missing 'result': " + result[:500])
        start = result.find('"result":{')
        if start == -1:
            fail("Could not parse IPA result")
        brace_count = 0
        i = start + len('"result":{')
        while i < len(result) and result[i] != '}':
            if result[i] == '{':
                brace_count += 1
            elif result[i] == '}':
                if brace_count == 0:
                    break
                brace_count -= 1
            i += 1
        result_json = result[start + len('"result":{'): i + 1]
        return dict_from_json(result_json)
    
    # Helper to parse minimal JSON dict
    def dict_from_json(s):
        d = {}
        s = s.strip().strip('{}')
        if not s:
            return d
        items = []
        depth = 0
        current = ""
        for c in s:
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            elif c == ',' and depth == 0:
                items.append(current.strip())
                current = ""
                continue
            current += c
        if current.strip():
            items.append(current.strip())
        for item in items:
            if ':' not in item:
                continue
            key, value = item.split(':', 1)
            key = key.strip().strip('"')
            value = value.strip()
            if value == 'true':
                value = True
            elif value == 'false':
                value = False
            elif value.isdigit() or (value.startswith('-') and value[1:].isdigit()):
                value = int(value)
            elif value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            d[key] = value
        return d
    
    # Helper to perform hostgroup_find
    def hostgroup_find(cn):
        item = {"all": True, "cn": cn}
        return ipa_post("hostgroup_find", item)
    
    # Helper to perform hostgroup_add
    def hostgroup_add(cn, item):
        return ipa_post("hostgroup_add", item, cn)
    
    # Helper to perform hostgroup_mod
    def hostgroup_mod(cn, item):
        return ipa_post("hostgroup_mod", item, cn)
    
    # Helper to perform hostgroup_del
    def hostgroup_del(cn):
        return ipa_post("hostgroup_del", {}, cn)
    
    # Helper to add members
    def hostgroup_add_member(cn, item):
        return ipa_post("hostgroup_add_member", item, cn)
    
    # Helper to remove members
    def hostgroup_remove_member(cn, item):
        return ipa_post("hostgroup_remove_member", item, cn)
    
    # Login using curl directly (no helper needed since ctx.run handles it)
    login_res = ctx.run(
        ["curl", "-s", "-k", "--max-time", str(ipa_timeout), "-d", '{"method": "login", "params": [[""], {"user": "' + ipa_user + '", "password": "' + ipa_pass + '"}]}'],
        mutates=False
    )
    if login_res.rc != 0 or '"summary"' not in login_res.stdout:
        fail("Failed to login to FreeIPA")
    
    # Find current hostgroup
    ipa_hostgroup = hostgroup_find(name)
    # ipa_hostgroup may be empty dict if not found
    found = len(ipa_hostgroup) > 0
    
    # Prepare module desired state data
    module_hostgroup = {}
    if params.get("description") != None:
        module_hostgroup["description"] = params["description"]
    
    changed = False
    msg = ""
    
    if state == "present":
        if not found:
            # Create hostgroup
            changed = True
            if not ctx.check_mode:
                res = hostgroup_add(name, module_hostgroup)
                if res.get("error"):
                    fail("Failed to create hostgroup: " + str(res.get("error")))
            msg = "Created hostgroup %s" % name
        else:
            # Modify if needed
            current = {}
            for k in module_hostgroup.keys():
                current[k] = ipa_hostgroup.get(k)
            diff = {}
            for k in module_hostgroup.keys():
                if k not in current or current[k] != module_hostgroup[k]:
                    diff[k] = module_hostgroup[k]
            
            if len(diff) > 0:
                changed = True
                if not ctx.check_mode:
                    res = hostgroup_mod(name, diff)
                    if res.get("error"):
                        fail("Failed to modify hostgroup: " + str(res.get("error")))
                msg = "Updated hostgroup %s" % name
            else:
                msg = "Hostgroup %s already exists and is up to date" % name
        
        # Handle host membership
        if host != None:
            current_hosts = ipa_hostgroup.get("member_host", [])
            if type(current_hosts) == "string":
                current_hosts = [current_hosts]
            desired_hosts = [h.lower() for h in host]
            
            to_add = []
            to_remove = []
            
            if append:
                for h in desired_hosts:
                    if h not in current_hosts:
                        to_add.append(h)
            else:
                for h in current_hosts:
                    if h not in desired_hosts:
                        to_remove.append(h)
                for h in desired_hosts:
                    if h not in current_hosts:
                        to_add.append(h)
            
            if len(to_add) > 0:
                changed = True
                if not ctx.check_mode:
                    for h in to_add:
                        res = hostgroup_add_member(name, {"host": [h]})
                        if res.get("error"):
                            fail("Failed to add host %s: %s" % (h, str(res.get("error"))))
            if len(to_remove) > 0 and not ctx.check_mode:
                changed = True
                for h in to_remove:
                    res = hostgroup_remove_member(name, {"host": [h]})
                    if res.get("error"):
                        fail("Failed to remove host %s: %s" % (h, str(res.get("error"))))
        
        # Handle hostgroup membership
        if hostgroup != None:
            current_hostgroups = ipa_hostgroup.get("member_hostgroup", [])
            if type(current_hostgroups) == "string":
                current_hostgroups = [current_hostgroups]
            desired_hostgroups = [hg.lower() for hg in hostgroup]
            
            to_add = []
            to_remove = []
            
            if append:
                for hg in desired_hostgroups:
                    if hg not in current_hostgroups:
                        to_add.append(hg)
            else:
                for hg in current_hostgroups:
                    if hg not in desired_hostgroups:
                        to_remove.append(hg)
                for hg in desired_hostgroups:
                    if hg not in current_hostgroups:
                        to_add.append(hg)
            
            if len(to_add) > 0:
                changed = True
                if not ctx.check_mode:
                    for hg in to_add:
                        res = hostgroup_add_member(name, {"hostgroup": [hg]})
                        if res.get("error"):
                            fail("Failed to add hostgroup %s: %s" % (hg, str(res.get("error"))))
            if len(to_remove) > 0 and not ctx.check_mode:
                changed = True
                for hg in to_remove:
                    res = hostgroup_remove_member(name, {"hostgroup": [hg]})
                    if res.get("error"):
                        fail("Failed to remove hostgroup %s: %s" % (hg, str(res.get("error"))))
    
    elif state == "absent":
        if found:
            changed = True
            if not ctx.check_mode:
                res = hostgroup_del(name)
                if res.get("error"):
                    fail("Failed to delete hostgroup: " + str(res.get("error")))
            msg = "Deleted hostgroup %s" % name
    
    elif state in ("enabled", "disabled"):
        fail("State '%s' is not supported for hostgroups" % state)
    
    # Return final hostgroup info (always fetch after changes)
    final = hostgroup_find(name)
    if type(final) != "dict":
        final = {}
    
    return {"changed": changed, "msg": msg, "data": final}
