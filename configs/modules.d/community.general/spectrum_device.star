def main(ctx, params):
    device = params["device"]
    community = params.get("community")
    landscape = params["landscape"]
    state = params.get("state", "present")
    url = params["url"]
    url_username = params["url_username"]
    url_password = params["url_password"]
    use_proxy = params.get("use_proxy", True)
    validate_certs = params.get("validate_certs", True)
    agentport = params.get("agentport", 161)

    # Validate required parameters
    if state == "present" and community == None:
        fail("community is required when state is present")

    # Resolve hostname to IP
    device_ip = _resolve_host(ctx, device)

    # Check if device exists
    device_info = _get_device(ctx, url, url_username, url_password, device_ip, landscape, validate_certs)

    if state == "present":
        if device_info != None:
            return {"changed": False, "msg": "device already exists", "device": device_info}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add device", "device": {"model_handle": None, "address": device_ip, "landscape": landscape}}
        device_info = _add_device(ctx, url, url_username, url_password, device_ip, community, landscape, agentport, validate_certs)
        return {"changed": True, "msg": "device added", "device": device_info}
    elif state == "absent":
        if device_info == None:
            return {"changed": False, "msg": "device does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove device"}
        _remove_device(ctx, url, url_username, url_password, device_info["model_handle"], validate_certs)
        return {"changed": True, "msg": "device removed"}

    fail("unsupported state: " + state)


def _resolve_host(ctx, hostname):
    # Use getent to resolve hostname to IP
    res = ctx.run(["getent", "hosts", hostname])
    output = res.stdout.strip()
    if output == "":
        fail("failed to resolve device ip address for '%s'" % hostname)
    # Format: "IP hostname hostname aliases..."
    parts = output.split()
    if len(parts) == 0:
        fail("failed to resolve device ip address for '%s'" % hostname)
    return parts[0]


def _build_url(ctx, url, resource):
    base = url.rstrip("/")
    if not resource.startswith("/"):
        resource = "/" + resource
    return base + "/spectrum/restful" + resource


def _base64_encode(ctx, input_str):
    # Encode string to base64 manually using base64 character set
    b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    result = []
    i = 0
    while i < len(input_str):
        # Get 3 bytes (24 bits)
        b1 = ord(input_str[i]) if i < len(input_str) else 0
        b2 = ord(input_str[i + 1]) if i + 1 < len(input_str) else 0
        b3 = ord(input_str[i + 2]) if i + 2 < len(input_str) else 0
        
        # Pack into 24 bits
        bits = (b1 << 16) + (b2 << 8) + b3
        
        # Split into 4 6-bit groups
        c1 = (bits >> 18) & 0x3F
        c2 = (bits >> 12) & 0x3F
        c3 = (bits >> 6) & 0x3F
        c4 = bits & 0x3F
        
        # Map to base64 characters
        result.append(b64_chars[c1] if i < len(input_str) else "=")
        result.append(b64_chars[c2] if i + 1 < len(input_str) else "=")
        result.append(b64_chars[c3] if i + 2 < len(input_str) else "=")
        result.append(b64_chars[c4] if i + 2 < len(input_str) else "=")
        
        i += 3
    
    return "".join(result)


def _auth_header(ctx, username, password):
    # Basic auth encoding: base64("user:pass")
    auth_str = username + ":" + password
    encoded = _base64_encode(ctx, auth_str)
    return "Basic " + encoded


def _xml_request(ctx, url, method, auth_header, body, validate_certs):
    # Prepare curl command
    cmd = ["curl", "-s", "-w", "\n%{http_code}", "-X", method, "-H", "Content-Type: application/xml", "-H", "Accept: application/xml", "-H", "Authorization: " + auth_header]
    if not validate_certs:
        cmd.append("-k")
    if body != None:
        cmd.extend(["--data", body])
    cmd.append(url)
    
    res = ctx.run(cmd)
    # Parse response: last line is HTTP status code
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        fail("unexpected response from server: " + res.stderr)
    
    body_output = "\n".join(lines[:-1])
    # Parse status code without try/except
    last_line = lines[-1]
    if last_line.isdigit():
        status_code = int(last_line)
    else:
        fail("could not parse HTTP status code from response")
    
    return {"body": body_output, "status": status_code}


