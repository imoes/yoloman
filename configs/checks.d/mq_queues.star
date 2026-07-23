def main(ctx, params):
    # Extract item (empty string for single-service, but this check is per-queue)
    item = params.get("item", "")

    # Gather data: run the agent's raw command (same data the Checkmk plugin parses)
    # The Checkmk agent plugin for mq_queues reads the IBM MQ queue data via the 'mq_queues' section.
    # Since we don't have Checkmk installed, we must replicate the *same underlying source*:
    # The Checkmk agent typically uses `cmk --execute-mq-plugin` or similar, but for portability
    # and since no concrete CLI is specified, we fall back to reading the agent's raw output format.
    #
    # However: the checkmk.mq_queues plugin is part of the Checkmk agent's *native* plugin system.
    # The actual source is the Checkmk agent's built-in mq_queues section, which executes IBM MQ
    # commands like `dspmq`, `runmqsc`, etc., depending on the agent's mq_* configuration.
    #
    # Because there is NO portable CLI that matches the Checkmk agent's internal behavior (and
    # the source doesn't specify an explicit CLI), and because a *read-only* check must not rely
    # on Checkmk being present, we fall back to the *only safe source*: the agent's JSON output
    # via `cmk --dry-run` is NOT available, and we cannot call the Checkmk agent.
    #
    # But: the problem statement says "Checkmk check → read-only Starlark check module"
    # and "JSON IS AVAILABLE HERE". The agent's *standard output* (what a standalone agent
    # would send) is not available via ctx.*. The *only viable interpretation* is that
    # the agent's JSON section is exposed as a special input. Since no such ctx.* is defined,
    # and because this is a *check* (not a facts module), we must assume the input data is
    # provided by the agent runtime in a way that matches Checkmk's agent section parsing.
    #
    # In practice, for Starlark agents, the agent section is often available via a file or
    # ctx.*. Since none is specified, and because the problem explicitly says "JSON IS AVAILABLE"
    # and this is an mq_queues check (which in Checkmk comes from the agent's mq_queues section),
    # we assume the agent provides the queue data via a CLI command that mimics the Checkmk agent.
    #
    # The Checkmk agent's mq_queues section typically runs:
    #   runmqsc <queue_manager> | grep -A4 "QUEUE(...)" | grep -E "(CURDEPTH|AGE|ENQ|DEQ|CONSUMER)"
    # but this is environment-specific.
    #
    # However, the example shows tab-separated numeric lines after `[[queue_name]]` headers.
    # This is the Checkmk agent's *text* format (not JSON). The problem statement says "JSON IS
    # AVAILABLE", but the check plugin source parses `StringTable` — a list of string lines.
    #
    # Because the agent's raw section is *text*, and because the Starlark runtime lacks direct
    # access to the Checkmk agent's internal data, we must assume the agent runtime *already
    # parsed the mq_queues section* and provided it via a ctx.* call. Since no such call is
    # documented in the base contract, and because the problem says "JSON IS AVAILABLE", we
    # assume the agent runtime exposes the section as a JSON string.
    #
    # We use a best-effort approach: try to read a JSON file or env var that might contain
    # the mq_queues data. But no standard path is defined.
    #
    # Given the constraints and the explicit requirement to translate the check *exactly*, we
    # must rely on the agent runtime exposing the data. Since no ctx.* is defined for this,
    # and because this is a *translated* check from Checkmk, we assume the agent provides
    # the section via `ctx.run()` with a specific command.
    #
    # The safest, most portable way is to assume the agent runtime provides the section in
    # JSON format via a known path or via an environment variable. But this is not reliable.
    #
    # Alternative: the agent's text section for mq_queues is standard and simple. We can
    # assume the agent runtime already has a `ctx.mq_queues_section()` or similar, but it's
    # not in the spec.
    #
    # Since this is a *translation* and the check *must* work, and because the problem says
    # "JSON IS AVAILABLE", we assume the agent runtime provides the section as a JSON string
    # in a file like `/var/lib/mk-queues/queues.json` or via an environment variable. But
    # this is not portable.
    #
    # Given the ambiguity, we follow the *spirit of the problem*: the check is read-only and
    # the agent runtime *must* provide the data. Since no standard ctx.* is available for the
    # agent section, and because the example shows text lines, we assume the agent provides
    # the raw text section via a CLI command: `mq_queues`.
    #
    # We use `ctx.run(["mq_queues"], mutates=False)` as a fallback. This command should
    # output the same format as the Checkmk agent's mq_queues section: lines like
    #   [[queue_name]]
    #   size consumer_count enqueue_count dequeue_count
    #
    # If this command fails, we return UNKNOWN with a helpful message.

    # Try to get the section data via a command that outputs the same format as Checkmk agent
    res = ctx.run(["mq_queues"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Failed to retrieve mq_queues data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "No mq_queues data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # discovery mode: enumerate all queues
    if params.get("_discover"):
        queues = []
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("[[") and line.endswith("]]"):
                queue_name = line[2:-2]
                # Suggested default params: none (check uses defaults from source)
                params_default = {"size": None, "consumer_count_levels_upper": None, "consumer_count_levels_lower": None}
                metrics_list = ["consumer_count", "size", "enque", "deque"]
                queues.append({"item": queue_name, "params": params_default, "metrics": metrics_list})
            i += 1
        return {"changed": False, "msg": "discovered %d queues" % len(queues),
                "data": {"discovery": queues}}

    # check mode: find the requested item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = False
    size = -1
    consumer_count = -1
    enqueue_count = -1
    dequeue_count = -1

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if found:
            # next non-header line contains the numbers
            parts = line.split()
            if len(parts) >= 4:
                size = int(parts[0])
                consumer_count = int(parts[1])
                enqueue_count = int(parts[2])
                dequeue_count = int(parts[3])
            break
        if line.startswith("[[") and line.endswith("]]"):
            queue_name = line[2:-2]
            if queue_name == item:
                found = True
        i += 1

    if not found:
        return {"changed": False, "msg": "queue '%s' not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract thresholds from params (checkmk defaults from source)
    size_levels = params.get("size", None)
    consumer_count_levels_upper = params.get("consumer_count_levels_upper", None)
    consumer_count_levels_lower = params.get("consumer_count_levels_lower", None)

    # Helper: compute Checkmk state based on levels (upper and lower)
    # Checkmk's check_levels_legacy_compatible returns a Result with State.OK/WARN/CRIT
    # We simulate: for upper levels (None, None) means no check. For lower levels similarly.
    def check_levels(value, name, upper_levels, lower_levels, human_readable=None):
        # upper_levels is (warn, crit) or (None, None)
        # lower_levels is (warn, crit) or (None, None)
        # Returns a tuple (state, details)
        # Checkmk logic:
        #   - if value >= crit (upper) or value <= crit (lower) -> CRIT
        #   - if value >= warn (upper) or value <= warn (lower) -> WARN
        #   - else OK
        # If both upper and lower levels are None, no check -> OK
        state = "OK"
        details = ""
        if value != None:
            # Check upper levels first
            if upper_levels:
                warn_u, crit_u = upper_levels
                if crit_u != None and value >= crit_u:
                    state = "CRIT"
                elif warn_u != None and value >= warn_u:
                    if state == "OK":
                        state = "WARN"
            # Check lower levels
            if lower_levels and state == "OK":
                warn_l, crit_l = lower_levels
                if crit_l != None and value <= crit_l:
                    state = "CRIT"
                elif warn_l != None and value <= warn_l:
                    state = "WARN"
            # Format human readable
            hr = str(value) if human_readable == None else human_readable(value)
            if state != "OK":
                details = "%s: %s" % (name, hr)
        return state, details

    # Check consumer_count
    state_con = "OK"
    details_con = ""
    upper = consumer_count_levels_upper or (None, None)
    lower = consumer_count_levels_lower or (None, None)
    if consumer_count != -1:
        state_con, details_con = check_levels(consumer_count, "Consuming connections",
                                              upper, lower, str)
    # Check size
    state_size = "OK"
    details_size = ""
    if size != -1:
        state_size, details_size = check_levels(size, "Queue size",
                                                size_levels or (None, None), (None, None), str)
    # Enqueue and dequeue have no levels by default
    state_enq = "OK"
    details_enq = ""
    if enqueue_count != -1:
        state_enq, details_enq = check_levels(enqueue_count, "Enqueue count", (None, None), (None, None), str)
    state_deq = "OK"
    details_deq = ""
    if dequeue_count != -1:
        state_deq, details_deq = check_levels(dequeue_count, "Dequeue count", (None, None), (None, None), str)

    # Final state: CRIT if any is CRIT, else WARN if any is WARN, else OK
    final_state = "OK"
    details_parts = []
    for s, d in [(state_con, details_con), (state_size, details_size),
                 (state_enq, details_enq), (state_deq, details_deq)]:
        if s == "CRIT":
            final_state = "CRIT"
        elif s == "WARN" and final_state == "OK":
            final_state = "WARN"
        if d:
            details_parts.append(d)

    # Build msg: Checkmk-style summary
    msg_parts = []
    if size != -1:
        msg_parts.append("Size: %s" % str(size))
    if consumer_count != -1:
        msg_parts.append("Consumers: %s" % str(consumer_count))
    if enqueue_count != -1:
        msg_parts.append("Enqueued: %s" % str(enqueue_count))
    if dequeue_count != -1:
        msg_parts.append("Dequeued: %s" % str(dequeue_count))
    msg = ", ".join(msg_parts) if msg_parts else "Queue '%s'" % item
    if final_state != "OK":
        msg += " (" + final_state + ")"
    # Add details if any
    if details_parts:
        msg += " - " + "; ".join(details_parts)

    # Build metrics dict (perfdata)
    metrics = {}
    if size != -1:
        metrics["size"] = size
    if consumer_count != -1:
        metrics["consumer_count"] = consumer_count
    if enqueue_count != -1:
        metrics["enque"] = enqueue_count
    if dequeue_count != -1:
        metrics["deque"] = dequeue_count

    return {"changed": False, "msg": msg, "data": {"state": final_state, "metrics": metrics, "details": ""}}