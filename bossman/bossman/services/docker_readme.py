"""Extract a Docker image's configurable variables from its Docker Hub README.

For a given image this fetches the Hub overview (full_description) and asks the
configured OpenRouter model (settings.docker_extract_model, e.g. laguna-s2.1) to
pull out the env-var knobs (name/default/description), exposed ports and volumes
as templating-style parameters — the docker counterpart to the config-template
schemas. Results are stored in docker_app_templates for the app store/blueprint.
TOP_IMAGES is a curated set of the most-deployed containers to seed the catalog.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, DockerAppTemplate
from bossman.services.chat_backend import ChatBackendError, chat_backend_for

# Curated most-common containers (rank = popularity). Official images use the
# bare name; others carry their namespace.
TOP_IMAGES: list[str] = [
    "nginx", "postgres", "redis", "mysql", "mariadb", "mongo", "httpd", "node", "python", "traefik",
    "memcached", "rabbitmq", "influxdb", "elasticsearch", "wordpress", "grafana/grafana", "prom/prometheus",
    "portainer/portainer-ce", "jenkins/jenkins", "gitlab/gitlab-ce", "sonarqube", "nextcloud", "vaultwarden/server",
    "jellyfin/jellyfin", "linuxserver/plex", "homeassistant/home-assistant", "adguard/adguardhome", "pihole/pihole",
    "louislam/uptime-kuma", "photoprism/photoprism", "minio/minio", "haproxy", "caddy", "consul", "vault",
    "telegraf", "prom/node-exporter", "prom/alertmanager", "grafana/loki", "grafana/promtail", "jaegertracing/all-in-one",
    "eclipse-mosquitto", "nats", "keycloak/keycloak", "quay.io/keycloak/keycloak", "gitea/gitea", "drone/drone",
    "registry", "docker", "busybox", "alpine", "ubuntu", "debian", "hashicorp/vault", "hashicorp/consul",
    "bitnami/postgresql", "bitnami/redis", "bitnami/kafka", "confluentinc/cp-kafka", "zookeeper", "cassandra",
    "couchdb", "neo4j", "clickhouse/clickhouse-server", "timescale/timescaledb", "pgvector/pgvector",
    "ghost", "joomla", "drupal", "mediawiki", "matomo", "rocket.chat", "mattermost/mattermost-team-edition",
    "wekanteam/wekan", "focalboard", "vikunja/vikunja", "linuxserver/sonarr", "linuxserver/radarr",
    "linuxserver/qbittorrent", "linuxserver/nextcloud", "filebrowser/filebrowser", "syncthing/syncthing",
    "duplicati/duplicati", "restic/rest-server", "miniflux/miniflux", "freshrss/freshrss", "wallabag/wallabag",
    "code-server", "codercom/code-server", "gitpod/openvscode-server", "n8nio/n8n", "nodered/node-red",
    "apache/airflow", "metabase/metabase", "apache/superset", "redash/redash", "grafana/tempo", "vectordotdev/vector",
    "fluent/fluentd", "opensearchproject/opensearch", "kibana", "logstash", "sentry", "getsentry/sentry",
]


def _repo_path(image: str) -> str:
    """Docker Hub repo path: official images live under `library/`."""
    img = image.split(":", 1)[0]  # drop any tag
    if img.startswith("quay.io/") or "@" in img:
        return img  # non-Hub / digest — return as-is (README fetch will just fail)
    return img if "/" in img else f"library/{img}"


async def fetch_readme(image: str, timeout: float = 20.0) -> dict[str, str]:
    """{name, description, readme} from Docker Hub, or raises ValueError."""
    path = _repo_path(image)
    url = f"https://hub.docker.com/v2/repositories/{path}/"
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(url)
    except httpx.HTTPError as exc:
        raise ValueError(f"fetching Hub page for {image!r}: {exc}") from exc
    if resp.status_code != 200:
        raise ValueError(f"Docker Hub returned {resp.status_code} for {image!r}")
    data = resp.json()
    return {
        "name": data.get("name") or image,
        "description": data.get("description") or "",
        "readme": data.get("full_description") or "",
    }


_SYSTEM = """You extract the configurable knobs of a Docker image from its README. Reply with a
SINGLE JSON object and nothing else (no prose, no code fences):

{
  "description": "one line on what the image is",
  "variables": [{"name": "POSTGRES_PASSWORD", "default": "", "description": "…", "required": true}],
  "ports": ["5432"],
  "volumes": ["/var/lib/postgresql/data"]
}

`variables` are the environment variables the image documents (name exactly as the env var, a default if the
README gives one else "", a short description, required=true if it must be set). `ports` are the container
ports it EXPOSEs/documents; `volumes` the data paths worth persisting. Include only what the README actually
documents — do not invent. If none, use empty arrays."""


def _parse_json_object(text: str) -> dict[str, Any]:
    t = re.sub(r"^```(?:json)?|```$", "", (text or "").strip(), flags=re.MULTILINE).strip()
    start = t.find("{")
    if start < 0:
        raise ValueError("model returned no JSON object")
    depth = 0
    for i in range(start, len(t)):
        if t[i] == "{":
            depth += 1
        elif t[i] == "}":
            depth -= 1
            if depth == 0:
                return json.loads(t[start : i + 1])
    raise ValueError("unterminated JSON object")


async def extract_variables(readme: str, image: str, settings: Settings) -> dict[str, Any]:
    """LLM-extract {description, variables, ports, volumes} from a README."""
    backend = chat_backend_for(settings, "openrouter")
    # Keep the prompt bounded — READMEs can be huge; the knobs are near the top.
    body = readme[:12000]
    messages = [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": f"Image: {image}\n\nREADME:\n{body}"},
    ]
    try:
        res = await backend.complete_with_tools(messages, [], model=settings.docker_extract_model)
    except ChatBackendError as exc:
        raise ValueError(f"LLM backend error: {exc}") from exc
    return _parse_json_object(res.get("content", ""))


async def extract_and_store(
    session: AsyncSession, settings: Settings, image: str, popularity: int = 0
) -> DockerAppTemplate:
    """Fetch the README, extract the variables, and upsert a DockerAppTemplate.
    Skips the LLM call when the README is unchanged since the last extraction."""
    meta = await fetch_readme(image)
    readme_hash = hashlib.sha256(meta["readme"].encode("utf-8")).hexdigest()
    row = await session.scalar(select(DockerAppTemplate).where(DockerAppTemplate.image == image))
    if row is not None and row.readme_hash == readme_hash and row.variables:
        if popularity and not row.popularity:
            row.popularity = popularity
        return row

    extracted = await extract_variables(meta["readme"], image, settings)
    variables = extracted.get("variables") or []
    ports = [str(p) for p in (extracted.get("ports") or [])]
    volumes = [str(v) for v in (extracted.get("volumes") or [])]
    desc = extracted.get("description") or meta["description"]

    if row is None:
        row = DockerAppTemplate(tenant_id=DEFAULT_TENANT_ID, image=image)
        session.add(row)
    row.name = image.split("/")[-1]
    row.description = desc
    row.variables = variables
    row.ports = ports
    row.volumes = volumes
    row.readme_hash = readme_hash
    if popularity:
        row.popularity = popularity
    return row
