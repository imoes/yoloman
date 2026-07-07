def main(ctx, params):
    # Required
    server_ids = params.get("server_ids")
    if not server_ids:
        fail("server_ids is required and must be a list")
    if not isinstance(server_ids, list):
        fail("server_ids must be a list of server IDs")

    # Optional parameters with defaults
    state = params.get("state", "present")
    wait = params.get("wait", True)
    cpu = params.get("cpu")
    memory = params.get("memory")
    anti_affinity_policy_id = params.get("anti_affinity_policy_id")
    anti_affinity_policy_name = params.get("anti_affinity_policy_name")
    alert_policy_id = params.get("alert_policy_id")
    alert_policy_name = params.get("alert_policy_name")

    # Mutually exclusive checks
    if anti_affinity_policy_id and anti_affinity_policy_name:
        fail("anti_affinity_policy_id and anti_affinity_policy_name are mutually exclusive")
    if alert_policy_id and alert_policy_name:
        fail("alert_policy_id and alert_policy_name are mutually exclusive")

    # 'absent' state does not support cpu/memory modification
    if state == "absent" and (cpu or memory):
        fail("state=absent is not supported with cpu or memory")

    # Environment variables — assumed provided via facts.env
    facts_env = ctx.facts().get("env", {})
    v2_api_token = facts_env.get("CLC_V2_API_TOKEN")
    clc_alias = facts_env.get("CLC_ACCT_ALIAS")
    api_url = facts_env.get("CLC_V2_API_URL", "https://api.ctl.io/v2")

    # Credential validation
    if not v2_api_token or not clc_alias:
        fail("Must set CLC_V2_API_TOKEN and CLC_ACCT_ALIAS environment variables")

    # Helper: run API request via curl
    def api_call(method, url_suffix, body=None):
        full_url = api_url + "/" + url_suffix
        headers = ["-H", "Authorization: Bearer " + v2_api_token,
                   "-H", "Content-Type: application/json"]
        argv = ["curl", "-s", "-X", method] + headers
        if body:
            argv = argv + ["-d", body]
        argv.append(full_url)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        return res.stdout

    # Helper: find ID by name (simple JSON parser)
    def find_id_by_name(json_str, name_key, target_name):
        # naive parsing: split lines and find matching {"name":"xxx","id":"yyy"}
        lines = json_str.split("\n")
        for line in lines:
            if name_key + '":"' in line and target_name in line:
                parts = line.split(",")
                for p in parts:
                    if '"id"' in p:
                        val = p.split(":")[1].strip().strip('"')
                        return val
        return None

    # Helper: get AA policy ID by name
    def get_aa_policy_id_by_name(name):
        res = api_call("GET", "antiAffinityPolicies/" + clc_alias)
        return find_id_by_name(res, "name", name)

    # Helper: get alert policy ID by name
    def get_alert_policy_id_by_name(name):
        res = api_call("GET", "alertPolicies/" + clc_alias)
        return find_id_by_name(res, "name", name)

    # Helper: get server's current AA policy ID
    def get_server_aa_policy(server_id):
        res = api_call("GET", "servers/" + clc_alias + "/" + server_id + "/antiAffinityPolicy")
        return find_id_by_name(res, "id", "")  # second arg unused, just for reuse

    # Helper: get server's alert policy IDs (list)
    def get_server_alert_policies(server_id):
        res = api_call("GET", "servers/" + clc_alias + "/" + server_id + "/alertPolicies")
        ids = []
        parts = res.split('"id"')
        for p in parts[1:]:
            if ':' in p:
                ids.append(p.split(':')[1].strip().strip('"'))
        return ids

    # --- Main processing loop ---
    changed_servers = []
    result_server_ids = []

    for sid in server_ids:
        current_aa_id = get_server_aa_policy(sid)
        current_alert_ids = get_server_alert_policies(sid)

        server_changed = False

        if state == "present":
            # 1. CPU/memory update
            if cpu or memory:
                srv_data = api_call("GET", "servers/" + clc_alias + "/" + sid)
                cpu_cur = None
                mem_cur = None
                for part in srv_data.split(","):
                    if '"cpu"' in part:
                        cpu_cur = int(part.split(":")[1].strip())
                    if '"memory"' in part:
                        mem_cur = int(part.split(":")[1].strip())

                cpu_new = int(cpu) if cpu else cpu_cur
                mem_new = int(memory) if memory else mem_cur

                if cpu_new != cpu_cur or mem_new != mem_cur:
                    server_changed = True
                    if not ctx.check_mode:
                        payload = '[{"op":"set","member":"cpu","value":' + str(cpu_new) + '},{"op":"set","member":"memory","value":' + str(mem_new) + '}]'
                        api_call("PATCH", "servers/" + clc_alias + "/" + sid, payload)

            # 2. Anti-affinity policy update
            aa_target_id = anti_affinity_policy_id or (
                get_aa_policy_id_by_name(anti_affinity_policy_name)
                if anti_affinity_policy_name else None
            )
            if aa_target_id and aa_target_id != current_aa_id:
                server_changed = True
                if not ctx.check_mode:
                    payload = '{"id":"' + aa_target_id + '"}'
                    api_call("PUT", "servers/" + clc_alias + "/" + sid + "/antiAffinityPolicy", payload)

            # 3. Alert policy add
            alert_target_id = alert_policy_id or (
                get_alert_policy_id_by_name(alert_policy_name)
                if alert_policy_name else None
            )
            if alert_target_id and alert_target_id not in current_alert_ids:
                server_changed = True
                if not ctx.check_mode:
                    payload = '{"id":"' + alert_target_id + '"}'
                    api_call("POST", "servers/" + clc_alias + "/" + sid + "/alertPolicies", payload)

        elif state == "absent":
            # Remove AA policy if specified and matches
            aa_target_id = anti_affinity_policy_id or (
                get_aa_policy_id_by_name(anti_affinity_policy_name)
                if anti_affinity_policy_name else None
            )
            if aa_target_id and aa_target_id == current_aa_id:
                server_changed = True
                if not ctx.check_mode:
                    api_call("DELETE", "servers/" + clc_alias + "/" + sid + "/antiAffinityPolicy", "{}")

            # Remove alert policy if specified and exists
            alert_target_id = alert_policy_id or (
                get_alert_policy_id_by_name(alert_policy_name)
                if alert_policy_name else None
            )
            if alert_target_id and alert_target_id in current_alert_ids:
                server_changed = True
                if not ctx.check_mode:
                    api_call("DELETE", "servers/" + clc_alias + "/" + sid + "/alertPolicies/" + alert_target_id)

        if server_changed:
            changed_servers.append(sid)
            result_server_ids.append(sid)

    # Wait (no-op in check_mode)
    if wait and changed_servers and not ctx.check_mode:
        # Simulated wait — real implementation would poll task status
        pass

    # Return result
    changed = len(changed_servers) > 0
    if changed:
        if ctx.check_mode:
            msg = "would modify " + str(len(changed_servers)) + " servers"
        else:
            msg = "modified " + str(len(changed_servers)) + " servers"
    else:
        msg = "no changes required"

    return {
        "changed": changed,
        "msg": msg,
        "data": {
            "server_ids": result_server_ids,
            "servers": []
        }
    }
