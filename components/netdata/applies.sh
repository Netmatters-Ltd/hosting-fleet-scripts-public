#!/usr/bin/env bash
# Servers whose fleet-agent.conf has NETDATA_CLAIM_TOKEN and
# NETDATA_CLAIM_ROOMS.
# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ -n "${NETDATA_CLAIM_TOKEN:-}" ] && [ -n "${NETDATA_CLAIM_ROOMS:-}" ]
