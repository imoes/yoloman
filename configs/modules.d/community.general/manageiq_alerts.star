def main(ctx, params):
    description = params.get("description")
    enabled = params.get("enabled")
    expression = params.get("expression")
    expression_type = params.get("expression_type", "hash")
    manageiq_connection = params.get("manageiq_connection", {})
    options = params.get("options")
    resource_type = params.get("resource_type")
    state = params.get("state", "present")

    # Validate required parameters
    if state == "present":
        if description == None:
            ctx.fail("description is required when state is present")
        if resource_type == None:
            ctx.fail("resource_type is required when state is present")
        if expression == None:
            ctx.fail("expression is required when state is present")
        if enabled == None:
            ctx.fail("enabled is required when state is present")
        if options == None:
            ctx.fail("options is required when state is present")
    elif state == "absent":
        if description == None:
            ctx.fail("description is required when state is absent")

    # Build ManageIQ connection URL and auth
    url = manageiq_connection.get("url") or ctx.getenv("MIQ_URL")
    if url == None:
        ctx.fail("url is required in manageiq_connection or MIQ_URL environment variable")

    username = manageiq_connection.get("username") or ctx.getenv("MIQ_USERNAME")
    password = manageiq_connection.get("password") or ctx.getenv("MIQ_PASSWORD")
    token = manageiq_connection.get("token") or ctx.getenv("MIQ_TOKEN")
    ca_cert = manageiq_connection.get("ca_cert") or manageiq_connection.get("ca_bundle_path")
    verify_ssl = manageiq_connection.get("validate_certs", True)

    auth_header = ""
    if token != None:
        auth_header = "Authorization: Bearer " + token
    elif username != None and password != None:
        # Base64 encoding without importing module
        def b64encode(s):
            chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            result = ""
            i = 0
            while i < len(s):
                chunk = s[i:i+3]
                if len(chunk) < 3:
                    chunk = chunk + "\x00" * (3 - len(chunk))
                b1 = ord(chunk[0])
                b2 = ord(chunk[1])
                b3 = ord(chunk[2])
                c1 = b1 >> 2
                c2 = ((b1 & 3) << 4) | (b2 >> 4)
                c3 = ((b2 & 15) << 2) | (b3 >> 6)
                c4 = b3 & 63
                result = result + chars[c1] + chars[c2] + (chars[c3] if i + 1 < len(s) else "=") + (chars[c4] if i + 2 < len(s) else "=")
                i += 3
            return result

        auth_header = "Authorization: Basic " + b64encode(username + ":" + password)
    else:
        ctx.fail("Either token or username+password must be provided in manageiq_connection or via environment variables")

    # Helper to make HTTP requests
    def manageiq_request(method, path, body=None, headers=None):
        argv = ["curl", "-s", "-X", method, "-H", "Content-Type: application/json"]
        if auth_header != "":
            argv.extend(["-H", auth_header])
        if not verify_ssl:
            argv.append("-k")
        if ca_cert != None:
            argv.extend(["--cacert", ca_cert])
        if body != None:
            argv.extend(["-d", str(body)])
        if headers != None:
            for k, v in headers.items():
                argv.extend(["-H", k + ": " + v])
        argv.append(url + path)
        res = ctx.run(argv)
        if res.rc != 0:
            ctx.fail("ManageIQ request failed: " + res.stderr)
        return res.stdout

    # Get existing alerts
    alerts_json = manageiq_request("GET", "/api/alert_definitions?expand=resources")
    # Simple JSON parsing without json module
    alerts = []
    if '"resources"' in alerts_json:
        # Extract resources list - naive parsing for known structure
        start = alerts_json.find('"resources"')
        if start != -1:
            bracket_start = alerts_json.find('[', start)
            if bracket_start != -1:
                depth = 0
                end = bracket_start
                for i in range(bracket_start, len(alerts_json)):
                    if alerts_json[i] == '[':
                        depth += 1
                    elif alerts_json[i] == ']':
                        depth -= 1
                        if depth == 0:
                            end = i + 1
                            break
                raw_resources = alerts_json[bracket_start:end]
                # Parse resources as list of dicts
                # Split by '},{' pattern to get individual alerts
                parts = []
                depth = 0
                current = ""
                in_object = False
                for ch in raw_resources:
                    if ch == '{':
                        in_object = True
                        depth += 1
                    elif ch == '}':
                        depth -= 1
                        if depth == 0 and in_object:
                            parts.append(current + ch)
                            current = ""
                            in_object = False
                            continue
                    if in_object:
                        current += ch
                for part in parts:
                    alert = {}
                    # Parse description
                    if '"description"' in part:
                        desc_start = part.find('"description"') + len('"description"')
                        desc_val = part[desc_start:].strip()
                        if desc_val.startswith(': "'):
                            desc_val = desc_val[3:]
                            desc_end = desc_val.find('"')
                            if desc_end != -1:
                                alert['description'] = desc_val[:desc_end]
                    # Parse id
                    if '"id"' in part:
                        id_start = part.find('"id"') + len('"id"')
                        id_val = part[id_start:].strip()
                        if id_val.startswith(': '):
                            id_val = id_val[2:]
                            id_num = ""
                            for ch in id_val:
                                if ch.isdigit():
                                    id_num += ch
                                else:
                                    break
                            if id_num != "":
                                alert['id'] = int(id_num)
                    # Parse enabled
                    if '"enabled"' in part:
                        enabled_start = part.find('"enabled"') + len('"enabled"')
                        enabled_val = part[enabled_start:].strip()
                        if enabled_val.startswith(': '):
                            enabled_val = enabled_val[2:]
                            if enabled_val.startswith('true'):
                                alert['enabled'] = True
                            elif enabled_val.startswith('false'):
                                alert['enabled'] = False
                    # Parse db (resource type)
                    if '"db"' in part:
                        db_start = part.find('"db"') + len('"db"')
                        db_val = part[db_start:].strip()
                        if db_val.startswith(': "'):
                            db_val = db_val[3:]
                            db_end = db_val.find('"')
                            if db_end != -1:
                                alert['db'] = db_val[:db_end]
                    # Parse options
                    if '"options"' in part:
                        options_start = part.find('"options"') + len('"options"')
                        options_val = part[options_start:].strip()
                        brace_start = options_val.find('{')
                        if brace_start != -1:
                            depth = 0
                            end_opt = brace_start
                            for i in range(brace_start, len(options_val)):
                                if options_val[i] == '{':
                                    depth += 1
                                elif options_val[i] == '}':
                                    depth -= 1
                                    if depth == 0:
                                        end_opt = i + 1
                                        break
                            alert['options'] = options_val[brace_start:end_opt]
                    # Parse hash_expression
                    if '"hash_expression"' in part:
                        he_start = part.find('"hash_expression"') + len('"hash_expression"')
                        he_val = part[he_start:].strip()
                        brace_start = he_val.find('{')
                        if brace_start != -1:
                            depth = 0
                            end_he = brace_start
                            for i in range(brace_start, len(he_val)):
                                if he_val[i] == '{':
                                    depth += 1
                                elif he_val[i] == '}':
                                    depth -= 1
                                    if depth == 0:
                                        end_he = i + 1
                                        break
                            alert['hash_expression'] = he_val[brace_start:end_he]
                    # Parse expression (miq_expression)
                    if '"expression"' in part:
                        expr_start = part.find('"expression"') + len('"expression"')
                        expr_val = part[expr_start:].strip()
                        brace_start = expr_val.find('{')
                        if brace_start != -1:
                            depth = 0
                            end_expr = brace_start
                            for i in range(brace_start, len(expr_val)):
                                if expr_val[i] == '{':
                                    depth += 1
                                elif expr_val[i] == '}':
                                    depth -= 1
                                    if depth == 0:
                                        end_expr = i + 1
                                        break
                            alert['expression'] = expr_val[brace_start:end_expr]
                    # Parse miq_expression
                    if '"miq_expression"' in part:
                        mie_start = part.find('"miq_expression"') + len('"miq_expression"')
                        mie_val = part[mie_start:].strip()
                        brace_start = mie_val.find('{')
                        if brace_start != -1:
                            depth = 0
                            end_mie = brace_start
                            for i in range(brace_start, len(mie_val)):
                                if mie_val[i] == '{':
                                    depth += 1
                                elif mie_val[i] == '}':
                                    depth -= 1
                                    if depth == 0:
                                        end_mie = i + 1
                                        break
                        alert['miq_expression'] = mie_val[brace_start:end_mie]
                    alerts.append(alert)

    # Find existing alert by description
    existing_alert = None
    for alert in alerts:
        if alert.get("description") == description:
            existing_alert = alert
            break

    if state == "present":
        # Build alert payload
        alert_payload = {
            "description": description,
            "db": resource_type,
            "enabled": enabled,
            "options": options
        }

        # Validate hash expression
        if expression_type == "hash":
            required_keys = ["options", "eval_method", "mode"]
            for key in required_keys:
                if key not in expression:
                    ctx.fail("Hash expression is missing required field: " + key)
            alert_payload["hash_expression"] = expression
        else:
            alert_payload["expression"] = expression

        # Check if update needed
        changed = False
        msg = ""

        if existing_alert == None:
            # Create alert
            if ctx.check_mode:
                return {"changed": True, "msg": "would create alert " + description}
            body_json = str(alert_payload).replace("'", '"')
            create_res = manageiq_request("POST", "/api/alert_definitions", body_json)
            msg = "Alert " + description + " created successfully: " + create_res
            changed = True
        else:
            # Compare alerts (simplified)
            # Check if fields differ
            if (existing_alert.get("enabled") != enabled or
                existing_alert.get("db") != resource_type or
                existing_alert.get("description") != description or
                str(existing_alert.get("options")) != str(options)):
                changed = True
            else:
                # Check expressions
                if expression_type == "hash" and str(existing_alert.get("hash_expression")) != str(expression):
                    changed = True
                elif expression_type != "hash" and str(existing_alert.get("expression")) != str(expression):
                    changed = True

            if changed:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update alert " + description}
                # Update alert
                alert_id = existing_alert.get("id")
                if alert_id == None:
                    ctx.fail("Could not determine alert ID for update")
                body_json = str(alert_payload).replace("'", '"')
                update_res = manageiq_request("POST", "/api/alert_definitions/" + str(alert_id), body_json)
                msg = "Alert " + description + " updated successfully"
                changed = True
            else:
                msg = "Alert " + description + " already exists with correct configuration"
                changed = False

        return {"changed": changed, "msg": msg}

    elif state == "absent":
        if existing_alert == None:
            return {"changed": False, "msg": "Alert " + description + " does not exist in ManageIQ"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete alert " + description}
            alert_id = existing_alert.get("id")
            if alert_id == None:
                ctx.fail("Could not determine alert ID for deletion")
            delete_res = manageiq_request("POST", "/api/alert_definitions/" + str(alert_id) + "?action=delete")
            return {"changed": True, "msg": "Alert " + description + " deleted successfully"}
