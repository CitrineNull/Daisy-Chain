#!/bin/bash
set -e

# DuckDNS variables
DOMAIN=
TOKEN=
LOG_FILE=/var/log/duckdns.log

IPv6=$(curl -s https://api6.ipify.org)
IPv4=$(curl -s https://api.ipify.org)

SITE="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=${IPv4}&ipv6=${IPv6}&verbose=true"

curl -s $SITE -o $LOG_FILE