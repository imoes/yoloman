# Debian 13 (trixie) — the suite the Debian package corpus was extracted from (qualify_packages DEB_SUITE).
# One image, one fresh pod per package: nothing a previous package installed can make the next one pass.
FROM debian:trixie
ARG http_proxy
ARG https_proxy
ENV DEBIAN_FRONTEND=noninteractive
# REPO_SNAPSHOT (the build date, from build.sh) is part of this layer's cache key: without it the baked index comes
# from the Docker cache for as long as the base image does, and an index that never expires drifts from the mirror
# release by release. Refreshed once a day of building.
ARG REPO_SNAPSHOT
# The package index is baked in: a fresh pod per package must not spend a minute on `apt-get update` first.
# No service may start during install — there is no init in the pod, and a postinst that starts a daemon would
# test the package's defaults, not the configuration this suite writes.
# Every package of priority "important" — what every installed Debian system has and the docker base image lacks.
# Found one at a time first: without adduser a postinst's `adduser --system` was skipped (217/USER); without procps
# isc-dhcp-server's init script could not `ps -p` the dhcpd it had just started and reported "failed!" with dhcpd
# running. Both facts about the image, not the packages — so the image takes the whole tier, computed from the
# archive at build time (trixie: adduser, cron, iproute2, logrotate, procps, systemd, … 33 packages).
RUN echo "repo snapshot ${REPO_SNAPSHOT}" && printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d \
 && apt-get update -q \
 && apt-get install -y -q --no-install-recommends python3 ca-certificates \
      $(apt-cache dumpavail | awk '/^Package:/{p=$2} /^Priority: important/{print p}' | sort -u) \
 && rm -rf /var/cache/apt/archives/*.deb
COPY agent.deb /tmp/agent.deb
RUN apt-get install -y -q /tmp/agent.deb && rm /tmp/agent.deb && /usr/bin/agentic-mcpd --version
COPY e2e-one.py /usr/local/bin/e2e-one
ENTRYPOINT ["python3", "/usr/local/bin/e2e-one"]
