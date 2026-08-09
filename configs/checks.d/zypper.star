# Copyright (C) 2024 Checkmk GmbH - License: GNU General Public License v2 (GPLv2)
# Translated to a read-only Starlark check module for the yolo-man agent.

# Default thresholds mirroring the Checkmk plugin's DEFAULT_PARAMS.
# locks: WARN, security: CRIT, recommended: WARN, other: OK
DEFAULT_LOCKS = 1
DEFAULT_SECURITY = 2
DEFAULT_RECOMMENDED = 1
DEFAULT_OTHER = 0

# Map Checkmk State ordinals to label strings (0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN).
def _state_label(n):
    labels = ["OK", "WARN", "CRIT", "UNKNOWN"]
    if n < 0 or n >= len(labels):
        return "UNKNOWN"
    return labels[n]


def _grade(count, threshold):
    # count: int value; threshold: int (0=OK,1=WARN,2=CRIT)
    # Returns state label: warn at >=threshold if threshold is WARN(1)?
    # The original maps each patch-type count to a fixed state via params;
    # there is no "count >= threshold" comparison — the state is determined
    # purely by the configured level for that patch type.
    return _state_label(threshold)


def _parse_patch_types_and_locks(raw):
    """Parse the zypper list output into (patch_types, locks).

    Each input line is expected to look like one of:
      <name> <version> <repo> <type> needed
      <name> <version> <repo> <type> needed <date>
      <name> <lock> <repo> <reason>
    Returns ([type,...], [lock,...]). A leading 'ERROR:' line means error.
    """
    patch_types = []
    locks = []
    has_error = False
    for line in raw:
        f = line.split()
        if not f:
            continue
        if len(f) >= 1 and f[0] == "ERROR:" or line.startswith("ERROR:"):
            has_error = True
            break
        # Match patterns by field count & content.
        if len(f) == 5 and f[4].lower() == "needed":
            patch_types.append(f[3].strip())
        elif len(f) == 6 and f[4].lower() == "needed":
            patch_types.append(f[3].strip())
        elif len(f) >= 7 and f[5].lower() == "needed":
            patch_types.append(f[3].strip())
        elif len(f) == 4:
            # lock line: [name, lock, repo, reason]
            locks.append(f[1])
    return patch_types, locks, has_error


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: probe for the real thing — zypper binary.
        prob = ctx.run(["zypper", "--version"], mutates=False)
        if prob.rc != 0:
            # Not installed (rc 127 or other failure): empty discovery.
            return {
                "changed": False,
                "msg": "zypper not available on this host",
                "data": {"discovery": []},
            }
        # Single-service check: one entry with item "".
        metrics = ["patches", "locks"]
        entry = {
            "item": "",
            "params": {
                "locks": DEFAULT_LOCKS,
                "security": DEFAULT_SECURITY,
                "recommended": DEFAULT_RECOMMENDED,
                "other": DEFAULT_OTHER,
            },
            "metrics": metrics,
        }
        host_labels = {}
        if ctx.facts().get("os_family") != None:
            host_labels["cmk/os_family"] = ctx.facts().get("os_family")
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [entry],
                "host_labels": host_labels,
            },
        }

    # Check mode: gather the zypper updates list (read-only).
    res = ctx.run(["zypper", "list-updates", "--type", "patch"], mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return {
                "changed": False,
                "msg": "zypper not installed",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "zypper binary not found",
                },
            }
        # If there's stderr, surface it as UNKNOWN (no fabricated OK).
        detail = res.stderr if res.stderr else "zypper returned rc=%d" % res.rc
        return {
            "changed": False,
            "msg": detail,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": detail,
            },
        }

    raw = res.stdout.splitlines()
    patch_types, locks, has_error = _parse_patch_types_and_locks(raw)

    if has_error:
        return {
            "changed": False,
            "msg": "zypper reported an error",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "ERROR",
            },
        }

    # Count patch types by category using a manual Counter (no imports).
    counts = {}
    for pt in patch_types:
        if pt in counts:
            counts[pt] = counts[pt] + 1
        else:
            counts[pt] = 1

    # Build metric set & overall summary.
    metrics = {}
    num_patches = len(patch_types)
    num_locks = len(locks)
    metrics["patches"] = num_patches
    metrics["locks"] = num_locks

    # Determine worst state across patch-type results.
    state_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = 0  # start OK
    details_lines = []
    details_lines.append("%d patches" % num_patches)
    if num_locks > 0:
        details_lines.append("%d locks" % num_locks)

    # Per-type breakdown using configured thresholds.
    type_thresholds = {
        "security": params.get("security", DEFAULT_SECURITY),
        "recommended": params.get("recommended", DEFAULT_RECOMMENDED),
    }
    other_threshold = params.get("other", DEFAULT_OTHER)

    # Sort types for stable output.
    sorted_types = sorted(counts.keys())
    for t in sorted_types:
        if t in type_thresholds:
            lvl = type_thresholds[t]
        else:
            lvl = other_threshold
        label = _state_label(lvl)
        lv = state_order.get(label, 0)
        if lv > worst:
            worst = lv
        c = counts[t]
        # Expose per-type count as a metric name derived from the type.
        metrics[t] = c
        details_lines.append("%s: %d" % (t, c))

    # Locks threshold (default WARN=1).
    locks_threshold = params.get("locks", DEFAULT_LOCKS)
    locks_label = _state_label(locks_threshold)
    lv_locks = state_order.get(locks_label, 0)
    if lv_locks > worst:
        worst = lv_locks

    final_state = "OK"
    if worst == 1:
        final_state = "WARN"
    elif worst == 2:
        final_state = "CRIT"
    elif worst == 3:
        final_state = "UNKNOWN"

    summary = "%d updates" % num_patches
    if num_locks > 0:
        summary = summary + ", %d locks" % num_locks

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": "\n".join(details_lines),
        },
    }