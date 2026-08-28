# A deliberately SIMPLE check, hand-written to exercise the whole path: author → assign in the UI → execute on
# the host → the service state that comes back. Everything else in checks.d is machine-translated from Checkmk;
# this one exists so the authoring path has a worked example a person can read in one sitting.
#
# WHAT IT MEASURES: how fast the host's own agent port accepts a TCP connection, from the host itself. That is
# the floor under every other check — every check's latency includes this one's — and it is measured LOCALLY,
# so it says something about the agent rather than about the network between the host and Bossman (the host's
# reachability check already measures that, and one number mixing both would be unactionable).
#
# WRITTEN AGAINST THE REAL ctx API, which is the thing this example is really for: `ctx.probe(kind, params)`,
# `ctx.facts()`, `ctx.run(argv)`. The first draft used `ctx.now_ms()` — which does not exist — and the check
# failed on the host with "ctx struct has no .now_ms attribute", visible as an UNKNOWN service state carrying
# that exact sentence. That is the system working: a check that cannot run says why, in the place a person
# looks.

def main(ctx, params):
    port = params.get("port", 8051)
    warn_ms = params.get("warn_ms", 50)
    crit_ms = params.get("crit_ms", 500)

    # 127.0.0.1 ON PURPOSE. Probing the host's own name would resolve through DNS and cross the network stack,
    # which is a different measurement with different failure modes — and one that fails when DNS does, which
    # would blame the agent for a name server.
    probe = ctx.probe("tcp", {"host": "127.0.0.1", "port": port, "timeout": 5})

    if not probe.get("connected"):
        # THE AGENT IS ANSWERING THIS VERY CALL, so its port not accepting a connection means something
        # specific: it is bound to another address, or a local firewall rule blocks the loopback path. Said as
        # that rather than as "agent down", which would be self-contradictory.
        return {
            # THE RETURN CONTRACT, which the stub gate enforces and no prose would have taught me:
            # {changed, msg, data:{state, metrics, details}} — and `metrics` is a DICT of name→number, not a
            # list of objects. My first three attempts got this wrong in three different ways, and each time
            # `bin/starlark-check -strict` named the exact key that was missing.
            "changed": False,
            # EXPLICIT +, because Starlark has no implicit string concatenation across lines. Python does,
            # and the first version of this file relied on it: the agent REJECTED the module with
            # "33:95: got string literal, want '}'" — which nobody saw, because Bossman only checked the
            # HTTP status of the push and the host kept running the previous version. `bin/starlark-check`
            # says it in one second, and belongs in front of every check edit.
            # THE MESSAGE NAMES THE PARAMETER, because the first real run said exactly this on a host whose
            # agent listens on 18051: the check was right and its DEFAULT was wrong, and "connection refused"
            # alone would have sent the reader looking for a firewall. A check that cannot know a value should
            # say which knob sets it.
            "msg": ("nothing accepts a local connection on port %d (%s). The agent answered this check, so "
                    + "either it listens elsewhere — set this check's `port` parameter, e.g. 18051 or 8451 — "
                    + "or the loopback path is filtered.")
                   % (port, probe.get("error", "no reason given")),
            "data": {"state": "CRIT", "metrics": {}, "details": probe.get("error", "")},
        }

    connect_ms = probe.get("connect_ms", 0.0)
    # ONE DECIMAL, THE HARD WAY. Starlark's % takes only bare verbs — "%.1f" raises "unknown conversion %."
    # at RUNTIME, past the parse gate, which is how a check gets shipped and then fails on the host (it has
    # happened to eight checks in this repo already). So the rounding is arithmetic and the verb is %s.
    shown_ms = int(connect_ms * 10) / 10.0
    facts = ctx.facts()
    os_family = facts.get("os_family", "unknown")

    state = "OK"
    if connect_ms >= crit_ms:
        state = "CRIT"
    elif connect_ms >= warn_ms:
        state = "WARN"

    msg = ("the agent's port %d accepted a local connection in %s ms (warn %d, crit %d) on %s"
           % (port, shown_ms, warn_ms, crit_ms, os_family))
    return {
        "changed": False,
        "msg": msg,
        # The metric's NAME carries its unit, since the contract has nowhere else to put one and a series
        # called "agent_connect" is a number nobody can plot against a threshold.
        "data": {"state": state, "metrics": {"agent_connect_ms": connect_ms}, "details": msg},
    }
