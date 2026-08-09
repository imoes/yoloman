def main(ctx, params):
    name = params["name"]
    description = params["description"]
    organization_id = params["organization_id"]
    state = params.get("state", "present")
    region = params["region"]
    tags = params.get("tags", [])
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    wait = params.get("wait", False)
    wait_timeout = params.get("wait_timeout", 300)
    wait_sleep_time = params.get("wait_sleep_time", 3)
    
    if state not in ("present", "absent"):
        fail("state must be 'present' or 'absent'")
    
    api_path = "/lb/v1/regions/" + region + "/lbs"
    
    # Helper to make HTTP requests
    def http_request(method, path, data=None):
        url = api_url + path
        headers_list = []
        headers_list.extend(["Authorization", "Bearer " + api_token])
        headers_list.extend(["Content-Type", "application/json"])
        body = ""
        if data != None:
            items = []
            for k, v in data.items():
                if type(v) == "list":
                    quoted = []
                    for x in v:
                        quoted.append('"%s"' % str(x).replace('"', '\\"'))
                    items.append('"%s": [%s]' % (k, ",".join(quoted)))
                else:
                    sval = str(v).replace('"', '\\"')
                    items.append('"%s": "%s"' % (k, sval))
            body = "{" + ",".join(items) + "}"
        args = ["curl", "-s", "-w", "\\n%{http_code}", "-X", method, "--location", url]
        for h in headers_list:
            args.extend(["-H", h])
        if body != "":
            args.extend(["--data", body])
        res = ctx.run(args, mutates=(method != "GET"))
        if res.rc != 0:
            fail("HTTP request failed: " + res.stderr)
        output = res.stdout.strip()
        parts = output.rsplit("\n", 1)
        if len(parts) == 2:
            status = int(parts[1])
            body_resp = parts[0]
        else:
            status = 0
            body_resp = output
        return status, body_resp
    
    # Fetch list of lbs
    status, lbs_json_str = http_request("GET", api_path)
    lbs = []
    if status == 200:
        content = lbs_json_str
        if '"lbs":' in content:
            start_idx = content.find('"lbs":') + 6
            bracket_idx = content.find("[", start_idx)
            if bracket_idx >= 0:
                depth = 0
                end_idx = bracket_idx
                for i in range(bracket_idx, len(content)):
                    if content[i] == "[":
                        depth += 1
                    elif content[i] == "]":
                        depth -= 1
                        if depth == 0:
                            end_idx = i + 1
                            break
                arr_str = content[bracket_idx:end_idx]
                obj_strs = []
                current = ""
                depth_obj = 0
                for ch in arr_str:
                    if ch == "{":
                        depth_obj += 1
                        current += ch
                    elif ch == "}":
                        depth_obj -= 1
                        current += ch
                        if depth_obj == 0:
                            obj_strs.append(current)
                            current = ""
                    elif ch == "," and depth_obj == 0:
                        continue
                    else:
                        current += ch
                for obj in obj_strs:
                    if obj.strip() == "":
                        continue
                    lb = {}
                    for field in ["id", "name", "description", "status", "organization_id", "region"]:
                        if ('"' + field + '":') in obj:
                            s = obj.find('"' + field + '":') + len(field) + 4
                            q = obj.find('"', s)
                            if q > s:
                                lb[field] = obj[s:q]
                    if '"tags":' in obj:
                        lb["tags"] = []
                        tag_start = obj.find('"tags":') + 7
                        if tag_start > 7 and obj[tag_start] == "[":
                            tag_end = obj.find("]", tag_start)
                            if tag_end > tag_start:
                                tags_str = obj[tag_start+1:tag_end]
                                for t in tags_str.split(","):
                                    t = t.strip().strip('"')
                                    if t != "":
                                        lb["tags"].append(t)
                    lbs.append(lb)
    
    # Lookup by name
    lbs_by_name = {}
    for lb in lbs:
        lbs_by_name[lb.get("name", "")] = lb
    
    if state == "present":
        if name not in lbs_by_name:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would create load-balancer"}
            data = {
                "organization_id": organization_id,
                "name": name,
                "description": description,
                "tags": tags
            }
            status, resp = http_request("POST", api_path, data=data)
            if status != 200 and status != 201:
                fail("Failed to create load-balancer: HTTP " + str(status) + " " + resp)
            created_lb = {}
            content = resp
            for field in ["id", "name", "description", "status", "organization_id", "region"]:
                if ('"' + field + '":') in content:
                    s = content.find('"' + field + '":') + len(field) + 4
                    q = content.find('"', s)
                    if q > s:
                        created_lb[field] = content[s:q]
            if '"tags":' in content:
                created_lb["tags"] = []
                tag_start = content.find('"tags":') + 7
                if tag_start > 7 and content[tag_start] == "[":
                    tag_end = content.find("]", tag_start)
                    if tag_end > tag_start:
                        tags_str = content[tag_start+1:tag_end]
                        for t in tags_str.split(","):
                            t = t.strip().strip('"')
                            if t != "":
                                created_lb["tags"].append(t)
            result_lb = created_lb
            
            if wait:
                elapsed = 0
                while elapsed < wait_timeout:
                    st, st_resp = http_request("GET", api_path + "/" + created_lb.get("id", ""))
                    if st == 200:
                        st_content = st_resp
                        if '"status":' in st_content:
                            s = st_content.find('"status":') + 9
                            q = st_content.find('"', s)
                            if q > s and st_content[s:q] == "ready":
                                break
                    ctx.run(["sleep", str(wait_sleep_time)])
                    elapsed += wait_sleep_time
            return {"changed": True, "msg": "load-balancer created", "data": result_lb}
        
        else:
            target = lbs_by_name[name]
            should_update = False
            update_data = {}
            if target.get("name") != name:
                should_update = True
                update_data["name"] = name
            if target.get("description") != description:
                should_update = True
                update_data["description"] = description
            target_tags = target.get("tags", [])
            new_tags = tags
            if sorted(target_tags) != sorted(new_tags):
                should_update = True
                update_data["tags"] = tags
            
            if not should_update:
                return {"changed": False, "msg": "load-balancer already correct", "data": target}
            
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would update load-balancer"}
            
            patch_path = api_path + "/" + target.get("id", "")
            status, resp = http_request("PATCH", patch_path, data=update_data)
            if status != 200:
                fail("Failed to update load-balancer: HTTP " + str(status) + " " + resp)
            
            updated_lb = {}
            content = resp
            for field in ["id", "name", "description", "status", "organization_id", "region"]:
                if ('"' + field + '":') in content:
                    s = content.find('"' + field + '":') + len(field) + 4
                    q = content.find('"', s)
                    if q > s:
                        updated_lb[field] = content[s:q]
            if '"tags":' in content:
                updated_lb["tags"] = []
                tag_start = content.find('"tags":') + 7
                if tag_start > 7 and content[tag_start] == "[":
                    tag_end = content.find("]", tag_start)
                    if tag_end > tag_start:
                        tags_str = content[tag_start+1:tag_end]
                        for t in tags_str.split(","):
                            t = t.strip().strip('"')
                            if t != "":
                                updated_lb["tags"].append(t)
            
            if wait:
                elapsed = 0
                while elapsed < wait_timeout:
                    st, st_resp = http_request("GET", api_path + "/" + target.get("id", ""))
                    if st == 200:
                        st_content = st_resp
                        if '"status":' in st_content:
                            s = st_content.find('"status":') + 9
                            q = st_content.find('"', s)
                            if q > s and st_content[s:q] == "ready":
                                break
                    ctx.run(["sleep", str(wait_sleep_time)])
                    elapsed += wait_sleep_time
            
            return {"changed": True, "msg": "load-balancer updated", "data": updated_lb}
    
    else:
        if name not in lbs_by_name:
            return {"changed": False, "msg": "load-balancer already absent"}
        
        target = lbs_by_name[name]
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete load-balancer"}
        
        delete_path = api_path + "/" + target.get("id", "")
        status, resp = http_request("DELETE", delete_path)
        if status != 204:
            fail("Failed to delete load-balancer: HTTP " + str(status) + " " + resp)
        
        if wait:
            elapsed = 0
            while elapsed < wait_timeout:
                st, st_resp = http_request("GET", api_path + "/" + target.get("id", ""))
                if st == 404:
                    break
                ctx.run(["sleep", str(wait_sleep_time)])
                elapsed += wait_sleep_time
        
        return {"changed": True, "msg": "load-balancer deleted"}
