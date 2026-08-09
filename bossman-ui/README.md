# Bossman UI

The Angular frontend for Bossman (Fleet Commander) — see
[`../docs/plan.md`](../docs/plan.md) in the repo root for the full design
(Bossman plan, section C).

Angular 20, standalone components, Material 3 theming with Rasta accent
colours (`--bm-green`/`--bm-gold`/`--bm-red`/`--bm-black`), no NgRx (state
lives in `providedIn: 'root'` services using `signal()`), Cytoscape+dagre
for the topology graph, ngx-echarts for metric charts.

## Develop

```bash
npm install
npm start           # ng serve, defaults to http://localhost:4300 — see angular.json
```

`src/environments/environment.ts` points the dev build at Bossman's API —
default `http://localhost:8123/api/v1`. Point it at wherever your own
Bossman dev instance is actually listening.

**Bossman itself must have `BOSSMAN_CORS_ALLOWED_ORIGINS` covering this
dev server's origin** (defaults already include
`http://localhost:4200`/`http://localhost:4300`) — without it, the browser
silently blocks every request carrying an `Authorization` header or JSON
body before it reaches a route. This was a real bug found the first time
this app was pointed at a real running Bossman; see `docs/plan.md`'s
Bossman Block C notes and `bossman/tests/test_cors.py`.

## Build

```bash
npm run build        # production build, output in dist/bossman-ui
```

## Test

```bash
npm test             # Karma/Jasmine unit tests
npm run e2e          # Playwright — needs a real running Bossman + agentic-mcpd,
                      # see docs/plan.md's Block C verification notes
```

`playwright.config.ts` defaults to `http://localhost:4200`; override with
`BOSSMAN_UI_URL` if `ng serve` is running on a different port.
