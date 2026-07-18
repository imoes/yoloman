# Server Monitoring & Management — gap backlog (2026-07-18)

Gaps vs Checkmk/Zabbix/Server-Manager the user greenlit, in a `/loop`. Base is
large already (1442 checks, discovery, roles wizard, gpedit, OU/policy, CVE
security, topology, MMC console, MCP lifecycle) — build only what's missing.

## Active (in priority order)
- [x] **#1 Notification channels + escalation** — Slack/Teams/Telegram/PagerDuty/
      Discord senders + `escalate_after_minutes` on-call chains (dispatch_escalations
      runs each poll cycle).
- [x] **#7 Scheduler** — recurring runbooks/maintenance (RRULE/cron, fleet-wide).
- [x] **#2 Event Console** — passive SNMP-trap + syslog receipt.
- [ ] **#8 Patch/reboot orchestration** — canary→ring waves, health-gate between.
- [ ] **#9 Software compliance** — required/forbidden packages per OU + drift alarm.
- [ ] **#10 Certificate/expiry inventory** — fleet-wide TLS/cert/licence expiry board.
- [ ] **#13 Audit-log UI** — searchable change tracking (audit already in DB).
- [ ] **#14 Custom dashboards** — drag-drop dashlets, NOC view.
- [ ] **#4 BI / service aggregation** — logical service = A AND B AND C across hosts.
- [ ] **#3 Trending/forecasting/capacity** — adaptive thresholds, "disk full in N days".
- [ ] **#15 Agent config distribution** — provide an automation (mostly policy-solved).

## Deferred (remembered)
- #5 Scheduled/exportable fleet reports (PDF/CSV, emailed SLA/inventory).
- #6 Full log analytics (Graylog/Loki index + pattern alerting) — likely its own
  product; today AI reads logs + grep covers the basics.
- #11 Backup orchestration (fs/DB dump jobs + verify).
- #12 Auth hardening: 2FA/TOTP + SSO (SAML/OIDC) + LDAP/AD login.
