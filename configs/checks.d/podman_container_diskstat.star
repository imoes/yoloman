_SI_UNITS = {
    "b": 1,
    "kb": 1000,
    "mb": 1000000,
    "gb": 1000000000,
    "tb": 1000000000000,
    "kib": 1024,
    "mib": 1048576,
    "gib": 1073741824,
    "tib": 1099511627776,
}

_PODMAN_ARGS = ["podman", "stats", "--no-stream", "--format", "json"]
_PODMAN_OK = [0, 1, 125, 126, 127]


def _parse_si_bytes(raw):
    s = raw.strip()
    if not s:
        return 0
    num_end = 0
    for idx in range(len(s)):
        if s[idx] in "0123456789.":
            num_end = idx + 1
        else:
            break
    if num_end == 0:
        return 0
    num_str = s[:num_end]
    unit = s[num_end:].strip().lower().replace(" ", "")
    dot = num_str.find(".")
    if dot == -1:
        int_part = int(num_str)
        frac_num = 0
        frac_den = 1
    else:
        ip_s = num_str[:dot]
        fp_s = num_str[dot + 1:]
        int_part = int(ip_s) if ip_s else 0
        frac_num = int(fp_s) if fp_s else 0
        frac_den = 1
        for _ in range(len(fp_s)):
            frac_den *= 10
    mult = _SI_UNITS.get(unit, 1)
    if frac_den == 1:
        return int_part * mult
    return int(int_part * mult + frac_num * mult / frac_den)


def _container_block_bytes(c):
    read_b = c.get("block_input")
    if read_b == None:
        read_b = c.get("BlockInput")
    write_b = c.get("block_output")
    if write_b == None:
        write_b = c.get("BlockOutput")
    if read_b != None and type(read_b) != "string":
        wb = int(write_b) if write_b != None else 0
        return int(read_b), wb
    bio = c.get("block_io")
    if bio == None:
        bio = c.get("BlockIO")
    if bio != None and type(bio) == "string" and "/" in bio:
        parts = bio.split("/")
        r = _parse_si_bytes(parts[0])
        w = _parse_si_bytes(parts[1]) if len(parts) >= 2 else 0
        return r, w
    return 0, 0


def _agg_block_bytes(containers):
    total_r = 0
    total_w = 0
    for c in containers:
        rb, wb = _container_block_bytes(c)
        total_r += rb
        total_w += wb
    return total_r, total_w


def _parse_stats_output(res):
    if res.rc != 0 or not res.stdout:
        return None
    out = res.stdout.strip()
    if not out:
        return None
    data = json.decode(out)
    if type(data) == "list":
        return data
    if type(data) == "dict":
        return [data]
    return None


def _fmt_throughput(bps):
    if bps >= 1073741824:
        major = bps // 1073741824
        frac = (bps % 1073741824) * 10 // 1073741824
        return "%d.%d GiB/s" % (major, frac)
    if bps >= 1048576:
        major = bps // 1048576
        frac = (bps % 1048576) * 10 // 1048576
        return "%d.%d MiB/s" % (major, frac)
    if bps >= 1024:
        major = bps // 1024
        frac = (bps % 1024) * 10 // 1024
        return "%d.%d KiB/s" % (major, frac)
    return "%d B/s" % bps


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(_PODMAN_ARGS, mutates=False, ok_codes=_PODMAN_OK)
        containers = _parse_stats_output(res)
        if containers == None or len(containers) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "SUMMARY",
                "params": {},
                "metrics": ["disk_read_throughput", "disk_write_throughput"],
            }]},
        }

    # First sample
    res1 = ctx.run(_PODMAN_ARGS, mutates=False, ok_codes=_PODMAN_OK)
    c1 = _parse_stats_output(res1)
    if c1 == None:
        return {
            "changed": False,
            "msg": "podman stats unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res1.stderr},
        }

    r1, w1 = _agg_block_bytes(c1)

    # 1-second gap to derive a rate from cumulative counters
    ctx.run(["sleep", "1"], mutates=False)

    # Second sample
    res2 = ctx.run(_PODMAN_ARGS, mutates=False, ok_codes=_PODMAN_OK)
    c2 = _parse_stats_output(res2)
    if c2 == None:
        return {
            "changed": False,
            "msg": "second podman stats sample unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    r2, w2 = _agg_block_bytes(c2)

    read_rate = max(0, r2 - r1)
    write_rate = max(0, w2 - w1)

    warn_read = params.get("read_throughput_warn")
    crit_read = params.get("read_throughput_crit")
    warn_write = params.get("write_throughput_warn")
    crit_write = params.get("write_throughput_crit")

    state = "OK"
    if crit_read != None and read_rate >= crit_read:
        state = "CRIT"
    elif warn_read != None and read_rate >= warn_read:
        state = "WARN"
    if crit_write != None and write_rate >= crit_write:
        state = "CRIT"
    elif warn_write != None and write_rate >= warn_write and state == "OK":
        state = "WARN"

    msg = "Read: %s, Write: %s" % (_fmt_throughput(read_rate), _fmt_throughput(write_rate))

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "disk_read_throughput": read_rate,
                "disk_write_throughput": write_rate,
            },
            "details": "",
        },
    }