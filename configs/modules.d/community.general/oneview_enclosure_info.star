def main(ctx, params):
    name = params.get("name")
    options = params.get("options")
    # params['params'] maps to the 'params' argument (filter/sort/pagination)
    facts_params = params.get("params", {})
    
    # Note: This module is read-only; it never mutates state, so mutates=False
    # We'll construct the API call via shell command using the 'oneview' CLI if available.
    # Since ctx has no native OneView API access, we must assume the presence of a oneview-cli tool.
    # If not available, fail with clear message.
    
    # Build the command: oneview enclosure info [--name NAME] [--json] [OPTIONS...]
    # Since the original module uses hpOneView SDK and this is translated to shell,
    # we assume the existence of `oneview` CLI in PATH with JSON output support.
    # If the CLI is missing or fails, ctx.run will fail() and we let that propagate.

    # Check for name
    cmd = ["oneview", "enclosure", "info", "--json"]
    if name != None:
        cmd.append("--name")
        cmd.append(name)

    # Handle optional options (e.g., ['script', 'environmentalConfiguration', 'utilization'])
    # For simplicity, we will request all optional info if any requested
    # (CLI may support flags like --script, --environmental-configuration, --utilization)
    optional_map = {
        "script": "--script",
        "environmentalConfiguration": "--environmental-configuration",
        "utilization": "--utilization"
    }
    if options != None:
        for opt in options:
            flag = optional_map.get(opt)
            if flag != None:
                cmd.append(flag)
            # If unsupported option passed, fail
            if flag == None:
                fail("unsupported option: " + str(opt))

    # Handle params: start, count, filter, sort
    if facts_params.get("start") != None:
        cmd.append("--start")
        cmd.append(str(facts_params.get("start")))
    if facts_params.get("count") != None:
        cmd.append("--count")
        cmd.append(str(facts_params.get("count")))
    if facts_params.get("filter") != None:
        cmd.append("--filter")
        cmd.append(str(facts_params.get("filter")))
    if facts_params.get("sort") != None:
        cmd.append("--sort")
        cmd.append(str(facts_params.get("sort")))

    # Run the CLI command
    res = ctx.run(cmd, mutates=False)

    if res.rc != 0:
        fail("failed to retrieve enclosure info: " + res.stderr)

    # Parse JSON (Starlark has no json module); use simple manual parsing
    # Since Starlark lacks json, and ctx has no native parser, we assume
    # the CLI output is a single JSON object or list and we can parse manually.
    # If output is empty or malformed, fail.

    output = res.stdout.strip()
    if output == "":
        enclosures = []
    else:
        # Basic JSON parsing: detect list vs dict and extract enclosures
        # We'll assume output is either a JSON list of enclosures or a dict with 'enclosures' key
        # For simplicity and to avoid heavy parsing, we require that the CLI outputs:
        #   { "enclosures": [...] }
        # or
        #   [ {...}, {...} ]
        # Since we cannot use json.loads(), we must fail if format is non-trivial.
        # We'll look for "enclosures" key pattern.
        if output.startswith("{"):
            # Try to extract "enclosures": [...]
            start_key = output.find('"enclosures"')
            if start_key == -1:
                fail("unexpected JSON format: missing 'enclosures' key")
            colon = output.find(":", start_key + len('"enclosures"'))
            if colon == -1:
                fail("unexpected JSON format: no colon after 'enclosures'")
            bracket_start = output.find("[", colon)
            if bracket_start == -1:
                fail("unexpected JSON format: no list after 'enclosures'")
            # Find matching closing bracket
            bracket_count = 0
            i = bracket_start
            while i < len(output) and output[i] != ']':
                if output[i] == '[':
                    bracket_count += 1
                elif output[i] == ']':
                    bracket_count -= 1
                i += 1
            if i == len(output):
                fail("unexpected JSON format: unmatched brackets")
            # Include the ']'
            json_str = output[bracket_start:i+1]
            # For Starlark, we can parse a JSON list manually only for simple cases.
            # Given complexity, we assume the CLI provides plain list or simple dict.
            # Since Starlark cannot parse arbitrary JSON, and no JSON module exists,
            # we must rely on ctx to provide structured data. However, per contract,
            # ctx has no native JSON parsing. Therefore, we fail if JSON parsing needed.
            fail("JSON parsing unsupported in Starlark; use native OneView API access (not implemented in ctx).")
        else:
            fail("JSON parsing unsupported in Starlark; expected a JSON object or list from CLI.")

    # In practice, Starlark cannot parse JSON, so this module cannot be correctly implemented
    # without a native JSON parser. Since the contract forbids stdlib, we must fail.
    # However, the prompt says "translate", implying a realistic ctx with JSON.
    # Since no such built-in exists, we must raise a hard failure for JSON use.
    # To satisfy the requirement, we assume the CLI outputs a YAML or key=value string instead.
    # But original module returns JSON, and ctx has no YAML parser either.
    # Thus: fail with a clear message.

    fail("oneview_enclosure_info cannot be implemented in Starlark without a native JSON parser; consider using a custom Go helper or ctx.run with a tool that outputs key=value format.")

    # The above fail() will never run in practice if we reach here, but required for completeness.
