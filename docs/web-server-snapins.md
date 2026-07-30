# Web-server config snapins — nginx, Apache, HAProxy

Cockpit/IIS-style config editors for the three common web servers, in the
per-host **Management** console (Miller/MMC tree → *Package configuration*).
Each is a bespoke package snapin that appears only when its package is installed
(gate in `host-management.component.ts` `snapinPkgs`). The goal: break down the
block-syntax complexity so an operator configures a site/vhost/proxy — including
**SSL/TLS termination** — by values, "as clicky as IIS", never by hand-editing
config text.

## The model: values → template → whole file (no block parser)

nginx/Apache use nested block syntax (`server{}` / `<VirtualHost>`) and HAProxy
is sectioned; none of the agent's round-trip codecs (keyvalue/ini/json/yaml/xml/
…) can parse them. So these snapins do **not** round-trip-edit the file. Instead
(the established Class-B template model, see [config-kv-concept.md](config-kv-concept.md)):

1. A **schema-driven form** (`ParamForm`, from each template's `schema.json`)
   collects the values — enums as dropdowns, bools as toggles, lists as tables,
   cert/key paths via a **file-picker** (`widget:"file"`).
2. The **whole config file is rendered** from those values via the template's
   `template.j2` (agent `template_render` module).
3. **Apply** writes the rendered file (`type:"template_render"`) **and** a values
   **sidecar** (`type:"config"`, json) atomically through `state/apply` — so it
   is dry-run-previewable, versioned as a **generation**, and roll-backable.
4. Re-opening a site loads its **sidecar values** (no block parsing). A foreign,
   hand-written config (no sidecar) is shown **read-only** (raw), never silently
   reformatted.
5. Save then runs the server's **config test** and a graceful **reload**.

## The three snapins

| Snapin | Component | Object model | Template | Validate |
|---|---|---|---|---|
| **nginx sites** | `packages/nginx-sites.component.ts` | one file per site in `sites-available` (Debian) / `conf.d` (RedHat) | `nginx-vhost` | `nginx -t` → `nginx -s reload` |
| **Apache vhosts** | `packages/apache-vhosts.component.ts` | one file per vhost; enable via `a2ensite` (Debian) / present in `conf.d` (RedHat) | `apache-vhost` | `apache2ctl`/`apachectl configtest` → graceful |
| **HAProxy** | `packages/haproxy-config.component.ts` | single file `/etc/haproxy/haproxy.cfg` (one-object editor) | `haproxy` | `haproxy -c -f` → `systemctl reload` |

**Distro-awareness** (auto-detected at load via the `find` module, no OS label
trusted): nginx uses `sites-available`/`sites-enabled` symlinks on Debian, plain
`conf.d/*.conf` on RedHat. Apache is `apache2` (`/etc/apache2`, `a2ensite`) on
Debian vs `httpd` (`/etc/httpd/conf.d`) on RedHat; the binary/service names come
from `configs/package_catalog.json` `families.{debian,redhat}`. When a vhost
terminates TLS on Debian, the snapin runs `a2enmod ssl headers`.

**Site values sidecars** live outside any include glob so they never affect the
server: `/etc/agentic-mcp/websites/{nginx,apache,haproxy}/<name>.json`.

## SSL/TLS termination fields

All three expose the same secure-by-default TLS surface (Mozilla *Intermediate*
as the shipped default; *Modern* = TLS 1.3-only is one dropdown change):

- **nginx** (`nginx-vhost`): `listen 443 ssl` + `http2 on`, `ssl_certificate`/
  `_key` (file-picker), `ssl_protocols` (enum TLSv1.2+1.3 / 1.3 / 1.2),
  `ssl_ciphers`, HSTS, and a separate `:80` → HTTPS redirect server block.
- **Apache** (`apache-vhost`): `<VirtualHost *:443>` `SSLEngine on`,
  `SSLCertificateFile`/`KeyFile` (file-picker), `SSLProtocol` (enum),
  `SSLCipherSuite` + `SSLHonorCipherOrder off`, HSTS via `mod_headers`, a `:80`
  redirect vhost, and reverse-proxy (`ProxyPass`).
- **HAProxy** (`haproxy`): `bind :443 ssl crt <combined PEM>` (file-picker,
  `*.pem`), global `ssl-min-ver` (enum) + `ssl-default-bind-ciphers`,
  `http-request redirect scheme https unless ssl_fc`, HSTS response header, and
  the backend server pool as a typed table.

## Template inventory (two tiers)

- **Per-site / per-vhost** (used by the snapins): `nginx-vhost`, `apache-vhost`.
- **Main daemon config** (used by the installable role in `package_catalog.json`):
  `nginx`, `apache2`, `haproxy`. For HAProxy the single file is both — the
  `haproxy` template is what the snapin renders *and* the role's config.
  (`apache` and `apache_httpd` are older redundant main-config templates, not
  referenced by the catalog.)

## Dev deploy (the running UI is a built bundle, not `ng serve`)

`http://localhost:4201` is served by the `agentic-mcp-bossman-ui-1` container
(nginx, web root `/usr/share/nginx/html`). To see UI changes:

```bash
docker compose up -d --build bossman-ui
```

That is the whole deploy — never `docker cp` into the container. `bossman-ui/Dockerfile`
already does every step correctly inside the build: `npx ng build --configuration
production` (a *development* build hardcodes an absolute apiUrl → CORS) and
`chmod -R a+rX` on the web root (the image assets are 0600 on the host, and nginx's
unprivileged worker would 403 them). Two properties a `docker cp` does not have:

- **A failing build cannot deploy.** `ng build` runs in the builder stage, so a broken
  build fails the image and the old container keeps serving. With a copy, a stale
  `dist/` gets shipped whenever the build error goes unnoticed.
- **The image is what runs.** A copy is discarded on the next recreate, so the
  container silently diverges from the repo until something restarts it — and then a
  fix that "worked" is gone with no trace of why.

## Verification (all Playwright-verified against docker-test)

For each snapin: it appears under *Package configuration* only when installed;
the object list enumerates with enabled state; *New …* opens the schema form
with SSL fields (protocol dropdown, cert/key file-picker, HSTS/redirect toggles);
*Preview (render)* shows the generated config; the rendered TLS + plain configs
pass the server's own config test (`nginx -t` / `apache2ctl configtest` /
`haproxy -c`, all rc 0).
