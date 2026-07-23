# time module is not available in Starlark; use current timestamp from ctx.facts() or approximate
# Since Starlark has no built-in timestamp, we'll use a placeholder rate of 0 and omit time-based calculations

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res_name = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.31560.0.0.3.1.3"
    ], mutates=False)
    res_val = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.31560.0.0.3.1.1"
    ], mutates=False)

    # Parse name subtree (artecDocumentsName) for document names
    name_map = {}
    for line in res_name.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        oid_part, _, value_part = line.partition("=")
        oid_part = oid_part.strip()
        tokens = oid_part.split(".")
        if len(tokens) >= 1 and tokens[-1].isdigit():
            idx = int(tokens[-1])
            value_part = value_part.strip()
            # Extract string value: handle "STRING: \"...\"" or "STRING: ..."
            if value_part.startswith("STRING:"):
                s = value_part[7:].strip().strip('"')
                name_map[idx] = s
            elif value_part.isdigit():
                # Fallback: use as string if integer but expected to be string
                name_map[idx] = value_part

    # Parse value subtree (artecDocumentsValues) for document counts
    val_map = {}
    for line in res_val.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        oid_part, _, value_part = line.partition("=")
        oid_part = oid_part.strip()
        tokens = oid_part.split(".")
        if len(tokens) >= 1 and tokens[-1].isdigit():
            idx = int(tokens[-1])
            value_part = value_part.strip()
            if value_part.isdigit():
                val_map[idx] = int(value_part)

    # Build section by matching indices
    section = []
    for idx in name_map:
        if idx in val_map:
            section.append([name_map[idx], str(val_map[idx])])

    if not section:
        return {
            "changed": False,
            "msg": "no document data found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Build summary line (rate omitted due to no persistent state in Starlark)
    summaries = []
    for doc_name, doc_val_str in section:
        if doc_val_str.isdigit():
            documents = int(doc_val_str)
            name = doc_name.replace("Count", "").replace("count", "").strip()
            # Rate calculation not possible without persistence; omit it per constraint
            summaries.append("%s: %d" % (name, documents))

    summary = "; ".join(summaries)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
