def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    
    LOCALE_SUPPORTED = "/var/lib/locales/supported.d/local"
    LOCALE_GEN = "/etc/locale.gen"
    SUPPORTED_LOCALES = "/usr/share/i18n/SUPPORTED"
    
    ubuntu_mode = ctx.file_exists(LOCALE_SUPPORTED)
    
    if not ubuntu_mode and not ctx.file_exists(LOCALE_GEN):
        fail(LOCALE_SUPPORTED + " and " + LOCALE_GEN + " are missing. Is the package locales installed?")
    
    locale_available = False
    
    if ubuntu_mode:
        locales_file = SUPPORTED_LOCALES
    else:
        locales_file = LOCALE_GEN
    
    if ctx.file_exists(locales_file):
        content = ctx.file_read(locales_file)
        lines = content.split("\n")
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if not line or line.startswith("#"):
                i = i + 1
                continue
            parts = line.split(None, 1)
            if len(parts) >= 1:
                locale_name = parts[0]
                norm_name = name
                replacements = [
                    (".utf8", ".UTF-8"),
                    (".eucjp", ".EUC-JP"),
                    (".iso885915", ".ISO-8859-15"),
                    (".cp1251", ".CP1251"),
                    (".koi8r", ".KOI8-R"),
                    (".armscii8", ".ARMSCII-8"),
                    (".euckr", ".EUC-KR"),
                    (".gbk", ".GBK"),
                    (".gb18030", ".GB18030"),
                    (".euctw", ".EUC-TW")
                ]
                j = 0
                while j < len(replacements):
                    norm_name = norm_name.replace(replacements[j][0], replacements[j][1])
                    j = j + 1
                if locale_name.lower() == norm_name.lower():
                    locale_available = True
                    break
            i = i + 1
    
    if not locale_available:
        res = ctx.run(["locale", "-a"], mutates=False)
        locale_lines = res.stdout.split("\n")
        i = 0
        while i < len(locale_lines):
            if locale_lines[i].strip() == name:
                locale_available = True
                break
            i = i + 1
    
    if not locale_available:
        fail("The locale you've entered is not available on your system.")
    
    if ubuntu_mode:
        current_content = ctx.file_read(LOCALE_SUPPORTED) if ctx.file_exists(LOCALE_SUPPORTED) else ""
        is_present = False
        lines = current_content.split("\n")
        i = 0
        while i < len(lines):
            if name in lines[i]:
                is_present = True
                break
            i = i + 1
    else:
        current_content = ctx.file_read(LOCALE_GEN) if ctx.file_exists(LOCALE_GEN) else ""
        is_present = False
        lines = current_content.split("\n")
        i = 0
        while i < len(lines):
            stripped = lines[i].strip()
            if not stripped or stripped.startswith("#"):
                i = i + 1
                continue
            if stripped.startswith(name + " ") or stripped.startswith(name + "\t"):
                is_present = True
                break
            i = i + 1
    
    if state == "present" and is_present:
        return {"changed": False, "msg": "Locale " + name + " is already present"}
    if state == "absent" and not is_present:
        return {"changed": False, "msg": "Locale " + name + " is already absent"}
    
    if ctx.check_mode:
        if state == "present":
            return {"changed": True, "msg": "would create locale " + name}
        else:
            return {"changed": True, "msg": "would remove locale " + name}
    
    if ubuntu_mode:
        if state == "present":
            res = ctx.run(["locale-gen", name], mutates=True)
            if res.rc != 0:
                fail("failed to create locale " + name + ": " + res.stderr)
        else:
            if ctx.file_exists(LOCALE_SUPPORTED):
                current_content = ctx.file_read(LOCALE_SUPPORTED)
                new_lines = []
                lines = current_content.split("\n")
                i = 0
                while i < len(lines):
                    line = lines[i].strip()
                    if line and not line.startswith(name + " ") and not line.startswith(name + "\t"):
                        new_lines.append(lines[i])
                    i = i + 1
                new_content = "\n".join(new_lines)
                if new_content != current_content:
                    ctx.file_write(LOCALE_SUPPORTED, new_content)
            res = ctx.run(["locale-gen", "--purge"], mutates=True)
            if res.rc != 0:
                fail("failed to purge locales: " + res.stderr)
    else:
        current_content = ctx.file_read(LOCALE_GEN)
        new_lines = []
        found = False
        lines = current_content.split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            if stripped.startswith("# " + name + " ") or stripped.startswith("# " + name + "\t"):
                if state == "present":
                    new_lines.append(name + stripped[2:])
                    found = True
                else:
                    new_lines.append(line)
            elif stripped.startswith(name + " ") or stripped.startswith(name + "\t"):
                if state == "present":
                    new_lines.append(line)
                    found = True
                else:
                    new_lines.append("# " + stripped)
                    found = True
            else:
                new_lines.append(line)
            i = i + 1
        
        if state == "present" and not found:
            new_lines.append(name + " UTF-8")
        
        new_content = "\n".join(new_lines)
        
        if new_content != current_content:
            ctx.file_write(LOCALE_GEN, new_content)
        
        res = ctx.run(["locale-gen"], mutates=True)
        if res.rc != 0:
            fail("failed to regenerate locales: " + res.stderr)
    
    if state == "present":
        if ubuntu_mode:
            current_content = ctx.file_read(LOCALE_SUPPORTED) if ctx.file_exists(LOCALE_SUPPORTED) else ""
            is_present_now = False
            lines = current_content.split("\n")
            i = 0
            while i < len(lines):
                if name in lines[i]:
                    is_present_now = True
                    break
                i = i + 1
            if not is_present_now:
                fail("locale " + name + " was not created")
        else:
            current_content = ctx.file_read(LOCALE_GEN) if ctx.file_exists(LOCALE_GEN) else ""
            is_present_now = False
            lines = current_content.split("\n")
            i = 0
            while i < len(lines):
                stripped = lines[i].strip()
                if not stripped or stripped.startswith("#"):
                    i = i + 1
                    continue
                if stripped.startswith(name + " ") or stripped.startswith(name + "\t"):
                    is_present_now = True
                    break
                i = i + 1
            if not is_present_now:
                fail("locale " + name + " was not activated")
    
    return {"changed": True, "msg": "locale " + name + " " + ("created" if state == "present" else "removed")}
