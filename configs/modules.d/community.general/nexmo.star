def main(ctx, params):
    api_key = params["api_key"]
    api_secret = params["api_secret"]
    src = str(params["src"])
    dest = params["dest"]
    msg = params["msg"]
    validate_certs = params.get("validate_certs", True)
    url_username = params.get("url_username")
    url_password = params.get("url_password")
    force_basic_auth = params.get("force_basic_auth", False)
    http_agent = params.get("http_agent", "ansible-httpget")
    use_proxy = params.get("use_proxy", True)
    
    if len(dest) == 0:
        fail("dest list cannot be empty")
    
    base_url = "https://rest.nexmo.com/sms/json"
    
    # Build headers
    auth_header = ""
    if force_basic_auth and url_username != None and url_password != None:
        auth_str = url_username + ":" + url_password
        # Simple base64 encoding without using import
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        encoded = ""
        i = 0
        while i < len(auth_str):
            byte1 = ord(auth_str[i])
            byte2 = ord(auth_str[i+1]) if i+1 < len(auth_str) else 0
            byte3 = ord(auth_str[i+2]) if i+2 < len(auth_str) else 0
            chunk = (byte1 << 16) + (byte2 << 8) + byte3
            encoded += b64_chars[(chunk >> 18) & 63]
            encoded += b64_chars[(chunk >> 12) & 63]
            encoded += b64_chars[(chunk >> 6) & 63]
            encoded += b64_chars[chunk & 63]
            padding = 3 - (len(auth_str) % 3)
            if padding == 3:
                encoded = encoded[:-2] + "=="
            elif padding == 2:
                encoded = encoded[:-1] + "="
            i += 3
        auth_header = "Authorization: Basic " + encoded
    
    headers_list = ["Accept: application/json", "User-Agent: " + http_agent]
    if auth_header != "":
        headers_list.append(auth_header)
    
    failed_numbers = []
    responses = {}
    
    # Process each destination number
    for number in dest:
        # Construct URL with number parameter
        url = base_url + "?to=" + str(number)
        url += "&api_key=" + api_key
        url += "&api_secret=" + api_secret
        url += "&from=" + src
        url += "&text=" + msg
        
        # Build curl arguments
        curl_args = ["curl", "-s", "-f", "-L", "-X", "GET", "--connect-timeout", "10", "--max-time", "30"]
        if not validate_certs:
            curl_args.append("--insecure")
        
        for header in headers_list:
            curl_args.extend(["-H", header])
        
        curl_args.append(url)
        
        # Make HTTP request
        res = ctx.run(curl_args, mutates=False)
        
        if res.rc != 0:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        # Parse JSON response manually - no try/except allowed
        response_text = res.stdout
        messages_start = response_text.find('"messages"')
        if messages_start == -1:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        # Extract messages array content
        start_brace = response_text.find("[", messages_start)
        if start_brace == -1:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        end_brace = start_brace
        bracket_count = 1
        i = start_brace + 1
        while i < len(response_text) and bracket_count > 0:
            if response_text[i] == '[':
                bracket_count += 1
            elif response_text[i] == ']':
                bracket_count -= 1
            i += 1
        end_brace = i - 1
        
        messages_str = response_text[start_brace+1:end_brace]
        
        # Parse status from the single message
        status_start = messages_str.find('"status"')
        if status_start == -1:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        colon_pos = messages_str.find(":", status_start)
        if colon_pos == -1:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        status_val = ""
        j = colon_pos + 1
        while j < len(messages_str) and messages_str[j] in "0123456789":
            status_val += messages_str[j]
            j += 1
        
        if status_val == "":
            failed_numbers.append(number)
            responses[number] = {"failed": True}
            continue
        
        status = int(status_val)
        if status != 0:
            failed_numbers.append(number)
            responses[number] = {"failed": True}
        else:
            responses[number] = {"messages": [{"status": status}]}
    
    # Prepare final result
    if len(failed_numbers) > 0:
        msg = "One or messages failed to send"
    else:
        msg = ""
    
    return {
        "changed": False,
        "msg": msg,
        "failed": len(failed_numbers) > 0,
        "responses": responses
    }
