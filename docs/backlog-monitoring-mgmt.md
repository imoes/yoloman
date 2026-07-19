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
- [x] **#8 Patch/reboot orchestration** — canary→ring waves (`plan_waves`), health-gate
      between waves (only NEW hard-CRIT counts vs a pre-wave baseline), fire-and-forget
      `execute_rollout` driver, `/api/v1/rollouts` CRUD+start/abort, Rollouts UI with live
      per-wave progress.
- [x] **#9 Software compliance** — required/forbidden package specs (with version
      constraints `openssl>=3.0`, `log4j<2.17`) per host/group/OU/fleet, evaluated
      against `Agent.facts["installed_packages"]` by a `compliance_loop`; per-host
      ComplianceResult + a NotifyEvent on drift; `/api/v1/compliance-rules` CRUD +
      evaluate/results; Compliance UI (rules + per-host drift, evaluate-now).
- [x] **#10 Certificate/expiry inventory** — fleet-wide board of TLS certs (probed
      from Bossman via unverified handshake → leaf notAfter/subject/issuer/SANs) plus
      manual licence/domain expiries, sorted by soonest expiry, warn/crit-day thresholds
      with drift alerting (`cert_inventory_loop`); `/api/v1/cert-targets` CRUD +
      check-now + summary; Certificates UI board. (Complements the per-endpoint `cert`
      active check, which monitors one cert as a service.)
- [x] **#13 Audit-log UI** — unified `audit_log` table + `record_audit` helper;
      an HTTP middleware records every authenticated mutating call (actor from the
      bearer, target from the path, outcome from the status) and login success/
      failure is logged explicitly; admin-gated `/api/v1/audit` (filters
      actor/category/status/q/since) + `/stats`; searchable Audit UI. (The prior
      "audit in DB" was only fragmented run tables — this adds the real unified trail.)
- [x] **#14 Custom dashboards** — core already existed (GridStack drag-drop, multi-
      dashboard CRUD, per-user persistence, AI generation, ECharts, 14 widget types).
      Added the missing **NOC view**: a chrome-less full-screen kiosk (`/noc`) that
      renders any saved dashboard read-only with auto-refresh, rotation through all
      dashboards, native fullscreen, and idle-hiding chrome; + a top-level nav entry.
- [ ] **#4 BI / service aggregation** — logical service = A AND B AND C across hosts.
- [ ] **#3 Trending/forecasting/capacity** — adaptive thresholds, "disk full in N days".
- [ ] **#15 Agent config distribution** — provide an automation (mostly policy-solved).

## Deferred (remembered)
- #5 Scheduled/exportable fleet reports (PDF/CSV, emailed SLA/inventory).
- #6 Full log analytics (Graylog/Loki index + pattern alerting) — likely its own
  product; today AI reads logs + grep covers the basics.
- #11 Backup orchestration (fs/DB dump jobs + verify).
- #12 Auth hardening: 2FA/TOTP + SSO (SAML/OIDC) + LDAP/AD login.
