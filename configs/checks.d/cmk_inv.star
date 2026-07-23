FAIL_STATES = {0: "OK", 1: "WARN", 2: "CRIT"}

def _fail_state(level):
    return FAIL_STATES.get(level, "WARN")

def _read_dmi(ctx, field):
    path = "/sys/class/dmi/id/" + field
    if ctx.file_exists(path):
        return ctx.file_read(path).strip()
    return ""

def _count_nonempty(text):
    count = 0
    for line in text.splitlines():
        if line.strip():
            count += 1
    return count

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "fail_status": 1,
                        "hw_changes": 0,
                        "sw_changes": 0,
                        "sw_missing": 0,
                        "nw_changes": 0,
                    },
                    "metrics": ["sw_packages", "nw_interfaces"],
                },
            ]},
        }

    fail_status = params.get("fail_status", 1)

    vendor   = _read_dmi(ctx, "sys_vendor")
    product  = _read_dmi(ctx, "product_name")
    bios_ver = _read_dmi(ctx, "bios_version")
    bios_date = _read_dmi(ctx, "bios_date")

    sw_count = 0
    facts = ctx.facts()
    os_family = facts.get("os_family", "")

    if os_family == "debian":
        sw_res = ctx.run(
            ["dpkg-query", "-W", "-f=${Package}\n"],
            mutates=False, ok_codes=[0, 1],
        )
        if sw_res.rc == 0:
            sw_count = _count_nonempty(sw_res.stdout)
    elif os_family == "redhat" or os_family == "suse":
        sw_res = ctx.run(
            ["rpm", "-qa", "--queryformat", "%{NAME}\n"],
            mutates=False, ok_codes=[0, 1],
        )
        if sw_res.rc == 0:
            sw_count = _count_nonempty(sw_res.stdout)

    nw_res = ctx.run(["ip", "-o", "link", "show"], mutates=False, ok_codes=[0, 1])
    if nw_res.rc != 0:
        return {
            "changed": False,
            "msg": "network inventory unavailable: " + nw_res.stderr.strip(),
            "data": {
                "state": _fail_state(fail_status),
                "metrics": {"sw_packages": sw_count, "nw_interfaces": 0},
                "details": nw_res.stderr.strip(),
            },
        }
    nw_count = _count_nonempty(nw_res.stdout)

    hw_parts = []
    if vendor:
        hw_parts.append(vendor)
    if product:
        hw_parts.append(product)
    bios_label = ""
    if bios_ver:
        bios_label = "BIOS " + bios_ver
        if bios_date:
            bios_label = bios_label + " " + bios_date
        hw_parts.append(bios_label)
    hw_summary = ", ".join(hw_parts)

    msg = "SW packages: %d, Interfaces: %d" % (sw_count, nw_count)
    if hw_summary:
        msg = hw_summary + " — " + msg

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {
                "sw_packages": sw_count,
                "nw_interfaces": nw_count,
            },
            "details": hw_summary,
        },
    }