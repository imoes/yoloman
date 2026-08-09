def main(ctx, params):
    balancer_vhost = params["balancer_vhost"]
    balancer_url_suffix = params.get("balancer_url_suffix", "/balancer-manager/")
    member_host = params.get("member_host")
    state = params.get("state")
    tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", True)

    # Check BeautifulSoup availability via facts if present
    facts = ctx.facts()
    if facts.get("has_beautifulsoup") == False:
        ctx.fail("This module requires BeautifulSoup - please install it on the target system.")

    # Build balancer URL
    protocol = "https" if tls else "http"
    balancer_url = protocol + "://" + balancer_vhost + balancer_url_suffix

    # Validate states
    valid_states = ["present", "absent", "enabled", "disabled", "drained", "hot_standby", "ignore_errors"]
    states_list = []
    if state != None:
        states_list = state.split(",")
        if len(states_list) > 1:
            if "present" in states_list or "enabled" in states_list:
                ctx.fail("state present/enabled is mutually exclusive with other states!")
        for s in states_list:
            if s not in valid_states:
                ctx.fail("State can only take values amongst 'present', 'absent', 'enabled', 'disabled', 'drained', 'hot_standby', 'ignore_errors'.")

    # Fetch balancer page
    balancer_res = ctx.run(["curl", "-sS", "--fail", "-k" if not validate_certs else "", balancer_url], mutates=False)
    if balancer_res.skipped:
        if ctx.check_mode and member_host == None:
            return {"changed": False, "members": [], "msg": "would fetch balancer page"}
    if balancer_res.rc != 0:
        ctx.fail("Could not get balancer page! HTTP status response: " + str(balancer_res.rc))

    balancer_page = balancer_res.stdout

    # Extract Apache version (simplified)
    apache_version = ""
    if "SERVER VERSION: APACHE/" in balancer_page:
        idx = balancer_page.find("SERVER VERSION: APACHE/")
        if idx >= 0:
            v_start = idx + len("SERVER VERSION: APACHE/")
            v_end = balancer_page.find(".", v_start + 2)
            if v_end > 0:
                apache_version = balancer_page[v_start:v_end]
            else:
                apache_version = balancer_page[v_start:].strip()
    if apache_version == "":
        ctx.fail("Could not get the Apache server version from the balancer-manager")
    version_parts = apache_version.split(".")
    if len(version_parts) < 2 or int(version_parts[0]) < 2 or (int(version_parts[0]) == 2 and int(version_parts[1]) < 4):
        ctx.fail("This module only acts on an Apache2 2.4+ instance, current Apache2 version: " + apache_version)

    # Parse balancer members from page HTML (simplified parsing)
    hrefs = []
    lines = balancer_page.split("\n")
    for line in lines:
        if "href=" in line and "<a " in line:
            start = line.find("href=\"")
            if start >= 0:
                start += 6
                end = line.find("\"", start)
                if end > start:
                    hrefs.append(line[start:end])

    # Filter out the balancer-manager link
    member_hrefs = []
    for href in hrefs[1:] if len(hrefs) > 0 else []:
        if not href.startswith(balancer_url_suffix) and not href.startswith("/balancer-manager"):
            member_hrefs.append(href)

    # Build member list
    members = []
    member_exists = False
    target_member = None
    management_url_base = protocol + "://" + balancer_vhost

    for href in member_hrefs:
        full_href = management_url_base + href
        # Extract host, port, path, protocol using basic string operations
        protocol_member = ""
        host_member = ""
        port_member = ""
        path_member = ""

        # Find protocol
        if "w=http://" in full_href:
            protocol_member = "http"
        elif "w=https://" in full_href:
            protocol_member = "https"
        elif "w=ajp://" in full_href:
            protocol_member = "ajp"
        elif "w=ftp://" in full_href:
            protocol_member = "ftp"
        elif "w=fcgi://" in full_href:
            protocol_member = "fcgi"
        elif "w=scgi://" in full_href:
            protocol_member = "scgi"
        elif "w=ws://" in full_href:
            protocol_member = "ws"
        elif "w=wss://" in full_href:
            protocol_member = "wss"

        # Extract host and port
        if "w=" + protocol_member + "://" in full_href:
            start = full_href.find("w=" + protocol_member + "://")
            if start >= 0:
                start += len("w=" + protocol_member + "://")
                end = start
                while end < len(full_href) and full_href[end] not in [":", "/", "?", "&"]:
                    end += 1
                host_member = full_href[start:end]
                if end < len(full_href) and full_href[end] == ":":
                    end2 = end + 1
                    while end2 < len(full_href) and full_href[end2] not in ["/", "?", "&"]:
                        end2 += 1
                    port_member = full_href[end+1:end2]
                    path_member = full_href[end2:end2 + 100]  # rough truncation
                    # Clean up path
                    if "?" in path_member:
                        path_member = path_member[:path_member.find("?")]

        # Skip if host matches balancer itself
        if host_member in balancer_vhost:
            continue

        m = {
            "host": host_member,
            "port": port_member if port_member != "" else "",
            "protocol": protocol_member,
            "path": path_member if path_member != "" and path_member != "/" else "",
            "management_url": full_href,
            "balancer_url": balancer_url
        }
        members.append(m)

        if member_host != None and host_member == member_host:
            member_exists = True
            target_member = m

    # If no member_host specified, return members list
    if member_host == None:
        return {"changed": False, "members": members, "msg": "retrieved balancer pool members"}

    # If member_host specified but not found
    if not member_exists:
        ctx.fail(member_host + " is not a member of the balancer " + balancer_vhost + "!")

    # Determine desired state for each attribute
    desired_state = {
        "disabled": False,
        "drained": False,
        "hot_standby": False,
        "ignore_errors": False
    }

    for s in states_list:
        if s == "absent":
            desired_state["disabled"] = True
        elif s == "disabled":
            desired_state["disabled"] = True
        elif s == "drained":
            desired_state["drained"] = True
        elif s == "hot_standby":
            desired_state["hot_standby"] = True
        elif s == "ignore_errors":
            desired_state["ignore_errors"] = True
        elif s == "enabled" or s == "present":
            desired_state = {
                "disabled": False,
                "drained": False,
                "hot_standby": False,
                "ignore_errors": False
            }
            break

    # In check_mode, just predict change
    if ctx.check_mode:
        changed = len(states_list) > 0
        return {"changed": changed, "member": {
            "host": target_member["host"],
            "port": target_member["port"],
            "protocol": target_member["protocol"],
            "path": target_member["path"],
            "management_url": target_member["management_url"],
            "balancer_url": target_member["balancer_url"],
            "status": desired_state
        }, "msg": "would set member state" if changed else "member state already matches"}

    # Apply state change via curl POST
    status_params = ""
    if desired_state["disabled"]:
        status_params += "&w_status_D=1"
    else:
        status_params += "&w_status_D=0"
    if desired_state["drained"]:
        status_params += "&w_status_N=1"
    else:
        status_params += "&w_status_N=0"
    if desired_state["hot_standby"]:
        status_params += "&w_status_H=1"
    else:
        status_params += "&w_status_H=0"
    if desired_state["ignore_errors"]:
        status_params += "&w_status_I=1"
    else:
        status_params += "&w_status_I=0"

    post_url = target_member["management_url"] + status_params

    # Build POST body (remove leading "&")
    post_body = status_params.lstrip("&")

    res = ctx.run([
        "curl", "-sS", "--fail", "-k" if not validate_certs else "",
        "-X", "POST",
        "-d", post_body,
        post_url
    ], mutates=True)

    if res.skipped:
        changed = len(states_list) > 0
        return {"changed": changed, "member": {
            "host": target_member["host"],
            "port": target_member["port"],
            "protocol": target_member["protocol"],
            "path": target_member["path"],
            "management_url": target_member["management_url"],
            "balancer_url": target_member["balancer_url"],
            "status": desired_state
        }, "msg": "would set member state"}

    if res.rc != 0:
        ctx.fail("Could not set the member status for " + member_host + ": " + res.stderr)

    changed = len(states_list) > 0
    return {"changed": changed, "member": {
        "host": target_member["host"],
        "port": target_member["port"],
        "protocol": target_member["protocol"],
        "path": target_member["path"],
        "management_url": target_member["management_url"],
        "balancer_url": target_member["balancer_url"],
        "status": desired_state
    }, "msg": "set member state"}
