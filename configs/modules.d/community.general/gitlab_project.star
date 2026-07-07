def main(ctx, params):
    name = params["name"]
    path = params.get("path", name.replace(" ", "_"))
    state = params.get("state", "present")

    api_url = params.get("api_url", "")
    api_token = params.get("api_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    ca_path = params.get("ca_path")

    def build_curl_args():
        headers = ["-H", "Content-Type: application/json"]
        if api_token:
            headers.extend(["-H", "PRIVATE-TOKEN: " + api_token])
        elif api_oauth_token:
            headers.extend(["-H", "Authorization: Bearer " + api_oauth_token])
        elif api_job_token:
            headers.extend(["-H", "JOB-TOKEN: " + api_job_token])
        return headers

    def curl_api(method, endpoint, data=None, ok_codes=[0, 200, 201, 204]):
        headers = build_curl_args()
        url = api_url.rstrip("/") + "/api/v4/" + endpoint.lstrip("/")
        argv = ["curl", "-s", "-f", "-X", method] + headers
        if data:
            argv.extend(["-d", data])
        if api_username and api_password:
            argv.extend(["--user", api_username + ":" + api_password])
        if not api_url.startswith("https") or not ca_path:
            argv.append("-k")
        if ca_path:
            argv.extend(["--cacert", ca_path])
        argv.append(url)
        return ctx.run(argv, mutates=(method != "GET"), ok_codes=ok_codes)

    def find_namespace():
        group_id = params.get("group")
        username = params.get("username")

        if group_id:
            res = curl_api("GET", "/groups?search=" + group_id)
            if res.rc != 0:
                fail("Failed to search group " + group_id + ": " + res.stderr)
            groups = []
            if len(res.stdout) > 0:
                for item in res.stdout.split("}"):
                    if len(item.strip()) == 0:
                        continue
                    item = item.strip()
                    if item.startswith("["):
                        item = item[1:]
                    if item == "":
                        continue
                    if '"id"' in item and '"full_path"' in item:
                        gid = ""
                        gpath = ""
                        for part in item.split(","):
                            if '"id"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    gid = parts2[1].strip().replace('"', '').replace(' ', '')
                            if '"full_path"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    gpath = parts2[1].strip().replace('"', '').replace(' ', '')
                        if gid != "":
                            groups.append({"id": int(gid), "full_path": gpath})
            if len(groups) == 0:
                fail("Group not found: " + group_id)
            return {"id": groups[0]["id"], "full_path": groups[0]["full_path"], "type": "group"}

        if username:
            res = curl_api("GET", "/users?username=" + username)
            if res.rc != 0:
                fail("Failed to search user " + username + ": " + res.stderr)
            users = []
            if len(res.stdout) > 0:
                for item in res.stdout.split("}"):
                    if len(item.strip()) == 0:
                        continue
                    item = item.strip()
                    if item.startswith("["):
                        item = item[1:]
                    if '"id"' in item and '"username"' in item:
                        uid = ""
                        uname = ""
                        for part in item.split(","):
                            if '"id"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    uid = parts2[1].strip().replace('"', '').replace(' ', '')
                            if '"username"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    uname = parts2[1].strip().replace('"', '').replace(' ', '')
                        if uid != "":
                            users.append({"id": int(uid), "username": uname})
            if len(users) == 0:
                fail("User not found: " + username)
            return {"id": users[0]["id"], "full_path": users[0]["username"], "type": "user"}

        res = curl_api("GET", "/user")
        if res.rc != 0:
            fail("Failed to get current user: " + res.stderr)
        if len(res.stdout) > 0:
            for item in res.stdout.split("}"):
                if len(item.strip()) == 0:
                    continue
                item = item.strip()
                if '"id"' in item and '"username"' in item:
                    uid = ""
                    uname = ""
                    for part in item.split(","):
                        if '"id"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                uid = parts2[1].strip().replace('"', '').replace(' ', '')
                        if '"username"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                uname = parts2[1].strip().replace('"', '').replace(' ', '')
                    if uid != "":
                        return {"id": int(uid), "full_path": uname, "type": "user"}
        fail("Failed to determine current user namespace")

    def project_exists(namespace, project_path):
        encoded_path = namespace["full_path"].replace("/", "%2F")
        endpoint = "/projects/" + encoded_path + "%2F" + project_path
        res = curl_api("GET", endpoint)
        if res.rc == 0:
            if len(res.stdout) > 0:
                for item in res.stdout.split("}"):
                    if len(item.strip()) == 0:
                        continue
                    item = item.strip()
                    if '"id"' in item:
                        pid = ""
                        for part in item.split(","):
                            if '"id"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    pid = parts2[1].strip().replace('"', '').replace(' ', '')
                        if pid != "":
                            return {"id": int(pid)}
            return None
        elif "404" in res.stderr:
            return None
        fail("Failed to check project existence: " + res.stderr)

    def create_project(namespace, project_path, options):
        payload_parts = []
        payload_parts.append('"name": "' + name + '"')
        payload_parts.append('"path": "' + project_path + '"')
        payload_parts.append('"namespace_id": "' + str(namespace["id"]) + '"')
        if options["description"]:
            payload_parts.append('"description": "' + options["description"] + '"')
        payload_parts.append('"issues_enabled": "' + str(options["issues_enabled"]).lower() + '"')
        payload_parts.append('"merge_requests_enabled": "' + str(options["merge_requests_enabled"]).lower() + '"')
        payload_parts.append('"merge_method": "' + options["merge_method"] + '"')
        payload_parts.append('"wiki_enabled": "' + str(options["wiki_enabled"]).lower() + '"')
        payload_parts.append('"snippets_enabled": "' + str(options["snippets_enabled"]).lower() + '"')
        payload_parts.append('"visibility": "' + options["visibility"] + '"')
        payload_parts.append('"lfs_enabled": "' + str(options["lfs_enabled"]).lower() + '"')

        if options["default_branch"] and options["initialize_with_readme"]:
            payload_parts.append('"default_branch": "' + options["default_branch"] + '"')
            payload_parts.append('"initialize_with_readme": "true"')

        if options["import_url"]:
            payload_parts.append('"import_url": "' + options["import_url"] + '"')

        optional_bools = [
            "allow_merge_on_skipped_pipeline",
            "only_allow_merge_if_all_discussions_are_resolved",
            "only_allow_merge_if_pipeline_succeeds",
            "packages_enabled",
            "remove_source_branch_after_merge",
        ]
        for key in optional_bools:
            if options.get(key) != None:
                payload_parts.append('"' + key + '": "' + str(options[key]).lower() + '"')

        if options.get("squash_option"):
            payload_parts.append('"squash_option": "' + options["squash_option"] + '"')
        if options.get("ci_config_path"):
            payload_parts.append('"ci_config_path": "' + options["ci_config_path"] + '"')
        if options.get("shared_runners_enabled") != None:
            payload_parts.append('"shared_runners_enabled": "' + str(options["shared_runners_enabled"]).lower() + '"')

        access_levels = [
            "builds_access_level",
            "forking_access_level",
            "container_registry_access_level",
            "releases_access_level",
            "environments_access_level",
            "feature_flags_access_level",
            "infrastructure_access_level",
            "monitor_access_level",
        ]
        for key in access_levels:
            if options.get(key):
                payload_parts.append('"' + key + '": "' + options[key] + '"')

        if options.get("topics"):
            topics_list = ",".join(options["topics"])
            payload_parts.append('"tag_list": "' + topics_list + '"')

        payload_json = "{" + ", ".join(payload_parts) + "}"

        res = curl_api("POST", "/projects", payload_json, ok_codes=[0, 201])
        if res.rc != 0:
            fail("Failed to create project: " + res.stderr)
        if len(res.stdout) > 0:
            for item in res.stdout.split("}"):
                if len(item.strip()) == 0:
                    continue
                item = item.strip()
                if '"id"' in item:
                    pid = ""
                    for part in item.split(","):
                        if '"id"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                pid = parts2[1].strip().replace('"', '').replace(' ', '')
                    if pid != "":
                        return {"id": int(pid)}
        return {"id": 0}

    def update_project(project_id, options):
        res = curl_api("GET", "/projects/" + str(project_id))
        if res.rc != 0:
            fail("Failed to get project details: " + res.stderr)

        current = {}
        if len(res.stdout) > 0:
            for item in res.stdout.split("}"):
                if len(item.strip()) == 0:
                    continue
                item = item.strip()
                if '"id"' in item:
                    for part in item.split(","):
                        if '"id"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                pid = parts2[1].strip().replace('"', '').replace(' ', '')
                                current["id"] = int(pid)
                        if '"description"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                current["description"] = parts2[1].strip().replace('"', '')
                        if '"issues_enabled"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                val = parts2[1].strip().replace('"', '')
                                current["issues_enabled"] = val == "true"
                        if '"merge_requests_enabled"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                val = parts2[1].strip().replace('"', '')
                                current["merge_requests_enabled"] = val == "true"
                        if '"merge_method"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                current["merge_method"] = parts2[1].strip().replace('"', '')
                        if '"wiki_enabled"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                val = parts2[1].strip().replace('"', '')
                                current["wiki_enabled"] = val == "true"
                        if '"snippets_enabled"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                val = parts2[1].strip().replace('"', '')
                                current["snippets_enabled"] = val == "true"
                        if '"visibility"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                current["visibility"] = parts2[1].strip().replace('"', '')
                        if '"lfs_enabled"' in part:
                            parts2 = part.split(":")
                            if len(parts2) > 1:
                                val = parts2[1].strip().replace('"', '')
                                current["lfs_enabled"] = val == "true"

        changes = {}
        update_fields = [
            "description", "issues_enabled", "merge_requests_enabled", "merge_method",
            "wiki_enabled", "snippets_enabled", "visibility", "lfs_enabled",
            "default_branch", "allow_merge_on_skipped_pipeline",
            "only_allow_merge_if_all_discussions_are_resolved",
            "only_allow_merge_if_pipeline_succeeds", "packages_enabled",
            "remove_source_branch_after_merge", "squash_option",
            "ci_config_path", "shared_runners_enabled"
        ]

        for field in update_fields:
            if options.get(field) != None and field in current:
                new_val = options[field]
                if isinstance(new_val, bool):
                    new_val = str(new_val).lower()
                if str(current[field]) != str(new_val):
                    changes[field] = new_val

        access_levels = [
            "builds_access_level",
            "forking_access_level",
            "container_registry_access_level",
            "releases_access_level",
            "environments_access_level",
            "feature_flags_access_level",
            "infrastructure_access_level",
            "monitor_access_level",
        ]
        for key in access_levels:
            if options.get(key) and str(current.get(key)) != options[key]:
                changes[key] = options[key]

        if options.get("topics") and current.get("tag_list"):
            current_topics = current["tag_list"].split(",")
            new_topics = options["topics"]
            if sorted(current_topics) != sorted(new_topics):
                changes["tag_list"] = ",".join(new_topics)

        if changes:
            payload_parts = []
            for k, v in changes.items():
                if isinstance(v, bool):
                    payload_parts.append('"' + k + '": "' + str(v).lower() + '"')
                else:
                    payload_parts.append('"' + k + '": "' + str(v) + '"')
            payload_json = "{" + ", ".join(payload_parts) + "}"

            res = curl_api("PUT", "/projects/" + str(project_id), payload_json)
            if res.rc != 0:
                fail("Failed to update project: " + res.stderr)
            if len(res.stdout) > 0:
                for item in res.stdout.split("}"):
                    if len(item.strip()) == 0:
                        continue
                    item = item.strip()
                    if '"id"' in item:
                        pid = ""
                        for part in item.split(","):
                            if '"id"' in part:
                                parts2 = part.split(":")
                                if len(parts2) > 1:
                                    pid = parts2[1].strip().replace('"', '').replace(' ', '')
                        if pid != "":
                            return {"id": int(pid)}, True
        return {}, False

    def delete_project(project_id):
        res = curl_api("DELETE", "/projects/" + str(project_id), ok_codes=[0, 202, 204])
        if res.rc != 0:
            fail("Failed to delete project: " + res.stderr)

    namespace = find_namespace()

    if state == "absent":
        project = project_exists(namespace, path)
        if project:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would delete project " + name}
            delete_project(project["id"])
            return {"changed": True, "msg": "Successfully deleted project " + name}
        return {"changed": False, "msg": "Project already absent"}

    options = {
        "description": params.get("description"),
        "issues_enabled": params.get("issues_enabled", True),
        "merge_requests_enabled": params.get("merge_requests_enabled", True),
        "merge_method": params.get("merge_method", "merge"),
        "wiki_enabled": params.get("wiki_enabled", True),
        "snippets_enabled": params.get("snippets_enabled", True),
        "visibility": params.get("visibility", "private"),
        "lfs_enabled": params.get("lfs_enabled", False),
        "default_branch": params.get("default_branch"),
        "import_url": params.get("import_url"),
        "allow_merge_on_skipped_pipeline": params.get("allow_merge_on_skipped_pipeline"),
        "only_allow_merge_if_all_discussions_are_resolved": params.get("only_allow_merge_if_all_discussions_are_resolved"),
        "only_allow_merge_if_pipeline_succeeds": params.get("only_allow_merge_if_pipeline_succeeds"),
        "packages_enabled": params.get("packages_enabled"),
        "remove_source_branch_after_merge": params.get("remove_source_branch_after_merge"),
        "squash_option": params.get("squash_option"),
        "ci_config_path": params.get("ci_config_path"),
        "shared_runners_enabled": params.get("shared_runners_enabled"),
        "avatar_path": params.get("avatar_path"),
        "initialize_with_readme": params.get("initialize_with_readme", False),
        "builds_access_level": params.get("builds_access_level"),
        "forking_access_level": params.get("forking_access_level"),
        "container_registry_access_level": params.get("container_registry_access_level"),
        "releases_access_level": params.get("releases_access_level"),
        "environments_access_level": params.get("environments_access_level"),
        "feature_flags_access_level": params.get("feature_flags_access_level"),
        "infrastructure_access_level": params.get("infrastructure_access_level"),
        "monitor_access_level": params.get("monitor_access_level"),
        "topics": params.get("topics", []),
    }

    if options["default_branch"] and not options["initialize_with_readme"]:
        fail("Param default_branch requires param initialize_with_readme set to true")

    project = project_exists(namespace, path)

    if not project:
        if ctx.check_mode:
            return {"changed": True, "msg": "Would create project " + name}
        project = create_project(namespace, path, options)
        return {"changed": True, "msg": "Successfully created project " + name, "data": project}

    updated_project, changed = update_project(project["id"], options)
    if changed:
        if ctx.check_mode:
            return {"changed": True, "msg": "Would update project " + name}
        return {"changed": True, "msg": "Successfully updated project " + name, "data": updated_project}

    return {"changed": False, "msg": "Project up to date", "data": project}
