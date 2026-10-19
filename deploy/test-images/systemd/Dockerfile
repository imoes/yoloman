# A test HOST: the family's package-e2e image plus systemd as PID 1, so the agent runs as the packaged
# yoloman-agent.service and the wizard's "restart the service" step meets a real init — as on a managed host.
# Units that mean nothing in a container are masked: on AlmaLinux dev-mqueue/hugepages and the ask-password paths
# intermittently held sysinit.target in "waiting", and with it the enrollment and the agent (measured: 2 of 2 RH
# hosts stuck in `initializing` after a pod restart).
ARG BASE
FROM ${BASE}
ARG FAMILY
ARG http_proxy
ARG https_proxy
RUN if [ "$FAMILY" = debian ]; then \
      apt-get install -y -q --no-install-recommends systemd systemd-sysv dbus && rm -rf /var/cache/apt/archives/*.deb; \
    else \
      dnf -q -y install systemd && dnf clean packages; \
    fi \
 && for u in getty.target console-getty.service systemd-logind.service systemd-udevd.service \
             systemd-remount-fs.service sys-kernel-debug.mount sys-kernel-tracing.mount \
             dev-hugepages.mount dev-mqueue.mount sys-fs-fuse-connections.mount sys-kernel-config.mount \
             systemd-ask-password-console.path systemd-ask-password-wall.path systemd-firstboot.service \
             systemd-machine-id-commit.service; do \
      systemctl mask "$u" >/dev/null 2>&1 || true; done
COPY e2e-host-entrypoint.sh /usr/local/bin/e2e-host-entrypoint
COPY e2e-register.service /etc/systemd/system/e2e-register.service
COPY agent-e2e.conf /etc/systemd/system/yoloman-agent.service.d/e2e.conf
RUN chmod +x /usr/local/bin/e2e-host-entrypoint && systemctl enable e2e-register.service yoloman-agent.service
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/bin/e2e-host-entrypoint"]
