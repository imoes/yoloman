def main(ctx, params):
    domain = params["domain"]
    limit_type = params["limit_type"]
    limit_item = params["limit_item"]
    value = params["value"]
    use_max = params.get("use_max", False)
    use_min = params.get("use_min", False)
    backup = params.get("backup", False)
    dest = params.get("dest", "/etc/security/limits.conf")
    comment = params.get("comment", "")

    # Validate value for nice/priority items
    if limit_item in ["nice", "priority"]:
        val = int(value)
        if val < -20 or val > 19:
            fail("Value of %r for item %r is invalid. Value must be a number in the range -20 to 19 inclusive." % (value, limit_item))
    else:
        # Check if value is valid: unlimited, infinity, -1, or non-negative number
        if value not in ["unlimited", "infinity", "-1"]:
            val = int(value)
            if val < 0:
                fail("Value of %r for item %r is invalid. Value must either be 'unlimited', 'infinity' or -1, all of which indicate no limit, or a limit of 0 or larger." % (value, limit_item))

    # Check mutually exclusive options
    if use_max and use_min:
        fail("Cannot use use_min and use_max at the same time.")

    # Ensure dest file exists and is writable
    if not ctx.file_exists(dest):
        # Create parent directory if needed
        dest_dir = dest.rsplit("/", 1)[0]
        if dest_dir != "" and not ctx.file_exists(dest_dir):
            fail("directory %s does not exist" % dest_dir)
        # Create empty file
        ctx.file_write(dest, "")
        changed = True
    else:
        # Check write permission by checking file stat
        stat_info = ctx.stat(dest)
        if stat_info == None or not stat_info.get("exists", False):
            fail("file %s is not accessible" % dest)

    # Backup if requested (simplified placeholder)
    backup_file = None
    if backup:
        backup_file = dest  # In real scenario would include timestamp

    # Read current file content
    content = ctx.file_read(dest)
    lines = content.split("\n")

    # Process lines
    new_lines = []
    found = False
    new_value = value

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            new_lines.append(line)
            continue
        if stripped == "":
            new_lines.append(line)
            continue

        # Parse line
        parts = stripped.split()
        if len(parts) != 4:
            new_lines.append(line)
            continue

        line_domain = parts[0]
        line_type = parts[1]
        line_item = parts[2]
        actual_value = parts[3]

        # Check if this is the line we are modifying
        if line_domain == domain and line_type == limit_type and line_item == limit_item:
            found = True
            if actual_value == value:
                new_lines.append(line)
                continue

            # Handle use_max/use_min
            if use_max or use_min:
                actual_unlimited = actual_value in ["unlimited", "infinity", "-1"]
                new_unlimited = value in ["unlimited", "infinity", "-1"]

                if use_max:
                    if actual_unlimited:
                        new_value = actual_value
                    elif new_unlimited:
                        new_value = value
                    else:
                        new_value = str(max(int(value), int(actual_value)))
                elif use_min:
                    if actual_unlimited and new_unlimited:
                        new_value = actual_value
                    elif actual_unlimited:
                        new_value = value
                    elif new_unlimited:
                        new_value = actual_value
                    else:
                        new_value = str(min(int(value), int(actual_value)))

            # Only change if value differs
            if new_value != actual_value:
                # Preserve original comment if no new one provided
                orig_comment = ""
                if "#" in line:
                    orig_comment = line.split("#", 1)[1].strip()
                if not comment and orig_comment:
                    comment = orig_comment
                
                comment_part = ""
                if comment:
                    comment_part = "\t#" + comment
                
                new_line = domain + "\t" + limit_type + "\t" + limit_item + "\t" + new_value + comment_part + "\n"
                new_lines.append(new_line)
                comment = ""  # Clear comment after applying once
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)

    # If not found, add new entry
    if not found:
        comment_part = ""
        if comment:
            comment_part = "\t#" + comment
        new_line = domain + "\t" + limit_type + "\t" + limit_item + "\t" + new_value + comment_part + "\n"
        new_lines.append(new_line)

    # Determine if change needed
    new_content = "\n".join(new_lines)
    if new_content == content:
        return {"changed": False, "msg": "limits already correct"}

    # In check mode, just report what would change
    if ctx.check_mode:
        return {"changed": True, "msg": "would update limits"}

    # Write new content
    ctx.file_write(dest, new_content)

    result = {"changed": True, "msg": "limits updated"}
    if backup:
        result["backup_file"] = backup_file
    return result
