def main(ctx, params):
    api_key = params["api_key"]
    app_key = params["app_key"]
    api_host = params.get("api_host", "https://api.datadoghq.com")
    state = params["state"]
    monitor_id = params.get("id")
    name = params["name"]
    query = params.get("query")
    monitor_type = params.get("type")
    notification_message = params.get("notification_message")
    escalation_message = params.get("escalation_message")
    silenced = params.get("silenced")
    notify_no_data = params.get("notify_no_data", False)
    no_data_timeframe = params.get("no_data_timeframe")
    timeout_h = params.get("timeout_h")
    renotify_interval = params.get("renotify_interval")
    notify_audit = params.get("notify_audit", False)
    locked = params.get("locked", False)
    require_full_window = params.get("require_full_window")
    new_host_delay = params.get("new_host_delay")
    evaluation_delay = params.get("evaluation_delay")
    include_tags = params.get("include_tags", True)
    priority = params.get("priority")
    notification_preset_name = params.get("notification_preset_name")
    renotify_occurrences = params.get("renotify_occurrences")
    renotify_statuses = params.get("renotify_statuses")
    tags = params.get("tags")
    thresholds = params.get("thresholds")

    def _fix_template_vars(msg):
        if msg == None:
            return None
        return msg.replace("[[", "{{").replace("]]", "}}")

    def _parse_json_obj(s):
        s = s.strip()
        if not (s.startswith("{") and s.endswith("}")):
            fail("Invalid JSON object")
        s = s[1:-1].strip()
        if s == "":
            return {}
        result = {}
        depth = 0
        current_key = ""
        current_val = ""
        in_key = True
        in_string = False
        escape = False
        i = 0
        while i < len(s):
            c = s[i]
            if escape:
                if in_string:
                    current_val += c
                else:
                    current_key += c
                escape = False
            elif c == "\\" and in_string:
                escape = True
            elif c == '"' and not escape:
                in_string = not in_string
            elif not in_string:
                if c == ":" and depth == 0:
                    in_key = False
                elif c == "," and depth == 0:
                    result[current_key.strip()] = _parse_value(current_val.strip())
                    in_key = True
                    current_key = ""
                    current_val = ""
                elif c == "{" or c == "[":
                    depth += 1
                    if in_key:
                        current_key += c
                    else:
                        current_val += c
                elif c == "}" or c == "]":
                    depth -= 1
                    if in_key:
                        current_key += c
                    else:
                        current_val += c
                else:
                    if in_key:
                        current_key += c
                    else:
                        current_val += c
            else:
                if in_key:
                    current_key += c
                else:
                    current_val += c
            i += 1
        if current_key.strip() != "":
            result[current_key.strip()] = _parse_value(current_val.strip())
        return result

    def _parse_value(v):
        v = v.strip()
        if v.startswith('"') and v.endswith('"'):
            return v[1:-1]
        if v == "true":
            return True
        if v == "false":
            return False
        if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
            return int(v)
        return v

    def _json_dumps(obj):
        if obj == None:
            return "null"
        if type(obj) == "bool":
            return "true" if obj else "false"
        if type(obj) == "int" or type(obj) == "float":
            return str(obj)
        if type(obj) == "string":
            return '"' + obj.replace("\\", "\\\\").replace('"', '\\"') + '"'
        if type(obj) == "list":
            items = [_json_dumps(i) for i in obj]
            return "[" + ", ".join(items) + "]"
        if type(obj) == "dict":
            parts = []
            for k in sorted(obj.keys()):
                parts.append('"' + str(k) + '": ' + _json_dumps(obj[k]))
            return "{ " + ", ".join(parts) + " }"
        return '"' + str(obj) + '"'

    def _build_options():
        options = {}
        if silenced != None:
            options["silenced"] = silenced
        options["notify_no_data"] = notify_no_data
        if no_data_timeframe != None:
            options["no_data_timeframe"] = no_data_timeframe
        if timeout_h != None:
            options["timeout_h"] = timeout_h
        if renotify_interval != None:
            options["renotify_interval"] = renotify_interval
        if escalation_message != None:
            options["escalation_message"] = _fix_template_vars(escalation_message)
        options["notify_audit"] = notify_audit
        options["locked"] = locked
        if require_full_window != None:
            options["require_full_window"] = require_full_window
        if new_host_delay != None:
            options["new_host_delay"] = new_host_delay
        if evaluation_delay != None:
            options["evaluation_delay"] = evaluation_delay
        options["include_tags"] = include_tags
        if notification_preset_name != None:
            options["notification_preset_name"] = notification_preset_name
        if renotify_occurrences != None:
            options["renotify_occurrences"] = renotify_occurrences
        if renotify_statuses != None:
            options["renotify_statuses"] = renotify_statuses
        if thresholds != None:
            options["thresholds"] = thresholds
        return options

    def _get_monitor():
        if monitor_id != None:
            res = ctx.run([
                "curl", "-s", "-X", "GET",
                api_host.rstrip("/") + "/api/v1/monitor/" + str(monitor_id),
                "-H", "DD-API-KEY: " + api_key,
                "-H", "DD-APPLICATION-KEY: " + app_key,
            ])
            if res.rc != 0:
                fail("Failed to retrieve monitor by id " + str(monitor_id) + ": " + res.stderr)
            data = res.stdout
            if data.strip() == "":
                return None
            return _json_loads(data)
        else:
            res = ctx.run([
                "curl", "-s", "-X", "GET",
                api_host.rstrip("/") + "/api/v1/monitor",
                "-H", "DD-API-KEY: " + api_key,
                "-H", "DD-APPLICATION-KEY: " + app_key,
            ])
            if res.rc != 0:
                fail("Failed to list monitors: " + res.stderr)
            monitors_str = res.stdout
            if monitors_str.strip() == "":
                return None
            monitors = _json_loads(monitors_str)
            for monitor in monitors:
                if type(monitor) == "dict" and monitor.get("name") == _fix_template_vars(name):
                    return monitor
            return None

    def _json_loads(s):
        # Basic JSON parser for arrays and objects
        s = s.strip()
        if s.startswith("["):
            return _parse_json_array(s)
        if s.startswith("{"):
            return _parse_json_obj(s)
        fail("Unexpected JSON structure")

    def _parse_json_array(s):
        s = s.strip()
        if not (s.startswith("[") and s.endswith("]")):
            fail("Invalid JSON array")
        s = s[1:-1].strip()
        if s == "":
            return []
        result = []
        depth = 0
        current = ""
        in_string = False
        escape = False
        i = 0
        while i < len(s):
            c = s[i]
            if escape:
                current += c
                escape = False
            elif c == "\\" and in_string:
                escape = True
            elif c == '"' and not escape:
                in_string = not in_string
                current += c
            elif not in_string:
                if c == "[" or c == "{":
                    depth += 1
                    current += c
                elif c == "]" or c == "}":
                    depth -= 1
                    current += c
                elif c == "," and depth == 0:
                    if current.strip() != "":
                        result.append(_parse_value_json(current.strip()))
                    current = ""
                else:
                    current += c
            else:
                current += c
            i += 1
        if current.strip() != "":
            result.append(_parse_value_json(current.strip()))
        return result

    def _parse_value_json(v):
        v = v.strip()
        if v.startswith("["):
            return _parse_json_array(v)
        if v.startswith("{"):
            return _parse_json_obj(v)
        if v == "true":
            return True
        if v == "false":
            return False
        if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
            return int(v)
        if v.startswith('"') and v.endswith('"'):
            return v[1:-1]
        return v

    def _create_monitor():
        options = _build_options()
        payload = {
            "type": monitor_type,
            "query": query,
            "name": _fix_template_vars(name),
            "message": _fix_template_vars(notification_message),
            "priority": priority,
            "options": options,
        }
        if tags != None:
            payload["tags"] = tags

        payload_str = _json_dumps(payload)
        res = ctx.run([
            "curl", "-s", "-X", "POST",
            api_host.rstrip("/") + "/api/v1/monitor",
            "-H", "DD-API-KEY: " + api_key,
            "-H", "DD-APPLICATION-KEY: " + app_key,
            "-H", "Content-Type: application/json",
            "-d", payload_str,
        ])
        if res.rc != 0:
            fail("Failed to create monitor: " + res.stderr)
        return _json_loads(res.stdout)

    def _update_monitor(monitor_id_val):
        options = _build_options()
        payload = {
            "id": monitor_id_val,
            "query": query,
            "name": _fix_template_vars(name),
            "message": _fix_template_vars(notification_message),
            "priority": priority,
            "options": options,
        }
        if tags != None:
            payload["tags"] = tags

        payload_str = _json_dumps(payload)
        res = ctx.run([
            "curl", "-s", "-X", "PUT",
            api_host.rstrip("/") + "/api/v1/monitor/" + str(monitor_id_val),
            "-H", "DD-API-KEY: " + api_key,
            "-H", "DD-APPLICATION-KEY: " + app_key,
            "-H", "Content-Type: application/json",
            "-d", payload_str,
        ])
        if res.rc != 0:
            fail("Failed to update monitor: " + res.stderr)
        return _json_loads(res.stdout)

    def _delete_monitor(monitor_id_val):
        res = ctx.run([
            "curl", "-s", "-X", "DELETE",
            api_host.rstrip("/") + "/api/v1/monitor/" + str(monitor_id_val),
            "-H", "DD-API-KEY: " + api_key,
            "-H", "DD-APPLICATION-KEY: " + app_key,
        ])
        if res.rc != 0:
            fail("Failed to delete monitor: " + res.stderr)
        return res.stdout

    def _mute_monitor(monitor_id_val):
        payload = {}
        if silenced != None:
            payload["silenced"] = silenced
        payload_str = _json_dumps(payload)
        res = ctx.run([
            "curl", "-s", "-X", "POST",
            api_host.rstrip("/") + "/api/v1/monitor/" + str(monitor_id_val) + "/mute",
            "-H", "DD-API-KEY: " + api_key,
            "-H", "DD-APPLICATION-KEY: " + app_key,
            "-H", "Content-Type: application/json",
            "-d", payload_str,
        ])
        if res.rc != 0:
            fail("Failed to mute monitor: " + res.stderr)
        return res.stdout

    def _unmute_monitor(monitor_id_val):
        res = ctx.run([
            "curl", "-s", "-X", "POST",
            api_host.rstrip("/") + "/api/v1/monitor/" + str(monitor_id_val) + "/unmute",
            "-H", "DD-API-KEY: " + api_key,
            "-H", "DD-APPLICATION-KEY: " + app_key,
        ])
        if res.rc != 0:
            fail("Failed to unmute monitor: " + res.stderr)
        return res.stdout

    monitor = _get_monitor()
    monitor_exists = monitor != None

    if state == "present":
        if not monitor_exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create monitor " + name}
            res = _create_monitor()
            return {"changed": True, "msg": "created monitor " + name, "data": res}
        else:
            current_options = monitor.get("options", {})
            desired_options = _build_options()
            changed = False

            if monitor.get("type") != monitor_type:
                changed = True
            if monitor.get("name") != _fix_template_vars(name):
                changed = True
            if monitor.get("query") != query:
                changed = True
            if monitor.get("message") != _fix_template_vars(notification_message):
                changed = True
            if monitor.get("priority") != priority:
                changed = True
            if tags != None and monitor.get("tags") != tags:
                changed = True

            for key in desired_options.keys():
                if current_options.get(key) != desired_options.get(key):
                    changed = True
                    break
            for key in current_options.keys():
                if key not in desired_options:
                    changed = True
                    break

            if not changed:
                return {"changed": False, "msg": "monitor " + name + " already exists and is up-to-date", "data": monitor}
            if ctx.check_mode:
                return {"changed": True, "msg": "would update monitor " + name}
            res = _update_monitor(monitor["id"])
            return {"changed": True, "msg": "updated monitor " + name, "data": res}

    elif state == "absent":
        if not monitor_exists:
            return {"changed": False, "msg": "monitor " + name + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete monitor " + name}
        _delete_monitor(monitor["id"])
        return {"changed": True, "msg": "deleted monitor " + name}

    elif state == "mute":
        if not monitor_exists:
            fail("Monitor " + name + " not found!")
        monitor_silenced = monitor["options"].get("silenced")
        if monitor_silenced != None and len(monitor_silenced) > 0:
            if silenced != None and len(silenced) > 0:
                if str(monitor_silenced) == str(silenced):
                    return {"changed": False, "msg": "monitor " + name + " is already muted with same scopes"}
            fail("Monitor is already muted. Datadog does not allow to modify muted alerts, consider unmuting it first.")
        if ctx.check_mode:
            return {"changed": True, "msg": "would mute monitor " + name}
        _mute_monitor(monitor["id"])
        return {"changed": True, "msg": "muted monitor " + name}

    elif state == "unmute":
        if not monitor_exists:
            fail("Monitor " + name + " not found!")
        monitor_silenced = monitor["options"].get("silenced")
        if monitor_silenced == None or len(monitor_silenced) == 0:
            return {"changed": False, "msg": "monitor " + name + " is not muted"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would unmute monitor " + name}
        _unmute_monitor(monitor["id"])
        return {"changed": True, "msg": "unmuted monitor " + name}

    fail("Unsupported state: " + state)
