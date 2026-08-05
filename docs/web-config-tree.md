# IIS-Manager-style web-server config tree (nginx, Apache, HAProxy, Caddy)

Per-endpoint web-server configuration presented like **Microsoft IIS Manager**: a tree with
directories/nodes and a right-click context menu (Add Website, add www root, Edit Bindings + attach a
certificate, Add Certificate), and per-node **Features** panes exposing the config settings — reusing the
OU/policy tree look. One tree per web-server snap-in, gated per installed package on the host's
**Management** tab.

Status: **done** — nginx (M1), Apache (M2), HAProxy (M3), Caddy (M4) live on the tree; schemas extended
toward the IIS feature set (M5). All milestones verified end-to-end on `docker-test`.

## The IIS model we mirror

`Server → Sites → Site → (Bindings / www root / Locations)` in the Connections tree; each node has a
**Features** list and an **Actions / right-click** menu; **Add Website** asks for site name, physical path
(www root) and a binding (http/https, port, SSL certificate); server scope also has **Certificates**.

## Two config models, two components

The four servers split by how their config is laid out on disk, so there are two components — both render the
same IIS-style tree, driven by a profile in
[web-server-profiles.ts](../bossman-ui/src/app/features/hosts/management/packages/web-server-profiles.ts).

| Model | Servers | Component | On disk |
|---|---|---|---|
| **one file per site** | nginx, Apache | [web-config-tree.component.ts](../bossman-ui/src/app/features/hosts/management/packages/web-config-tree.component.ts) | a file per site in `sites-available` (+ `sites-enabled` symlink), one `*-vhost` template rendered per site |
| **single config** | HAProxy, Caddy | [web-single-config-tree.component.ts](../bossman-ui/src/app/features/hosts/management/packages/web-single-config-tree.component.ts) | one config file rendered whole from one values doc; the tree's nodes are declared feature **sections** |

Both reuse the shared apply idiom: a node's values → `template_render` (the server's j2) into its config file
**+** a JSON sidecar, applied via `agentService.stateApply`, then **validate** via `callTool(id,'command',…)`
→ **reload**. Read-back is from the sidecar. No backend change — everything goes through existing
`stateApply` / `callTool` / `configTemplates` / `template_render`.

### Per-file profile (`WebServerProfile`)

Describes: `vhostTemplate`, `service`, `sitesDir` / `sitesEnabledDir` / `confdDir`, `sidecarDir`,
`fileSuffix` (`''` nginx, `'.conf'` apache — site file naming + display-name stripping), `sitesPattern`
(apache `*.conf`), `validateArgv` / `reloadArgv`, `fields` (schema fields mapped onto serverName / root /
port / TLS / cert / locations), `locationsList` (nginx true, apache false — gates the Add-Location action),
`featureGroups` (which schema fields show on the Bindings / www root / Locations panes) and `certSearchDirs`.

Tree: `Server → Sites → Site → (Bindings / www root / Locations)` + `Certificates`. Add Website writes a new
site file + sidecar; Edit Bindings attaches a cert; Save renders + validates (`nginx -t` /
`apache2ctl -t`) + enables the symlink (`a2ensite`-equivalent, keeps apache's `.conf`) + reloads; Remove
deletes file + symlink + sidecar.

### Single-config profile (`SingleConfigProfile`)

Describes: `template`, `service`, `configPath`, `sidecarPath`, `validateArgv` / `reloadArgv`, `sections`
and `certSearchDirs`. A **section** (`WebSectionSpec`) is either a fixed **group** of schema fields or a
**list** whose entries become child leaf nodes (add/remove via the right-click menu).

- **HAProxy**: Global / Frontend / Backend groups + a `backend_servers` list (Add Server) — validate
  `haproxy -c`.
- **Caddy**: Global options group + a `sites` list (Add Website) — validate `caddy validate`.

The whole config is one values doc, seeded from schema defaults then overlaid with the sidecar; every pane
edits into it (group panes merge their own fields, list-item panes write back to `values[listField][idx]`);
Save renders the whole template + sidecar, validates and reloads.

## Certificates (file-based, all servers)

Certificate files are discovered on the host (`find` over `certSearchDirs` for `*.pem` / `*.crt`, tolerant of
missing dirs) and listed under the **Certificates** node. *Add Certificate* registers a path a TLS
binding/setting can reference. No certificate content is stored in the DB.

## Features / settings coverage (M5)

Panes are schema-driven from each template's `schema.json` via the shared param-form, so "all settings" grows
as data, not code. M5 extended `nginx-vhost` and `apache-vhost` toward the IIS feature set — each new setting
is both a schema field and rendered by the template (so it reaches the config file, not just the sidecar):

Default Document, Directory Browsing, Request Filtering (max body size), Compression (apache wrapped in
`<IfModule mod_deflate.c>`), Logging paths, Error Pages (list), HTTP Response Headers (list; apache wrapped in
`<IfModule mod_headers.c>` so `apache2ctl -t` passes even without mod_headers loaded).

HAProxy and Caddy schemas already cover their models (global/frontend/backend + backend-server list; global
options + per-site domain/upstream/root/tls/extra).

## Wiring

[host-management.component.ts](../bossman-ui/src/app/features/hosts/management/host-management.component.ts):
the nginx / Apache snap-ins render `<app-web-config-tree>` and the HAProxy / Caddy snap-ins render
`<app-web-single-config-tree>` with their profiles. Because each pair shares one component type, the two
instances are targeted by template ref (`#nginxTree` / `#apacheTree`, `#haproxyTree` / `#caddyTree`).
`snapinPkgs` gating unchanged. The old flat panels (`apache-vhosts`, `haproxy-config`, `caddy-config`) are
superseded in this view.

## Verification (all on `docker-test`, id `6a0db3e4-0ce6-40cf-adf9-ff007254e9c7`)

- **nginx**: Add Website → Save writes `sites-available/<name>` + sidecar, `nginx -t` passes, symlink +
  reload; M5 fields (autoindex / client_max_body_size / gzip / add_header) render and pass `nginx -t`.
- **Apache**: Add Website writes `sites-available/<name>.conf` + sidecar, `apache2ctl -t` passes, `a2ensite`
  + graceful reload; context menu omits Add-Location; Remove cleans file + symlink + sidecar; M5 fields
  (+Indexes / LimitRequestBody / mod_deflate / ErrorDocument / IfModule-guarded Header) pass `apache2ctl -t`.
- **HAProxy**: Backend servers list — Add Server → Save renders `haproxy.cfg`, `haproxy -c` passes, reload.
- **Caddy**: right-click Sites → Add Website → Save renders the `Caddyfile`, `caddy validate` passes, reload.

## Possible follow-ups

- Dedicated feature-node children for the per-file tree (Error Pages / Response Headers / Logging as their own
  IIS-style nodes) instead of only appearing on the www-root / all-settings pane.
- `a2enmod headers/deflate` on Apache save when those features are enabled (today the template is
  IfModule-guarded so validation always passes, but the directive is a no-op if the module is absent).
- HAProxy stats page / `forwardfor`; Caddy `encode gzip` as first-class fields.
