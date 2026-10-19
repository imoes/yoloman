#!/bin/sh
# PID 1 of a systemd test host. The pod's environment does not reach systemd services, so the values the
# registration and the agent need are written to an EnvironmentFile first; then systemd takes over as init.
set -e
mkdir -p /etc/e2e
{
  echo "E2E_ENROLL_URL=${E2E_ENROLL_URL}"
  echo "E2E_NAME=${E2E_NAME}"
  echo "E2E_ADDRESS=${E2E_ADDRESS}"
  echo "E2E_WRITE=${E2E_WRITE:-true}"
  echo "http_proxy=${http_proxy:-}"
  echo "https_proxy=${https_proxy:-}"
  echo "no_proxy=${no_proxy:-}"
} > /etc/e2e/env
exec /sbin/init
