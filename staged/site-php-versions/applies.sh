#!/usr/bin/env bash
# nginx servers without cPanel only; cPanel sites are collected another way.
[ -r /etc/nginx/nginx.conf ] && [ ! -d /var/cpanel ] && command -v python3 >/dev/null 2>&1
