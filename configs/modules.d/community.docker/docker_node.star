def main(ctx, params):
    hostname = params["hostname"]
    availability = params.get("availability")
    role = params.get("role")
    labels = params.get("labels")
    labels_state = params.get("labels_state", "merge")
    labels_to_remove = params.get("labels_to_remove")

    # Get node info via docker node inspect with raw JSON
    inspect_cmd = ["docker", "node", "inspect", hostname]
    res = ctx.run(inspect_cmd)
    if res.rc != 0:
        if "no such node" in res.stderr.lower() or "swarm node not found" in res.stderr.lower() or "this node is not part of a swarm" in res.stderr.lower():
            fail("This node is not part of a swarm.")
        fail("Failed to get node information for " + hostname + ": " + res.stderr)

    stdout = res.stdout.strip()
    if not stdout.startswith('['):
        fail("Unexpected output format from docker node inspect: does not start with '['")
    start_idx = stdout.find('{')
    end_idx = stdout.rfind('}')
    if start_idx == -1 or end_idx == -1 or end_idx <= start_idx:
        fail("Failed to parse JSON from docker node inspect output")
    json_str = stdout[start_idx:end_idx+1]

    # Manual JSON field extraction helpers
    def _get_str_field(obj, key):
        prefix = '"' + key + '": "'
        idx = obj.find(prefix)
        if idx == -1:
            return None
        rest = obj[idx + len(prefix):]
        end = rest.find('"')
        if end == -1:
            return None
        return rest[:end]

    def _extract_spec(obj):
        spec_start = obj.find('"Spec": {')
        if spec_start == -1:
            return None
        depth = 0
        for i in range(spec_start, len(obj)):
            if obj[i] == '{':
                depth += 1
            elif obj[i] == '}':
                depth -= 1
                if depth == 0:
                    return obj[spec_start:i+1]
        return None

    spec_str = _extract_spec(json_str)
    if spec_str == None:
        fail("Failed to extract Spec from node inspect output")

    current_role = _get_str_field(spec_str, "Role")
    current_availability = _get_str_field(spec_str, "Availability")

    # Parse labels object manually
    labels_start = spec_str.find('"Labels": {')
    current_labels = {}
    if labels_start != -1:
        depth = 0
        start = labels_start
        for i in range(start, len(spec_str)):
            if spec_str[i] == '{':
                depth += 1
            elif spec_str[i] == '}':
                depth -= 1
                if depth == 0:
                    labels_str = spec_str[start+1:i]  # remove outer braces
                    # Parse key-value pairs: "key": "value"
                    idx = 0
                    while True:
                        key_start = labels_str.find('"', idx)
                        if key_start == -1:
                            break
                        key_end = labels_str.find('"', key_start+1)
                        if key_end == -1:
                            break
                        key = labels_str[key_start+1:key_end]
                        colon = labels_str.find(':', key_end)
                        if colon == -1:
                            break
                        val_start = labels_str.find('"', colon+1)
                        if val_start == -1:
                            idx = key_end + 1
                            continue
                        val_end = labels_str.find('"', val_start+1)
                        if val_end == -1:
                            idx = key_end + 1
                            continue
                        val = labels_str[val_start+1:val_end]
                        current_labels[key] = val
                        idx = val_end + 1
                    break

    # Determine required changes
    changed = False
    new_role = current_role
    new_availability = current_availability
    new_labels = dict(current_labels) if current_labels else {}

    if role != None and role != current_role:
        new_role = role
        changed = True
    if availability != None and availability != current_availability:
        new_availability = availability
        changed = True

    if labels_state == "replace":
        if labels == None or len(labels) == 0:
            if len(current_labels) > 0:
                changed = True
            new_labels = {}
        elif labels != None:
            if dict(current_labels) != labels:
                changed = True
                new_labels = dict(labels)
    elif labels_state == "merge":
        if labels != None:
            for key, value in labels.items():
                if new_labels.get(key) != value:
                    new_labels[key] = value
                    changed = True
        if labels_to_remove != None:
            for key in labels_to_remove:
                if labels != None and key in labels:
                    continue  # Keep value from labels
                if key in new_labels:
                    new_labels.pop(key)
                    changed = True

    # Check mode: return prediction
    if ctx.check_mode:
        return {"changed": changed, "msg": ("would update node " + hostname) if changed else "node already in desired state"}

    if not changed:
        return {"changed": False, "msg": "node already in desired state"}

    # Get version index from original inspect JSON
    version_idx = None
    version_start = json_str.find('"Version": {')
    if version_start != -1:
        idx_field = json_str.find('"Index": ', version_start)
        if idx_field != -1:
            idx_field += len('"Index": ')
            val = ""
            while idx_field < len(json_str) and json_str[idx_field].isdigit():
                val += json_str[idx_field]
                idx_field += 1
            if val:
                version_idx = int(val)

    if version_idx == None:
        fail("Failed to get node version index for update")

    # Build update command
    update_cmd = ["docker", "node", "update", hostname]
    update_cmd.append("--version")
    update_cmd.append(str(version_idx))

    if availability != None:
        update_cmd.append("--availability")
        update_cmd.append(availability)
    if role != None:
        update_cmd.append("--role")
        update_cmd.append(role)

    if labels_state == "replace":
        if labels == None or len(labels) == 0:
            for key in current_labels:
                update_cmd.append("--label-rm")
                update_cmd.append(key)
        elif labels != None:
            # Remove existing labels first
            for key in current_labels:
                update_cmd.append("--label-rm")
                update_cmd.append(key)
            # Add new labels
            for key, value in labels.items():
                update_cmd.append("--label-add")
                update_cmd.append(key + "=" + value)
    elif labels_state == "merge":
        if labels_to_remove != None:
            for key in labels_to_remove:
                if labels != None and key in labels:
                    continue
                update_cmd.append("--label-rm")
                update_cmd.append(key)
        if labels != None:
            for key, value in labels.items():
                update_cmd.append("--label-add")
                update_cmd.append(key + "=" + value)

    res = ctx.run(update_cmd, mutates=True)
    if res.rc != 0:
        fail("Failed to update node " + hostname + ": " + res.stderr)

    # Inspect again to get updated info
    res = ctx.run(["docker", "node", "inspect", hostname])
    if res.rc != 0:
        fail("Failed to get updated node information for " + hostname + ": " + res.stderr)

    stdout = res.stdout.strip()
    if not stdout.startswith('['):
        fail("Unexpected output format from docker node inspect after update")
    start_idx = stdout.find('{')
    end_idx = stdout.rfind('}')
    if start_idx == -1 or end_idx == -1 or end_idx <= start_idx:
        fail("Failed to parse JSON from docker node inspect output after update")
    updated_json = stdout[start_idx:end_idx+1]

    return {"changed": True, "msg": "updated node " + hostname, "data": {"node": updated_json}}
