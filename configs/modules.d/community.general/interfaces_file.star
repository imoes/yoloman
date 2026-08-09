def main(ctx, params):
    dest = params.get("dest", "/etc/network/interfaces")
    iface = params.get("iface")
    address_family = params.get("address_family")
    option = params.get("option")
    value = params.get("value")
    state = params.get("state", "present")
    backup = params.get("backup", False)

    # Validation
    if option != None and state == "present" and value == None:
        fail("Value must be set if option is defined and state is 'present'")
    if iface == None and option != None:
        fail("iface is required when option is specified")

    # Read current file
    if not ctx.file_exists(dest):
        fail("Error: file %s does not exist" % dest)
    content = ctx.file_read(dest)
    lines = content.split("\n")

    # Parse interfaces
    ifaces = {}
    current_iface = None
    current_family = None
    for l in lines:
        words = l.strip().split()
        if len(words) < 1:
            continue
        if words[0].startswith("#"):
            continue
        if words[0] == "iface" and len(words) >= 2:
            iface_name = words[1]
            curr = {
                "pre-up": [],
                "up": [],
                "down": [],
                "post-up": [],
                "address_family": words[2] if len(words) > 2 else None,
                "method": words[3] if len(words) > 3 else None,
            }
            ifaces[iface_name] = curr
            current_iface = iface_name
            current_family = curr["address_family"]
        elif words[0] in ["pre-up", "up", "down", "post-up"] and current_iface:
            val = l.strip()[len(words[0]):].strip()
            ifaces[current_iface][words[0]].append(val)
        elif words[0] not in ["mapping", "source", "source-dir", "source-directory", "auto"] and current_iface and len(words) >= 2:
            # Regular option
            opt_name = words[0]
            val = l.strip()[len(words[0]):].strip()
            if opt_name in ["pre-up", "up", "down", "post-up"]:
                ifaces[current_iface][opt_name].append(val)
            else:
                ifaces[current_iface][opt_name] = val

    # Filter iface lines for specific family if requested
    def get_iface_lines(target_iface, target_family):
        result = []
        for i, l in enumerate(lines):
            words = l.strip().split()
            if len(words) >= 2 and words[0] == "iface" and words[1] == target_iface:
                family = words[2] if len(words) > 2 else None
                if target_family == None or target_family == family:
                    result.append(i)
        return result

    changed = False
    if option != None:
        # Find interface lines
        iface_indices = get_iface_lines(iface, address_family)
        if len(iface_indices) == 0:
            fail("Error: interface %s%s not found" % (iface, " (family %s)" % address_family if address_family else ""))
        
        # Collect options for this interface
        options = []
        start_idx = iface_indices[0]
        end_idx = iface_indices[-1]
        for i in range(start_idx + 1, end_idx):
            l = lines[i].strip()
            if not l:
                continue
            words = l.split()
            if len(words) < 2:
                continue
            if words[0] in ["pre-up", "up", "down", "post-up", "method"]:
                opt_name = words[0]
                val = l[len(words[0]):].strip()
                options.append({"name": opt_name, "value": val, "line_index": i, "line": lines[i]})
            else:
                opt_name = words[0]
                val = l[len(words[0]):].strip()
                options.append({"name": opt_name, "value": val, "line_index": i, "line": lines[i]})

        if state == "present":
            # Check if option exists
            existing = [o for o in options if o["name"] == option]
            
            if len(existing) == 0:
                # Add new option at the end of interface section
                insert_idx = end_idx
                prefix = lines[insert_idx - 1][:len(lines[insert_idx - 1]) - len(lines[insert_idx - 1].lstrip())] if insert_idx > start_idx else "    "
                new_line = prefix + option + " " + str(value)
                lines.insert(insert_idx, new_line)
                changed = True
                options.append({"name": option, "value": str(value), "line_index": insert_idx, "line": new_line})
            else:
                # Update last matching option (unless it's a list option)
                if option in ["pre-up", "up", "down", "post-up"]:
                    # For list options, only add if value not present
                    vals = [o["value"] for o in existing]
                    if str(value) not in vals:
                        insert_idx = existing[-1]["line_index"] + 1
                        prefix = lines[insert_idx - 1][:len(lines[insert_idx - 1]) - len(lines[insert_idx - 1].lstrip())] if insert_idx > start_idx else "    "
                        new_line = prefix + option + " " + str(value)
                        lines.insert(insert_idx, new_line)
                        changed = True
                else:
                    # Update last occurrence
                    last = existing[-1]
                    if last["value"] != str(value):
                        old_line = last["line"]
                        old_val_pos = old_line.find(last["value"])
                        new_line = old_line[:old_val_pos] + str(value) + old_line[old_val_pos + len(last["value"]):]
                        lines[last["line_index"]] = new_line
                        changed = True
        elif state == "absent":
            # Remove matching option(s)
            to_remove = []
            if option in ["pre-up", "up", "down", "post-up"]:
                # If value specified, remove only matching ones
                if value != None:
                    to_remove = [o for o in existing if o["value"] == str(value)]
                else:
                    to_remove = existing
            else:
                to_remove = existing
            
            if len(to_remove) > 0:
                # Remove in reverse order to preserve indices
                # Build new list without the removed lines
                new_lines = []
                for i in range(len(lines)):
                    remove_this = False
                    for o in to_remove:
                        if o["line_index"] == i:
                            remove_this = True
                            break
                    if not remove_this:
                        new_lines.append(lines[i])
                lines = new_lines
                changed = True

    # Rebuild content
    new_content = "\n".join(lines)

    # Diff check
    if new_content == content:
        return {"changed": False, "msg": "No changes needed", "dest": dest, "ifaces": ifaces}

    # Check mode
    if ctx.check_mode:
        return {"changed": True, "msg": "would update " + dest, "dest": dest, "ifaces": ifaces}

    # Backup if requested
    if backup:
        backup_res = ctx.run(["cp", "-p", dest, dest + ".ansible_backup." + str(ctx.run(["date", "+%Y%m%d%H%M%S"]).stdout.strip())], mutates=False)
        # Backup doesn't affect changed status

    # Write file
    ctx.file_write(dest, new_content)

    # Update ifaces for return
    new_ifaces = {}
    current_iface = None
    current_family = None
    for l in lines:
        words = l.strip().split()
        if len(words) < 1:
            continue
        if words[0].startswith("#"):
            continue
        if words[0] == "iface" and len(words) >= 2:
            iface_name = words[1]
            curr = {
                "pre-up": [],
                "up": [],
                "down": [],
                "post-up": [],
                "address_family": words[2] if len(words) > 2 else None,
                "method": words[3] if len(words) > 3 else None,
            }
            new_ifaces[iface_name] = curr
            current_iface = iface_name
            current_family = curr["address_family"]
        elif words[0] in ["pre-up", "up", "down", "post-up"] and current_iface:
            val = l.strip()[len(words[0]):].strip()
            new_ifaces[current_iface][words[0]].append(val)
        elif words[0] not in ["mapping", "source", "source-dir", "source-directory", "auto"] and current_iface and len(words) >= 2:
            opt_name = words[0]
            val = l.strip()[len(words[0]):].strip()
            if opt_name in ["pre-up", "up", "down", "post-up"]:
                new_ifaces[current_iface][opt_name].append(val)
            else:
                new_ifaces[current_iface][opt_name] = val

    return {"changed": True, "msg": "updated " + dest, "dest": dest, "ifaces": new_ifaces}
