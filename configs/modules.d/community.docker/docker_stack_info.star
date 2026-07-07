def main(ctx, params):
    # Build docker CLI command arguments
    args = ["docker", "stack", "ls", "--format={{json .}}"]

    # Execute read-only command to list stacks
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        fail("docker stack ls failed: " + res.stderr)

    # Parse output (each line is a JSON object)
    results = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        entry = {}
        # Remove outer braces
        content = line[1:-1].strip()
        if content:
            # Split by comma (simple case; handles typical docker output)
            pairs = []
            depth = 0
            current = ""
            for ch in content:
                if ch in "{[":
                    depth += 1
                elif ch in "}]":
                    depth -= 1
                if ch == "," and depth == 0:
                    pairs.append(current.strip())
                    current = ""
                else:
                    current += ch
            if current.strip():
                pairs.append(current.strip())

            for pair in pairs:
                if ":" not in pair:
                    continue
                key, val = pair.split(":", 1)
                key = key.strip().strip('"')
                val = val.strip()
                # Strip quotes from string values
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                # Convert numbers if possible
                elif val.isdigit():
                    val = int(val)
                elif val.replace('.', '', 1).isdigit():
                    val = float(val)
                entry[key] = val
        results.append(entry)

    return {"changed": False, "msg": "retrieved docker stack info", "data": {"results": results}}
