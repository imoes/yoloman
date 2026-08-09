def main(ctx, params):
    cn = params["cn"]
    state = params.get("state", "present")
    cmd = params.get("cmd")
    cmdgroup = params.get("cmdgroup")
    cmdcategory = params.get("cmdcategory")
    deny_cmd = params.get("deny_cmd")
    deny_cmdgroup = params.get("deny_cmdgroup")
    description = params.get("description")
    host = params.get("host")
    hostcategory = params.get("hostcategory")
    hostgroup = params.get("hostgroup")
    runasusercategory = params.get("runasusercategory")
    runasgroupcategory = params.get("runasgroupcategory")
    sudoopt = params.get("sudoopt")
    user = params.get("user")
    usercategory = params.get("usercategory")
    usergroup = params.get("usergroup")
    runasextusers = params.get("runasextusers")
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)

    proto = "http" if ipa_prot == "http" else "https"
    base_url = "%s://%s:%d/ipa/session/json" % (proto, ipa_host, ipa_port)

    if state in ["present", "enabled"]:
        ipaenabledflag = "TRUE"
    else:
        ipaenabledflag = "FALSE"

    def ipa_post(method, item):
        body = '{"method":"%s","params":[null,{"all":true,"cn":"%s"}],"id":0}' % (method, cn)
        if item != None and len(item) > 0:
            inner = []
            for k, v in item.items():
                if v == None:
                    inner.append('"%s": null' % k)
                elif type(v) == "list":
                    inner.append('"%s": %s' % (k, str(v).replace("'", '"')))
                else:
                    inner.append('"%s": "%s"' % (k, str(v)))
            body = body[:-1] + ',"%s": {%s}}' % (method, ", ".join(inner)) + ',"id":0}'
        else:
            body = body[:-1] + '}' + ',"id":0}'

        res = ctx.run([
            "curl", "-s", "-X", "POST", "-H", "Content-Type:application/json",
            "-H", "Accept:application/json",
            "-d", body,
            "--cacert", "/etc/ssl/certs/ca-certificates.crt" if validate_certs else "/dev/null",
            base_url
        ])
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)

        resp = res.stdout.strip()
        if resp == "":
            fail("Empty response from IPA server")

        if '"result":' not in resp:
            fail("IPA response missing result: " + resp[:200])

        start = resp.find('"result":') + len('"result":')
        end = len(resp)
        brace_count = 0
        for i in range(start, end):
            c = resp[i]
            if c == '{':
                brace_count += 1
            elif c == '}':
                brace_count -= 1
                if brace_count == 0:
                    end = i + 1
                    break
        result_str = resp[start:end].strip()
        if result_str == "null":
            return None

        def parse_dict(s):
            d = {}
            s = s.strip()
            if not s.startswith("{") or not s.endswith("}"):
                return d
            inner = s[1:-1].strip()
            if inner == "":
                return d
            parts = []
            level = 0
            cur = ""
            for c in inner:
                if c == '{':
                    level += 1
                elif c == '}':
                    level -= 1
                elif c == ',' and level == 0:
                    parts.append(cur.strip())
                    cur = ""
                    continue
                cur += c
            if cur.strip() != "":
                parts.append(cur.strip())

            for p in parts:
                if ':' not in p:
                    continue
                k, v = p.split(':', 1)
                k = k.strip().strip('"')
                v = v.strip()
                if v.startswith('"') and v.endswith('"'):
                    v = v[1:-1]
                elif v == 'null':
                    v = None
                elif v.startswith('['):
                    v = v[1:-1].strip()
                    if v == "":
                        v = []
                    else:
                        v = [x.strip().strip('"') for x in v.split(',')]
                d[k] = v
            return d

        return parse_dict(result_str)

    ipa_sudorule = ipa_post("sudorule_find", {"cn": cn})

    changed = False

    module_sudorule = {}
    if cmdcategory != None:
        module_sudorule["cmdcategory"] = cmdcategory
    if description != None:
        module_sudorule["description"] = description
    if hostcategory != None:
        module_sudorule["hostcategory"] = hostcategory
    if usercategory != None:
        module_sudorule["usercategory"] = usercategory
    if runasusercategory != None:
        module_sudorule["ipasudorunasusercategory"] = runasusercategory
    if runasgroupcategory != None:
        module_sudorule["ipasudorunasgroupcategory"] = runasgroupcategory
    if ipaenabledflag != None:
        module_sudorule["ipaenabledflag"] = ipaenabledflag

    if state in ["present", "enabled", "disabled"]:
        if ipa_sudorule == None:
            changed = True
            if not ctx.check_mode:
                ipa_post("sudorule_add", module_sudorule)
        else:
            diff = {}
            for k, v in module_sudorule.items():
                cur = ipa_sudorule.get(k)
                if v != cur:
                    diff[k] = v
            if len(diff) > 0:
                changed = True
                if not ctx.check_mode:
                    if "hostcategory" in diff and ipa_sudorule.get("memberhost_host") != None:
                        ipa_post("sudorule_remove_host_host", {"host": ipa_sudorule.get("memberhost_host")})
                    if "hostcategory" in diff and ipa_sudorule.get("memberhost_hostgroup") != None:
                        ipa_post("sudorule_remove_host_hostgroup", {"hostgroup": ipa_sudorule.get("memberhost_hostgroup")})
                    ipa_post("sudorule_mod", module_sudorule)
            ipa_sudorule = ipa_post("sudorule_find", {"cn": cn})

        if cmd != None:
            if ipa_sudorule != None and ipa_sudorule.get("cmdcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"cmdcategory": None})
            if not ctx.check_mode and cmd != None:
                ipa_post("sudorule_add_allow_command", {"sudocmd": cmd})

        if cmdgroup != None:
            if ipa_sudorule != None and ipa_sudorule.get("cmdcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"cmdcategory": None})
            if not ctx.check_mode and cmdgroup != None:
                ipa_post("sudorule_add_allow_command", {"sudocmdgroup": cmdgroup})

        if deny_cmd != None:
            if ipa_sudorule != None and ipa_sudorule.get("cmdcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"cmdcategory": None})
            if not ctx.check_mode and deny_cmd != None:
                ipa_post("sudorule_add_deny_command", {"sudocmd": deny_cmd})

        if deny_cmdgroup != None:
            if ipa_sudorule != None and ipa_sudorule.get("cmdcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"cmdcategory": None})
            if not ctx.check_mode and deny_cmdgroup != None:
                ipa_post("sudorule_add_deny_command", {"sudocmdgroup": deny_cmdgroup})

        if runasusercategory != None:
            if ipa_sudorule != None and ipa_sudorule.get("ipasudorunasusercategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"ipasudorunasusercategory": None})

        if runasgroupcategory != None:
            if ipa_sudorule != None and ipa_sudorule.get("ipasudorunasgroupcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"ipasudorunasgroupcategory": None})

        if host != None:
            if ipa_sudorule != None and ipa_sudorule.get("hostcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"hostcategory": None})
            existing_hosts = ipa_sudorule.get("memberhost_host", [])
            to_add = [h for h in host if h not in existing_hosts]
            to_remove = [h for h in existing_hosts if h not in host]
            if len(to_add) > 0 or len(to_remove) > 0:
                changed = True
                if not ctx.check_mode:
                    if len(to_add) > 0:
                        ipa_post("sudorule_add_host_host", {"host": to_add})
                    if len(to_remove) > 0:
                        ipa_post("sudorule_remove_host_host", {"host": to_remove})

        if hostgroup != None:
            if ipa_sudorule != None and ipa_sudorule.get("hostcategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"hostcategory": None})
            existing_hgs = ipa_sudorule.get("memberhost_hostgroup", [])
            to_add_hgs = [h for h in hostgroup if h not in existing_hgs]
            to_remove_hgs = [h for h in existing_hgs if h not in hostgroup]
            if len(to_add_hgs) > 0 or len(to_remove_hgs) > 0:
                changed = True
                if not ctx.check_mode:
                    if len(to_add_hgs) > 0:
                        ipa_post("sudorule_add_host_hostgroup", {"hostgroup": to_add_hgs})
                    if len(to_remove_hgs) > 0:
                        ipa_post("sudorule_remove_host_hostgroup", {"hostgroup": to_remove_hgs})

        if sudoopt != None:
            existing_opts = ipa_sudorule.get("ipasudoopt", [])
            to_add_opts = [o for o in sudoopt if o not in existing_opts]
            to_remove_opts = [o for o in existing_opts if o not in sudoopt]
            if len(to_add_opts) > 0 or len(to_remove_opts) > 0:
                changed = True
                if not ctx.check_mode:
                    for o in to_remove_opts:
                        ipa_post("sudorule_remove_option_ipasudoopt", {"ipasudoopt": o})
                    for o in to_add_opts:
                        ipa_post("sudorule_add_option_ipasudoopt", {"ipasudoopt": o})

        if runasextusers != None:
            existing_runas = ipa_sudorule.get("ipasudorunasextuser", [])
            to_add_runas = [u for u in runasextusers if u not in existing_runas]
            to_remove_runas = [u for u in existing_runas if u not in runasextusers]
            if len(to_add_runas) > 0 or len(to_remove_runas) > 0:
                changed = True
                if not ctx.check_mode:
                    for u in to_remove_runas:
                        ipa_post("sudorule_remove_runasuser", {"user": u})
                    for u in to_add_runas:
                        ipa_post("sudorule_add_runasuser", {"user": u})

        if user != None:
            if ipa_sudorule != None and ipa_sudorule.get("usercategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"usercategory": None})
            existing_users = ipa_sudorule.get("memberuser_user", [])
            to_add_users = [u for u in user if u not in existing_users]
            to_remove_users = [u for u in existing_users if u not in user]
            if len(to_add_users) > 0 or len(to_remove_users) > 0:
                changed = True
                if not ctx.check_mode:
                    if len(to_add_users) > 0:
                        ipa_post("sudorule_add_user_user", {"user": to_add_users})
                    if len(to_remove_users) > 0:
                        ipa_post("sudorule_remove_user_user", {"user": to_remove_users})

        if usergroup != None:
            if ipa_sudorule != None and ipa_sudorule.get("usercategory") == ["all"]:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudorule_mod", {"usercategory": None})
            existing_ugs = ipa_sudorule.get("memberuser_group", [])
            to_add_ugs = [u for u in usergroup if u not in existing_ugs]
            to_remove_ugs = [u for u in existing_ugs if u not in usergroup]
            if len(to_add_ugs) > 0 or len(to_remove_ugs) > 0:
                changed = True
                if not ctx.check_mode:
                    if len(to_add_ugs) > 0:
                        ipa_post("sudorule_add_user_group", {"group": to_add_ugs})
                    if len(to_remove_ugs) > 0:
                        ipa_post("sudorule_remove_user_group", {"group": to_remove_ugs})

    else:
        if ipa_sudorule != None:
            changed = True
            if not ctx.check_mode:
                ipa_post("sudorule_del", {})

    final_rule = ipa_post("sudorule_find", {"cn": cn}) if not ctx.check_mode else {}
    return {"changed": changed, "msg": "sudorule processed", "data": {"sudorule": final_rule}}
