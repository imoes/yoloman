def main(ctx, params):
    cli_path = params.get("cli_path", "op")
    auto_login = params.get("auto_login")
    search_terms = params.get("search_terms")

    def parse_search_terms(terms):
        processed = []
        for term in terms:
            if type(term) != "dict":
                term = {"name": term}
            if "name" not in term:
                fail("Missing required 'name' field from search term, got: '%s'" % str(term))
            term["field"] = term.get("field", "password")
            term["section"] = term.get("section", None)
            term["vault"] = term.get("vault", None)
            processed.append(term)
        return processed

    def run_op(args, command_input=None):
        argv = [cli_path] + args
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            fail(res.stderr)
        return res.rc, res.stdout, res.stderr

    def assert_logged_in():
        res = run_op(["get", "account"])
        if res[0] == 0:
            return
        # Try basic sign-in first
        args = ["signin", "--output=raw"]
        if auto_login != None and auto_login.get("subdomain") != None:
            args = ["signin", auto_login.get("subdomain"), "--output=raw"]
        
        password_input = ""
        if auto_login != None:
            password_input = auto_login.get("master_password", "")
        res = run_op(args, command_input=password_input)
        if res[0] == 0:
            return
        
        # Fallback to full sign-in
        if auto_login == None:
            fail("Unable to perform an initial sign in to 1Password. Please run '%s signin' or define credentials in 'auto_login'." % cli_path)
        
        # Check required fields for full sign-in
        if (auto_login.get("subdomain") == None or
            auto_login.get("username") == None or
            auto_login.get("secret_key") == None or
            auto_login.get("master_password") == None):
            fail("Unable to perform initial sign in to 1Password. subdomain, username, secret_key, and master_password are required to perform initial sign in.")
        
        args = [
            "signin",
            auto_login.get("subdomain") + ".1password.com",
            auto_login.get("username"),
            auto_login.get("secret_key"),
            "--output=raw",
        ]
        res = run_op(args, command_input=auto_login.get("master_password"))
        if res.rc != 0:
            fail("Failed to perform initial sign in to 1Password: " + res.stderr)
    
    def get_raw(item_id, vault=None):
        args = ["get", "item", item_id]
        if vault != None:
            args += ["--vault=" + vault]
        res = run_op(args)
        return res.stdout
    
    def parse_field(data_json, item_id, field_name, section_title=None):
        data = data_json.strip()
        # Check if it's a document by looking for documentAttributes
        if data.find("documentAttributes") >= 0:
            # Extract title - simplified parsing
            title_start = data.find('"title":"') + len('"title":"')
            if title_start < len('"title":"'):
                title_start = data.find('"title": "') + len('"title": "')
            title_end = data.find('"', title_start)
            if title_end < 0:
                fail("Could not parse item title from JSON")
            title = data[title_start:title_end]
            doc_res = run_op(["get", "document", title])
            return {"document": doc_res.stdout.strip()}
        
        # Try to extract field value from JSON-like structure
        # Look for field in top-level details or fields array
        # Simple pattern matching for common 1Password JSON output
        if data.find('"' + field_name + '":') >= 0:
            # Check for direct field in details
            pattern = '"' + field_name + '":'
            start = data.find(pattern)
            if start >= 0:
                start = start + len(pattern)
                # Skip whitespace and quotes
                while start < len(data) and (data[start] == ' ' or data[start] == '"'):
                    start += 1
                end = start
                while end < len(data) and data[end] not in [',', '}', '\n']:
                    end += 1
                return {field_name: data[start:end].strip('"')}
        
        # Try fields array
        fields_start = data.find('"fields":')
        if fields_start >= 0:
            # Find the start of the fields array
            arr_start = data.find('[', fields_start)
            if arr_start >= 0:
                # Search within the array for our field
                # This is simplified - real parsing would need more robust handling
                fields_section = data[arr_start:]
                fields_end = fields_section.find(']')
                if fields_end >= 0:
                    fields_section = fields_section[:fields_end]
                    # Look for name field with matching field_name
                    name_pattern = '"name": "' + field_name + '"'
                    if fields_section.lower().find(name_pattern.lower()) >= 0:
                        pos = fields_section.lower().find(name_pattern.lower())
                        # Find value field after this
                        value_pos = fields_section.lower().find('"value":', pos)
                        if value_pos >= 0:
                            vstart = value_pos + len('"value":')
                            while vstart < len(fields_section) and fields_section[vstart] in ' \t"':
                                vstart += 1
                            vend = vstart
                            while vend < len(fields_section) and fields_section[vend] not in ['"', ',', ']', '\n']:
                                vend += 1
                            return {field_name: fields_section[vstart:vend].strip('"')}
        
        # Try sections
        if section_title != None:
            sec_pattern = '"title": "' + section_title + '"'
            sec_start = data.lower().find(sec_pattern.lower())
            if sec_start >= 0:
                # Find the section object
                brace_start = data.find('{', sec_start)
                if brace_start >= 0:
                    # Find matching close brace
                    depth = 0
                    brace_end = brace_start
                    while brace_end < len(data) and depth >= 0:
                        if data[brace_end] == '{':
                            depth += 1
                        if data[brace_end] == '}':
                            depth -= 1
                        brace_end += 1
                    sec_section = data[brace_start:brace_end]
                    # Search for field in this section
                    fields_start = sec_section.find('"fields":')
                    if fields_start >= 0:
                        arr_start = sec_section.find('[', fields_start)
                        if arr_start >= 0:
                            arr_end = sec_section.find(']', arr_start)
                            if arr_end >= 0:
                                field_arr = sec_section[arr_start:arr_end+1]
                                name_pattern = '"name": "' + field_name + '"'
                                if field_arr.lower().find(name_pattern.lower()) >= 0:
                                    pos = field_arr.lower().find(name_pattern.lower())
                                    value_pos = field_arr.lower().find('"value":', pos)
                                    if value_pos >= 0:
                                        vstart = value_pos + len('"value":')
                                        while vstart < len(field_arr) and field_arr[vstart] in ' \t"':
                                            vstart += 1
                                        vend = vstart
                                        while vend < len(field_arr) and field_arr[vend] not in ['"', ',', ']', '\n']:
                                            vend += 1
                                        return {field_name: field_arr[vstart:vend].strip('"')}
        
        # If we get here, field not found
        optional_section_title = "" if section_title == None else " in the section '%s'" % section_title
        fail("Unable to find an item in 1Password named '%s' with the field '%s'%s." % (item_id, field_name, optional_section_title))
    
    # Main logic
    if len(search_terms) == 0:
        fail("search_terms is required and cannot be empty")
    
    parsed_terms = parse_search_terms(search_terms)
    assert_logged_in()
    
    result = {}
    for term in parsed_terms:
        raw_data = get_raw(term["name"], term["vault"])
        value = parse_field(raw_data, term["name"], term["field"], term["section"])
        
        if term["name"] in result:
            result[term["name"]].update(value)
        else:
            result[term["name"]] = value
    
    return {"changed": False, "msg": "Successfully retrieved items from 1Password", "data": result}
