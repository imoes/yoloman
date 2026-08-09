def main(ctx, params):
    # Gather facts for OS detection
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    if os_family != "smartos":
        fail("This module only runs on SmartOS")

    filters = params.get("filters")
    if filters == None:
        filters = ""

    # Prepare imgadm list command
    cmd = ["imgadm", "list", "-j"]
    if filters != "":
        cmd.append(filters)

    # Execute imgadm list -j
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to get SmartOS images: " + res.stderr)

    # Use Python to parse JSON output (SmartOS includes Python)
    python_script = """
import json, sys
data = json.loads(sys.stdin.read())
result = {}
for img in data:
    uuid = img['manifest']['uuid']
    manifest = dict(img['manifest'])
    for k in ['clones', 'source', 'zpool']:
        if k in img:
            manifest[k] = img[k]
    result[uuid] = manifest
print(json.dumps(result))
"""

    # Write script to temp file
    tmp_script = "/tmp/smartos_image_parser_" + str(facts.get("hostname", "host")) + ".py"
    ctx.file_write(tmp_script, python_script, mode="0644")

    # Run Python script with imgadm output piped to stdin
    # Use /bin/sh -c to enable piping
    shell_cmd = ['/bin/sh', '-c', 'imgadm list -j' + (' ' + filters if filters else '') + ' | python ' + tmp_script]
    res_python = ctx.run(shell_cmd, mutates=False)
    
    # Clean up script file
    ctx.run(['/bin/sh', '-c', 'rm -f "%s"' % tmp_script], mutates=True)

    if res_python.rc != 0:
        fail("Failed to parse image JSON: " + res_python.stderr)

    # Since SmartOS has jq available in most cases, try jq first for reliable parsing
    jq_cmd = ['/bin/sh', '-c', 'which jq > /dev/null 2>&1 && echo found || echo notfound']
    res_which_jq = ctx.run(jq_cmd, mutates=False)
    use_jq = res_which_jq.stdout.strip() == "found"

    if use_jq:
        # Use jq to convert JSON to a list of JSON objects for easier parsing
        jq_filter = '.[] | {uuid: .manifest.uuid, data: .}'
        jq_cmd2 = ['/bin/sh', '-c', 'imgadm list -j' + (' ' + filters if filters else '') + ' | jq -c "' + jq_filter + '"']
        res_jq = ctx.run(jq_cmd2, mutates=False)
        if res_jq.rc != 0:
            fail("Failed to parse image JSON with jq: " + res_jq.stderr)
        output = res_jq.stdout
    else:
        # Fallback: use Python to output newline-delimited JSON with uuid as key
        res = ctx.run(["imgadm", "list", "-j"], mutates=False)
        if res.rc != 0:
            fail("Failed to get SmartOS images: " + res.stderr)
        output = res.stdout

    # Parse JSON manually for output compatibility
    # We'll build a dict using uuids found in the output
    images_dict = {}

    if use_jq:
        lines = output.split("\n")
        for line in lines:
            if line.strip() == "":
                continue
            # Extract uuid: look for "uuid":"..." in the line
            start = line.find('"uuid":"') + len('"uuid":"')
            if start < len('"uuid":"'):
                continue
            end = line.find('"', start)
            if end == -1:
                continue
            uuid = line[start:end]
            # Extract the 'data' field value — the entire original object
            data_start = line.find('"data":{') + len('"data":{')
            if data_start < len('"data":{'):
                continue
            # Find matching closing brace — approximate by counting braces
            brace_count = 0
            pos = data_start
            while pos < len(line) and brace_count >= 0:
                if line[pos] == '{':
                    brace_count += 1
                elif line[pos] == '}':
                    brace_count -= 1
                pos += 1
            json_str = line[data_start:pos-1]
            images_dict[uuid] = "{" + json_str + "}"
    else:
        # Try to extract uuids from raw JSON
        # This is fragile but necessary without jq
        lines = output.split("\n")
        # Expecting a single-line JSON array or multi-line
        content = "".join(lines)
        # Simple extraction: find "uuid":"..." pairs
        idx = 0
        while True:
            start = content.find('"uuid":"', idx)
            if start == -1:
                break
            start += len('"uuid":"')
            end = content.find('"', start)
            if end == -1:
                break
            uuid = content[start:end]
            # Find start of this image object
            obj_start = content.rfind("{", 0, start - len('"uuid":"') - 1)
            if obj_start == -1:
                obj_start = content.find("{", start)
            # Find end
            brace_count = 0
            pos = obj_start
            found = False
            while pos < len(content) and not found:
                if content[pos] == '{':
                    brace_count += 1
                elif content[pos] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        images_dict[uuid] = content[obj_start:pos+1]
                        found = True
                pos += 1

    return {
        "changed": False,
        "msg": "Retrieved SmartOS image information",
        "data": {"smartos_images": images_dict}
    }
