# The inbound firewall rule, on both platforms

An agent that installs, starts, and reports itself reachable at a port the host's firewall drops is a machine
that **looks managed and is not** — and the state is invisible from the host (the service is running, the log
says "listening") while showing up centrally as a poll error, which reads as a network fault. So the rule is
created where the port is decided.

| | where | what |
|---|---|---|
| **Linux** | `packaging/postinst` | reads `listen:` from the installed config, then ufw → firewalld → iptables, in that order |
| **Windows** | the agent itself, at startup (`WindowsFirewall.EnsurePortOpen`) | `netsh advfirewall`, idempotent by rule name |

Windows creates it in the agent rather than in an installer because there is no installer yet (the MSI is
milestone 6) — and because the port is a runtime setting there (`AGENT_LISTEN`), so the agent is the only
thing that knows it.

## The five cases the Linux path distinguishes

Run them without touching this host — the firewall tools are stubbed:

```
POSTINST=packaging/postinst STUBS=packaging/test-firewall-stubs \
  LISTEN_UNDER_TEST=0.0.0.0:8051 UFW_STATE=active ./packaging/test-postinst-firewall.sh
```

    listen=127.0.0.1:8010          loopback-only — NO rule, and it says so
    ufw active                     ufw allow 8051/tcp
    firewalld running              --permanent --add-port + --reload (both, or it only works after a reload)
    iptables with a DROP policy    -I INPUT ... ACCEPT, and it says whether that survives a reboot
    nothing blocks                 no rule, named as its own outcome

**ufw is tried first** on purpose: on a host that runs it, an iptables rule inserted behind its chains is
invisible to `ufw status` and disappears on the next reload. **iptables is touched only if something actually
blocks** (a DROP/REJECT policy or a rejecting rule) — adding a rule to a permissive ruleset is noise in
somebody else's configuration. And persistence is never assumed: without `netfilter-persistent` or
`/etc/sysconfig`, the rule is live and temporary, and the install log says that rather than hoping.

The fourth and fifth lines exist because "nothing was opened" and "nothing needed opening" must not look the
same in an install log.
