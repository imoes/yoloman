# yoloman.benchmark — one run of one fixed workload, returned as a number with its unit.
#
# One call is ONE run on purpose: an experiment alternates baseline and
# candidate (A/B/A/B) so that slow drift (thermal, page cache, a neighbour VM)
# lands on both sides instead of looking like an effect. Repetition and the
# verdict live in Bossman (services/tuning_experiments.py), not here.
#
# Every number carries what it is: metric, unit, higher_is_better, tool,
# tool version and the exact command, so a result can be re-run by hand.

_PROFILES = {
    "sched_latency": {"binary": "cyclictest", "metric": "wakeup_latency_p99", "unit": "us", "higher_is_better": False},
    "sched_throughput": {"binary": "hackbench", "metric": "hackbench_time", "unit": "s", "higher_is_better": False},
    "cpu": {"binary": "stress-ng", "metric": "matrixprod_bogo_ops_per_s", "unit": "ops/s", "higher_is_better": True},
    "memory": {"binary": "sysbench", "metric": "memory_bandwidth", "unit": "MiB/s", "higher_is_better": True},
    "io_randread": {"binary": "fio", "metric": "randread_4k_iops", "unit": "IOPS", "higher_is_better": True},
}
# Which package holds a tool, per OS family where it differs. Fedora/RHEL's rt-tests contains no binaries —
# cyclictest and hackbench are in realtime-tests (measured on Fedora 44).
_PKG_HINT = {"cyclictest": "rt-tests", "hackbench": "rt-tests", "stress-ng": "stress-ng", "sysbench": "sysbench", "fio": "fio"}
_PKG_HINT_BY_FAMILY = {"redhat": {"cyclictest": "realtime-tests", "hackbench": "realtime-tests"}}
_SCRATCH = "yoloman-benchmark.fio"


def main(ctx, params):
    profile = params.get("profile", "")
    if profile not in _PROFILES:
        fail("profile must be one of %s, got %r" % (", ".join(sorted(_PROFILES.keys())), profile))
    duration = int(params.get("duration", 20))
    if duration < 5 or duration > 300:
        fail("duration must be within 5..300 seconds, got %d" % duration)
    p = _PROFILES[profile]
    path = params.get("path", "/var/tmp")
    if profile == "io_randread" and (not path.startswith("/") or ".." in path or not ctx.file_exists(path)):
        fail("path must be an existing absolute directory, got %r" % path)

    which = ctx.run(["sh", "-c", 'command -v "$1"', "sh", p["binary"]])
    if which.rc != 0 or not which.stdout.strip():
        family = ctx.facts().get("os_family", "")
        pkg = _PKG_HINT_BY_FAMILY.get(family, {}).get(p["binary"], _PKG_HINT[p["binary"]])
        fail("tool_unavailable: %s is not installed (usually in the package %s)" % (p["binary"], pkg))
    binary = which.stdout.strip()
    argv = _argv(profile, binary, duration, path)
    # On systemd, the workload runs as its own transient unit, not as a child of the agent: a child would inherit
    # the agent unit's seccomp filter (RestrictRealtime=true made cyclictest fail with "Unable to change scheduling
    # policy" even as root) and be measured inside the agent's cgroup and its limits.
    #
    # It is started --no-block and then waited for: `systemd-run --wait/--pipe` from inside the agent's unit failed
    # on systemd 259 (Fedora 44) with "Connection timed out" for EVERY transient service, while --no-block worked
    # (measured 2026-10-18); systemd 257 (Debian 13) accepted both. Output goes to files under /run.
    init = ((ctx.facts().get("kernel_caps") or {}).get("init_system") or {}).get("state")
    isolated = init == "systemd"
    out = {
        "profile": profile, "metric": p["metric"], "unit": p["unit"], "higher_is_better": p["higher_is_better"],
        "tool": p["binary"], "tool_version": _version(ctx, p["binary"], binary), "command": " ".join(argv),
        "duration_s": duration, "cpus": _cpus(ctx),
        "isolation": "transient systemd unit" if isolated else "child of the agent",
    }
    if ctx.check_mode:
        return {"changed": True, "msg": "would run: " + out["command"], "data": out}

    if isolated:
        r = _run_isolated(ctx, profile, argv, duration)
    else:
        res = ctx.run(argv, mutates = True)
        r = {"rc": res.rc, "stdout": res.stdout, "stderr": res.stderr}
    if profile == "io_randread":
        ctx.run(["rm", "-f", path.rstrip("/") + "/" + _SCRATCH], mutates = True)
    if r["rc"] != 0:
        fail("%s failed (rc %d): %s" % (p["binary"], r["rc"], (r["stderr"] or r["stdout"])[-400:]))
    value, extra = _parse(ctx, profile, r["stdout"], r["stderr"])
    if value == None:
        fail("could not read %s from %s output: %s" % (p["metric"], p["binary"], (r["stdout"] + r["stderr"])[-400:]))
    out["value"] = value
    out.update(extra)
    return {"changed": True, "msg": "%s = %s %s" % (p["metric"], value, p["unit"]), "data": out}


