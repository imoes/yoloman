# AlmaLinux 9 + EPEL + CRB — the repo set the RedHat universe was measured from (rh_universe.py).
FROM almalinux:9
ARG http_proxy
ARG https_proxy
# REPO_SNAPSHOT (the build date, from build.sh) is part of this layer's cache key: without it the baked index comes
# from the Docker cache for as long as the base image does, and an index that never expires drifts from the mirror
# release by release. Refreshed once a day of building.
ARG REPO_SNAPSHOT
# Metadata baked in and never expired for the life of the image: otherwise every fresh pod re-downloads
# BaseOS + AppStream + CRB + EPEL metadata before its first package.
# The base tools of an EL9 minimal install (@core) the container image lacks — procps-ng first: init scripts and
# postinsts call `ps`/`pidof`. @core itself is not taken: it brings firewalld and sshd, which would start inside a
# test host and change what the network looks like to the role under test.
RUN echo "repo snapshot ${REPO_SNAPSHOT}" && dnf -q -y install epel-release dnf-plugins-core python3 \
      procps-ng cronie logrotate iproute iputils less kmod findutils which hostname shadow-utils util-linux \
 && dnf config-manager --set-enabled crb \
 && echo "metadata_expire=-1" >> /etc/dnf/dnf.conf \
 && dnf -q makecache \
 && dnf clean packages
COPY agent.rpm /tmp/agent.rpm
RUN dnf -q -y install /tmp/agent.rpm && rm /tmp/agent.rpm && /usr/bin/agentic-mcpd --version
COPY e2e-one.py /usr/local/bin/e2e-one
ENTRYPOINT ["python3", "/usr/local/bin/e2e-one"]