def _get_device(ctx, url, username, password, device_ip, landscape, validate_certs):
    auth_header = _auth_header(ctx, username, password)
    resource = "/models"
    
    landscape_min = "0x%x" % int(landscape, 16)
    landscape_max = "0x%x" % (int(landscape, 16) + 0x100000)
    
    xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rs:model-request throttlesize="5"
        xmlns:rs="http://www.ca.com/spectrum/restful/schema/request"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="http://www.ca.com/spectrum/restful/schema/request ../../../xsd/Request.xsd">
            <rs:target-models>
            <rs:models-search>
                <rs:search-criteria xmlns="http://www.ca.com/spectrum/restful/schema/filter">
                    <action-models>
                        <filtered-models>
                            <and>
                                <equals>
                                    <model-type>SearchManager</model-type>
                                </equals>
                                <greater-than>
                                    <attribute id="0x129fa">
                                        <value>{mh_min}</value>
                                    </attribute>
                                </greater-than>
                                <less-than>
                                    <attribute id="0x129fa">
                                        <value>{mh_max}</value>
                                    </attribute>
                                </less-than>
                            </and>
                        </filtered-models>
                        <action>FIND_DEV_MODELS_BY_IP</action>
                        <attribute id="AttributeID.NETWORK_ADDRESS">
                            <value>{search_ip}</value>
                        </attribute>
                    </action-models>
                </rs:search-criteria>
            </rs:models-search>
            </rs:target-models>
            <rs:requested-attribute id="0x12d7f" />
        </rs:model-request>""".format(search_ip=device_ip, mh_min=landscape_min, mh_max=landscape_max)

    resp = _xml_request(ctx, _build_url(ctx, url, resource), "POST", auth_header, xml, validate_certs)
    
    if resp["status"] == 401:
        fail("failed to authenticate to Oneclick server")
    
    if resp["status"] not in (200, 201, 204):
        fail("unexpected HTTP status: %d" % resp["status"])

    # Parse XML response
    body = resp["body"]
    total_models = _get_xml_tag_value(body, "total-models")
    
    if total_models == None or int(total_models) == 0:
        return None
    
    # Extract model handle and address
    model_handle = _get_xml_tag_value(body, "model mh")
    if model_handle == None:
        return None
    
    # Get network address (0x12d7f)
    address = _get_xml_tag_value(body, "attribute id=\"0x12d7f\"")
    if address == None:
        return None

    # Calculate landscape from model handle
    model_handle_int = int(model_handle, 16)
    model_landscape = "0x%x" % ((model_handle_int // 0x100000) * 0x100000)

    return {
        "model_handle": model_handle,
        "address": address.strip(),
        "landscape": model_landscape
    }


def _add_device(ctx, url, username, password, device_ip, community, landscape, agentport, validate_certs):
    auth_header = _auth_header(ctx, username, password)
    resource = "/model?ipaddress=" + device_ip + "&commstring=" + community + "&landscapeid=" + landscape
    
    if agentport != None:
        resource += "&agentport=" + str(agentport)

    resp = _xml_request(ctx, _build_url(ctx, url, resource), "POST", auth_header, None, validate_certs)
    
    if resp["status"] not in (200, 201, 204):
        fail("unexpected HTTP status: %d" % resp["status"])

    body = resp["body"]
    
    # Check error status
    error = _get_xml_tag_value(body, "error")
    if error != None and error != "Success":
        error_message = _get_xml_tag_value(body, "error-message")
        fail("error creating device: %s" % (error_message if error_message != None else error))

    # Get device details from response
    model_handle = _get_xml_tag_value(body, "model mh")
    if model_handle == None:
        fail("no model handle returned after device creation")

    # Calculate landscape from model handle
    model_handle_int = int(model_handle, 16)
    model_landscape = "0x%x" % ((model_handle_int // 0x100000) * 0x100000)

    return {
        "model_handle": model_handle,
        "address": device_ip,
        "landscape": model_landscape
    }


def _remove_device(ctx, url, username, password, model_handle, validate_certs):
    auth_header = _auth_header(ctx, username, password)
    resource = "/model/" + model_handle

    resp = _xml_request(ctx, _build_url(ctx, url, resource), "DELETE", auth_header, None, validate_certs)
    
    if resp["status"] not in (200, 201, 204):
        fail("unexpected HTTP status: %d" % resp["status"])

    body = resp["body"]

    error = _get_xml_tag_value(body, "error")
    if error != None and error != "Success":
        error_message = _get_xml_tag_value(body, "error-message")
        fail("error removing device: %s %s" % (error, error_message if error_message != None else ""))


def _get_xml_tag_value(xml_content, tag_pattern):
    # Simple XML parser for specific tags (no full XML lib available)
    # Support for: <tag attr="value">content</tag>, <tag attr="value" /> or <tag>content</tag>
    
    # Normalize tag pattern for matching
    if " " in tag_pattern:
        tag_parts = tag_pattern.split(" ", 1)
        tag_name = tag_parts[0]
        attr_match = tag_parts[1].strip()
    else:
        tag_name = tag_pattern
        attr_match = None
    
    # Try opening tag with content
    open_tag = "<" + tag_name
    if attr_match != None:
        # Include attribute match
        search_str = open_tag + " " + attr_match
        idx_start = xml_content.find(search_str)
        if idx_start == -1:
            # Try alternate quote styles
            alt_attr = attr_match.replace('\"', "'")
            search_str = open_tag + " " + alt_attr
            idx_start = xml_content.find(search_str)
        if idx_start == -1:
            return None
        
        # Find end of opening tag
        idx_end = xml_content.find(">", idx_start)
        if idx_end == -1:
            return None
        
        # Check for self-closing
        if xml_content[idx_end-1] == "/":
            return ""
        
        # Find closing tag
        close_tag = "</" + tag_name + ">"
        idx_content_start = idx_end + 1
        idx_content_end = xml_content.find(close_tag, idx_content_start)
        if idx_content_end == -1:
            return None
        
        return xml_content[idx_content_start:idx_content_end].strip()
    
    # Simple case: just <tag>content</tag>
    idx_start = xml_content.find("<" + tag_name + ">")
    if idx_start == -1:
        # Try with attributes
        idx_start = xml_content.find("<" + tag_name + " ")
        if idx_start == -1:
            return None
        # Find closing bracket
        idx_bracket = xml_content.find(">", idx_start)
        if idx_bracket == -1:
            return None
        idx_content_start = idx_bracket + 1
        close_tag = "</" + tag_name + ">"
        idx_content_end = xml_content.find(close_tag, idx_content_start)
        if idx_content_end == -1:
            return None
        return xml_content[idx_content_start:idx_content_end].strip()
    
    # Simple opening tag found
    idx_end = idx_start + len(tag_name) + 2  # len("<tag>") = len(tag) + 2
    idx_content_start = idx_end
    close_tag = "</" + tag_name + ">"
    idx_content_end = xml_content.find(close_tag, idx_content_start)
    if idx_content_end == -1:
        return None
    
    return xml_content[idx_content_start:idx_content_end].strip()