_WAIT_UNIT = ('u=$1; while :; do a=$(systemctl show -p ActiveState --value "$u"); ' +
              's=$(systemctl show -p SubState --value "$u"); ' +
              '[ "$a" = failed ] && break; [ "$s" = exited ] && break; [ "$a" = inactive ] && break; sleep 1; done')


def _run_isolated(ctx, profile, argv, duration):
    """Run argv as a transient service, wait for it to end, return {rc, stdout, stderr}."""
    stamp = ctx.run(["date", "+%s%N"]).stdout.strip()
    unit = "yoloman-benchmark-%s-%s" % (profile.replace("_", "-"), stamp)
    outf = "/run/%s.out" % unit
    errf = "/run/%s.err" % unit
    start = ctx.run(["systemd-run", "--no-block", "--quiet", "--unit=" + unit, "-p", "RestrictRealtime=no",
                     "-p", "RemainAfterExit=yes", "-p", "StandardOutput=file:" + outf, "-p", "StandardError=file:" + errf,
                     "--description=yoloman.benchmark " + profile] + argv, mutates = True)
    if start.rc != 0:
        fail("starting the benchmark unit failed: %s" % start.stderr)
    ctx.run(["timeout", str(duration + 300), "sh", "-c", _WAIT_UNIT, "sh", unit + ".service"])
    status = ctx.run(["systemctl", "show", "-p", "ExecMainStatus", "--value", unit + ".service"]).stdout.strip()
    stdout = ctx.file_read(outf) if ctx.file_exists(outf) else ""
    stderr = ctx.file_read(errf) if ctx.file_exists(errf) else ""
    ctx.run(["systemctl", "stop", unit + ".service"], mutates = True)
    ctx.run(["systemctl", "reset-failed", unit + ".service"], mutates = True, ok_codes = [0, 1])
    ctx.run(["rm", "-f", outf, errf], mutates = True)
    return {"rc": int(status) if status.isdigit() else 1, "stdout": stdout, "stderr": stderr}


def _argv(profile, binary, duration, path):
    if profile == "sched_latency":
        # One measuring thread per CPU, 1 ms interval, histogram up to 10 ms (for the p99). SCHED_OTHER on
        # purpose: the fair class and sched_ext schedule exactly these tasks (real-time tasks bypass both),
        # and it needs no CAP_SYS_NICE / mlock, so the agent measures what a tuning change can move.
        return [binary, "-q", "-S", "--policy=other", "-i", "1000", "-D", str(duration), "-h", "10000"]
    if profile == "sched_throughput":
        return [binary, "-g", "10", "-l", "2000"]
    if profile == "cpu":
        return [binary, "--cpu", "0", "--cpu-method", "matrixprod", "--metrics-brief", "-t", "%ds" % duration]
    if profile == "memory":
        return [binary, "memory", "--memory-total-size=1000T", "--time=%d" % duration, "run"]
    return [binary, "--name=yoloman", "--filename=" + path.rstrip("/") + "/" + _SCRATCH, "--size=256M",
            "--rw=randread", "--bs=4k", "--direct=1", "--ioengine=psync", "--runtime=%d" % duration,
            "--time_based", "--output-format=json"]


