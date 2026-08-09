def main(ctx, params):
    path = params["path"]
    section = params.get("section")
    option = params.get("option")
    value = params.get("value")
    values_param = params.get("values")
    state = params.get("state", "present")
    exclusive = params.get("exclusive", True)
    backup = params.get("backup", False)
    no_extra_spaces = params.get("no_extra_spaces", False)
    ignore_spaces = params.get("ignore_spaces", False)
    allow_no_value = params.get("allow_no_value", False)
    modify_inactive_option = params.get("modify_inactive_option", True)
    create = params.get("create", True)
    follow = params.get("follow", False)

    # Validate required arguments
    if state == "present" and not allow_no_value and value == None and values_param == None:
        fail("Parameter 'value(s)' must be defined if state=present and allow_no_value=False.")
    if value != None and values_param != None:
        fail("Parameters 'value' and 'values' are mutually exclusive.")
    if values_param == None:
        values = []
    else:
        values = values_param
    if value != None:
        values = [value]

    # Read current file content
    file_exists = ctx.file_exists(path)
    if not file_exists:
        if not create:
            fail("Destination %s does not exist!" % path)

    if file_exists:
        content_str = ctx.file_read(path)
    else:
        content_str = ""

    # Parse content into lines (handle UTF-8 BOM by stripping it)
    if content_str.startswith("\ufeff"):
        content_str = content_str[1:]
    lines = content_str.splitlines()
    diff_before = "\n".join(lines)

    # Normalize lines list: ensure at least one line, and trailing newline
    if not lines or lines[-1] != "":
        lines.append("")
    if len(lines) == 1 and lines[0] == "":
        pass  # already one empty line, keep it
    elif lines[-1] != "":
        lines.append("")

    # Fake section names to simplify logic
    fake_section_name = "ad01e11446efb704fcdbdb21f2c43757423d91c5"
    all_lines = ["[%s]" % fake_section_name] + lines + ["["]

    # Use section name; if no section given, use fake
    if section == None:
        section = fake_section_name

    # Find section boundaries
    within_section = False
    section_start = -1
    section_end = -1
    for idx in range(len(all_lines)):
        line = all_lines[idx]
        stripped = line.strip()
        if stripped == "[%s]" % section:
            within_section = True
            section_start = idx
        elif stripped.startswith("[") and stripped.endswith("]"):
            if within_section:
                section_end = idx
                break

    # Default: if no section found, insert at beginning (after fake section)
    if section_start == -1:
        section_start = 1  # right after fake section
        section_end = 1

    before = all_lines[:section_start]
    section_lines = all_lines[section_start:section_end]
    after = all_lines[section_end:]

    changed = False
    msg = "OK"
    changed_lines = [0] * len(section_lines)

    # Assignment formatting
    if no_extra_spaces:
        assignment_format = "%s=%s\n"
    else:
        assignment_format = "%s = %s\n"

    # Helper to match active or commented option lines
    def match_opt(option, line):
        stripped = line.strip()
        if not stripped:
            return None
        # Check if the line starts with optional comment and contains the option followed by optional spaces, =, and optional value
        comment_prefix = ""
        rest = stripped
        if rest.startswith("#") or rest.startswith(";"):
            comment_prefix = rest[0]
            rest = rest[1:].lstrip(" \t")
        if not rest:
            return None
        eq_idx = rest.find("=")
        if eq_idx == -1:
            # No value
            if allow_no_value and rest == option:
                return {"comment": comment_prefix, "value": ""}
            return None
        key_part = rest[:eq_idx].rstrip()
        value_part = rest[eq_idx + 1:].lstrip()
        if key_part == option:
            return {"comment": comment_prefix, "value": value_part}
        return None

    def match_active_opt(option, line):
        stripped = line.strip()
        if not stripped:
            return None
        # No comment at start allowed
        if stripped.startswith("#") or stripped.startswith(";"):
            return None
        eq_idx = stripped.find("=")
        if eq_idx == -1:
            if allow_no_value and stripped == option:
                return {"value": ""}
            return None
        key_part = stripped[:eq_idx].rstrip()
        value_part = stripped[eq_idx + 1:].lstrip()
        if key_part == option:
            return {"value": value_part}
        return None

    # Deduplicate values
    values_unique = []
    for v in values:
        if v != None and v not in values_unique:
            values_unique.append(v)
    values = values_unique

    # Use correct match function based on modify_inactive_option
    if modify_inactive_option:
        match_func = match_opt
    else:
        match_func = match_active_opt

    # Processing state=present
    if state == "present" and option:
        for idx in range(len(section_lines)):
            line = section_lines[idx]
            m = match_func(option, line)
            if m:
                if values and m["value"] in values:
                    # Replace with existing value, then remove that value
                    matched = m["value"]
                    newline = assignment_format % (option, matched)
                    if ignore_spaces:
                        # Check if changing only spaces before/after =
                        old_m = match_opt(option, line)
                        new_m = match_opt(option, newline.rstrip("\n"))
                        if old_m and new_m:
                            if old_m["value"] == new_m["value"]:
                                # Same value, just spaces differ
                                continue
                    if section_lines[idx] != newline.rstrip("\n"):
                        section_lines[idx] = newline.rstrip("\n")
                        changed = True
                        msg = "option changed"
                    changed_lines[idx] = 1
                    # Remove matched value from list
                    values = [v for v in values if v != matched]
                elif not values and allow_no_value:
                    # Replace option with no value
                    newline = "%s\n" % option
                    if section_lines[idx] != newline.rstrip("\n"):
                        section_lines[idx] = newline.rstrip("\n")
                        changed = True
                        msg = "option changed"
                    changed_lines[idx] = 1
                    break

        if exclusive and not allow_no_value and len(values) > 0:
            # Override first unmatched line with remaining values
            for idx in range(len(section_lines)):
                if not changed_lines[idx] and match_func(option, section_lines[idx]):
                    newline = assignment_format % (option, values.pop(0))
                    if section_lines[idx] != newline.rstrip("\n"):
                        section_lines[idx] = newline.rstrip("\n")
                        changed = True
                        msg = "option changed"
                    changed_lines[idx] = 1
                    if not values:
                        break
            # Remove remaining option lines
            new_section = []
            new_changed = []
            for idx in range(len(section_lines)):
                line = section_lines[idx]
                m = match_active_opt(option, line)
                if m and not changed_lines[idx]:
                    changed = True
                    msg = "option changed"
                else:
                    new_section.append(line)
                    new_changed.append(changed_lines[idx])
            section_lines = new_section
            changed_lines = new_changed

        # Insert missing option lines
        # Insert before last non-blank/non-comment line of section
        insert_idx = len(section_lines)
        for idx in range(len(section_lines) - 1, -1, -1):
            line = section_lines[idx]
            stripped = line.strip()
            if stripped == "" or stripped.startswith("#") or stripped.startswith(";"):
                continue
            insert_idx = idx + 1
            break

        for v in reversed(values):
            if v != None:
                section_lines.insert(insert_idx, assignment_format % (option, v))
                changed = True
                msg = "option added"
            elif allow_no_value:
                section_lines.insert(insert_idx, "%s\n" % option)
                changed = True
                msg = "option added"

    # Processing state=absent
    if state == "absent":
        if option:
            if exclusive:
                # Delete all matching lines
                new_section = []
                for idx in range(len(section_lines)):
                    line = section_lines[idx]
                    m = match_active_opt(option, line)
                    if m:
                        changed = True
                        msg = "option changed"
                    else:
                        new_section.append(line)
                section_lines = new_section
            elif len(values) > 0:
                # Delete only specified option=value lines
                new_section = []
                for idx in range(len(section_lines)):
                    line = section_lines[idx]
                    m = match_active_opt(option, line)
                    if m and m["value"] in values:
                        changed = True
                        msg = "option changed"
                    else:
                        new_section.append(line)
                section_lines = new_section
        else:
            # Delete entire section
            if section_lines:
                section_lines = []
                changed = True
                msg = "section removed"

    # Reassemble all_lines
    all_lines = before + section_lines + after

    # Remove fake section lines
    all_lines = all_lines[1:len(all_lines)-1]

    # If section not found and state=present, add section
    if state == "present" and section != fake_section_name:
        if section_start == 1 and section_end == 1 and section_lines == []:
            # Section does not exist, insert after fake section
            section_lines = []
            if option and values:
                for v in values:
                    section_lines.append(assignment_format % (option, v))
            elif option and not values and allow_no_value:
                section_lines.append("%s\n" % option)
            # Insert between fake section and rest
            all_lines = ["[%s]" % fake_section_name] + ["[%s]" % section] + section_lines + all_lines[1:]
            changed = True
            msg = "section and option added"
        elif not section_lines and option and values:
            # Add lines to existing empty section
            for v in values:
                section_lines.append(assignment_format % (option, v))
            # Rebuild all_lines
            all_lines = before + section_lines + after
            changed = True
            msg = "section and option added"

    diff_after = "\n".join(all_lines)

    # Output diff if needed
    diff = {}
    if diff_before != diff_after:
        diff = {
            "before": diff_before + "\n",
            "after": diff_after + "\n",
            "before_header": path + " (content)",
            "after_header": path + " (content)",
        }

    backup_file = None
    if changed and not ctx.check_mode:
        # Write new content
        content_to_write = diff_after
        if not content_to_write.endswith("\n"):
            content_to_write += "\n"
        ctx.file_write(path, content_to_write)

        # Set attributes if needed (owner, group, mode, SELinux)
        mode = params.get("mode")
        owner = params.get("owner")
        group = params.get("group")
        if mode != None:
            # ctx.file_write does not support mode; use chmod via run
            chmod_res = ctx.run(["chmod", mode, path], mutates=True)
            if chmod_res.rc != 0:
                fail("Failed to set mode %s: %s" % (mode, chmod_res.stderr))

        if owner != None or group != None:
            chown_arg = ""
            if owner != None:
                chown_arg += owner
            if group != None:
                chown_arg += ":" + group
            chown_res = ctx.run(["chown", chown_arg, path], mutates=True)
            if chown_res.rc != 0:
                fail("Failed to set owner/group: %s" % chown_res.stderr)

        # SELinux attributes
        seuser = params.get("seuser")
        serole = params.get("serole")
        setype = params.get("setype")
        selevel = params.get("selevel")
        if seuser or serole or setype or selevel:
            # Use chcon if available
            chcon_args = ["chcon"]
            if seuser and seuser != "_default":
                chcon_args.extend(["-u", seuser])
            if serole and serole != "_default":
                chcon_args.extend(["-r", serole])
            if setype and setype != "_default":
                chcon_args.extend(["-t", setype])
            if selevel and selevel != "_default":
                chcon_args.extend(["-l", selevel])
            chcon_args.append(path)
            chcon_res = ctx.run(chcon_args, mutates=True)
            if chcon_res.rc != 0:
                fail("Failed to set SELinux context: %s" % chcon_res.stderr)

    return {"changed": changed, "msg": msg, "diff": diff}
