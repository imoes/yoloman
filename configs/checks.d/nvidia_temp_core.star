# Checkmk check: nvidia_temp_core
# Translated to read-only Starlark. Reads the same on-host source the
# Checkmk agent plugin would (nvidia-smi), enumerates core temperature
# sensors in discovery and grades temperature in check mode.

def _format_nvidia_name(identifier):
    identifier = identifier.replace("Temp", "")
    if identifier == "GPUCore":
        return "GPU NVIDIA"
    return "System NVIDIA %s" % identifier

def _discover_nvidia_temp(core, section):
    out = []
    for line in section:
        line_san = line[0].strip(":")
        if line_san.lower().endswith("temp"):
            if core == (line_san == "GPUCoreTemp"):
                out.append(_format_nvidia_name(line_san))
    return out

def _get_nvidia_section(ctx):
    res = ctx.run(
        ["nvidia-smi", "--query-gpu=name,temperature.gpu", "--format=csv,noheader"],
        mutates=False,
    )
    if res.rc == 127:
        fail("nvidia-smi binary not found")
    if res.rc != 0:
        fail("nvidia-smi failed: %s" % res.stderr)
    section = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        if len(parts) < 2:
            continue
        section.append([parts[0].strip(), parts[1].strip()])
    return section

def main(ctx, params):
    if params.get("_discover"):
        section = _get_nvidia_section(ctx)
        items = _discover_nvidia_temp(True, section)
        discovery = []
        for name in items:
            discovery.append({
                "item": name,
                "params": {"levels": (90.0, 95.0)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _get_nvidia_section(ctx)
    value = None
    for line in section:
        formatted = _format_nvidia_name(line[0].strip(":"))
        if formatted == item or item == line[0].strip(":"):
            value = line[1]
            break
    if value == None:
        return {
            "changed": False,
            "msg": "no nvidia core temperature sensor found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = int(value) if value.isdigit() else 0
    levels = params.get("levels", (90.0, 95.0))
    warn = levels[0] if len(levels) > 0 else 90.0
    crit = levels[1] if len(levels) > 1 else 95.0
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "%s temperature: %dC" % (item, temp),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "",
        },
    }