def _version(ctx, name, binary):
    flag = {"cyclictest": "--help", "hackbench": "--help"}.get(name, "--version")
    r = ctx.run([binary, flag], ok_codes = [0, 1, 2])
    text = (r.stdout + "\n" + r.stderr).strip()
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:120]
    return "unknown"


def _cpus(ctx):
    r = ctx.run(["nproc"])
    return int(r.stdout.strip()) if r.rc == 0 and r.stdout.strip().isdigit() else None


def _num(s):
    s = s.strip().replace(",", "")
    whole, _, frac = s.partition(".")
    if not whole.isdigit() or (frac and not frac.isdigit()):
        return None
    return float(s)


def _parse(ctx, profile, stdout, stderr):
    if profile == "sched_throughput":
        for line in stdout.splitlines():
            if line.strip().startswith("Time:"):
                return _num(line.strip()[len("Time:"):]), {}
        return None, {}
    if profile == "cpu":
        # stress-ng --metrics-brief: "stress-ng: metrc: [123] cpu  41234  20.00  ...  2061.70  ..." — the
        # columns are bogo ops, real time, usr time, sys time, bogo ops/s (real time), bogo ops/s (usr+sys).
        for line in (stderr + "\n" + stdout).splitlines():
            parts = line.split()
            if "cpu" in parts:
                i = parts.index("cpu")
                nums = [_num(x) for x in parts[i + 1:]]
                if len(nums) >= 5 and nums[4] != None:
                    return nums[4], {"bogo_ops": nums[0]}
        return None, {}
    if profile == "memory":
        for line in stdout.splitlines():
            if "MiB/sec" in line and "(" in line:
                inner = line[line.rfind("(") + 1:]
                return _num(inner.split()[0]), {}
        return None, {}
    if profile == "io_randread":
        # fio JSON, read without a json module: the first "iops" of the read section and its clat p99.
        i = stdout.find('"read"')
        if i < 0:
            return None, {}
        sect = stdout[i:]
        iops = _json_number(sect, '"iops"')
        p99 = _json_number(sect, '"99.000000"')
        extra = {}
        if p99 != None:
            extra["clat_p99_us"] = p99 / 1000.0
        return iops, extra
    # sched_latency: cyclictest histogram — lines "<us> <count cpu0> <count cpu1> ...", plus
    # "# Histogram Overflows: ..." and "# Max Latencies: ...".
    hist = {}
    total = 0
    overflow = 0
    max_us = None
    for line in stdout.splitlines():
        s = line.strip()
        if s.startswith("# Histogram Overflows:"):
            for x in s[len("# Histogram Overflows:"):].split():
                if x.isdigit():
                    overflow = overflow + int(x)
        elif s.startswith("# Max Latencies:"):
            vals = [int(x) for x in s[len("# Max Latencies:"):].split() if x.isdigit()]
            if vals:
                max_us = max(vals)
        elif s and s[0].isdigit():
            parts = s.split()
            if all([x.isdigit() for x in parts]) and len(parts) >= 2:
                n = 0
                for x in parts[1:]:
                    n = n + int(x)
                hist[int(parts[0])] = hist.get(int(parts[0]), 0) + n
                total = total + n
    total = total + overflow
    if total == 0:
        return None, {}
    extra = {"samples": total, "max_us": max_us, "overflow": overflow}
    if overflow * 100 > total:
        # More than 1% above the histogram's 10 ms: the p99 lies beyond what was counted. Say so.
        extra["p99_beyond_histogram"] = True
        return float(max_us) if max_us != None else None, extra
    need = (total * 99 + 99) // 100
    seen = 0
    for us in sorted(hist.keys()):
        seen = seen + hist[us]
        if seen >= need:
            return float(us), extra
    return float(max_us) if max_us != None else None, extra


def _json_number(text, key):
    i = text.find(key)
    if i < 0:
        return None
    rest = text[i + len(key):].lstrip()
    if not rest.startswith(":"):
        return None
    rest = rest[1:].lstrip()
    num = ""
    for ch in rest.elems():
        if ch in "0123456789.-eE+":
            num = num + ch
        else:
            break
    if not num:
        return None
    return float(num)
