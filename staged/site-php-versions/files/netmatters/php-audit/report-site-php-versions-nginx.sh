#!/usr/bin/env bash
# Audits every nginx site on this VPS and which PHP version it runs, then
# POSTs the list to $N8N_BASE/webhook/hosting-fleet-site-php-versions with
# the fleet token. N8N_BASE and FLEET_TOKEN come from
# /netmatters/fleet-agent/fleet-agent.conf.
#
# How the PHP version is worked out, per nginx server block:
#   - nginx.conf is parsed with every include expanded (so shared snippets
#     and Forge's forge-conf/ are followed).
#   - fastcgi_pass is matched to a PHP-FPM pool by its listen address
#     (/etc/php/X.Y/fpm/pool.d/*.conf), which gives the version, the pool
#     name, its config file and the pool user. If no pool matches, the
#     version is read from the socket name (e.g. php7.4-fpm-examplecom.sock).
#   - Blocks that only redirect (return 301 etc.) and catch-all "_" blocks
#     with no PHP are skipped, so the list is real sites only.
#
# Needs python3 (any 3.4+, so old Ubuntu boxes are fine) and curl. Run as
# root so per-user include files under /home can be read.
#
# Usage: report-site-php-versions-nginx.sh [--dry-run]

set -euo pipefail

# shellcheck disable=SC1091
. /netmatters/fleet-agent/fleet-agent.conf
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-site-php-versions"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found - can't audit nginx sites." >&2; exit 1; }
[ -r "$NGINX_CONF" ] || { echo "$NGINX_CONF not readable - is this an nginx server?" >&2; exit 1; }

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

payload="$(HOSTNAME_FQDN="$HOSTNAME_FQDN" NGINX_CONF="$NGINX_CONF" PHP_ETC_ROOT="${PHP_ETC_ROOT:-}" python3 - <<'PY'
import glob, json, os, re, subprocess

NGINX_CONF = os.environ['NGINX_CONF']
CONF_DIR = os.path.dirname(NGINX_CONF)

TOKEN_RE = re.compile(r'''\s+|"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([{};])|(#[^\n]*)|([^\s{};"']+)''')


def tokenize(text):
    out = []
    for m in TOKEN_RE.finditer(text):
        dq, sq, punct, comment, word = m.groups()
        if comment is not None:
            continue
        if punct is not None:
            out.append(('p', punct))
        elif dq is not None:
            out.append(('w', dq))
        elif sq is not None:
            out.append(('w', sq))
        elif word is not None:
            out.append(('w', word))
    return out


def parse_tokens(tokens, pos, path):
    nodes, words = [], []
    while pos < len(tokens):
        kind, val = tokens[pos]
        pos += 1
        if kind == 'w':
            words.append(val)
        elif val == ';':
            if words:
                nodes.append({'name': words[0], 'args': words[1:], 'block': None, 'file': path})
            words = []
        elif val == '{':
            children, pos = parse_tokens(tokens, pos, path)
            nodes.append({'name': words[0] if words else '', 'args': words[1:], 'block': children, 'file': path})
            words = []
        elif val == '}':
            return nodes, pos
    return nodes, pos


def load(path, stack):
    real = os.path.realpath(path)
    if real in stack or len(stack) > 15:
        return []
    try:
        with open(path, errors='replace') as fh:
            text = fh.read()
    except (IOError, OSError):
        return []
    nodes, _ = parse_tokens(tokenize(text), 0, path)
    return expand(nodes, stack + [real])


def expand(nodes, stack):
    out = []
    for n in nodes:
        if n['name'] == 'include' and n['block'] is None and n['args']:
            pattern = n['args'][0]
            if not os.path.isabs(pattern):
                pattern = os.path.join(CONF_DIR, pattern)
            for f in sorted(glob.glob(pattern)):
                if os.path.isfile(f):
                    out.extend(load(f, stack))
            continue
        if n['block'] is not None:
            n['block'] = expand(n['block'], stack)
        out.append(n)
    return out


def walk(nodes, name):
    for n in nodes:
        if n['name'] == name:
            yield n
        if n['block']:
            for x in walk(n['block'], name):
                yield x


# ---- PHP-FPM pools: listen address -> version, user -------------------------

def norm_listen(addr):
    addr = addr.strip()
    if addr.startswith('unix:'):
        addr = addr[5:]
    if addr.startswith('/'):
        return os.path.realpath(addr)
    port = addr.rsplit(':', 1)[-1]
    return 'tcp:' + port


pools = {}
ETC = os.environ.get('PHP_ETC_ROOT', '') + '/etc'  # override only for testing
pool_files = glob.glob(ETC + '/php/*/fpm/pool.d/*.conf') + glob.glob(ETC + '/php/*/fpm/php-fpm.conf') \
    + glob.glob(ETC + '/php5/fpm/pool.d/*.conf') + glob.glob(ETC + '/php5/fpm/php-fpm.conf')
for pf in pool_files:
    m = re.search(r'/etc/php/(\d+\.\d+)/', pf)
    version = m.group(1) if m else '5'
    section, user = None, ''
    try:
        lines = open(pf, errors='replace').read().splitlines()
    except (IOError, OSError):
        continue
    entries = []
    for line in lines:
        line = line.split(';', 1)[0].strip()
        sm = re.match(r'^\[(.+)\]$', line)
        if sm:
            section = sm.group(1)
            continue
        kv = re.match(r'^([\w.]+)\s*=\s*(.+)$', line)
        if not kv or section is None or section == 'global':
            continue
        key, val = kv.group(1), kv.group(2).strip().strip('"\'')
        val = val.replace('$pool', section)
        entries.append((section, key, val))
    users = dict((s, v) for s, k, v in entries if k == 'user')
    for s, k, v in entries:
        if k == 'listen':
            pools[norm_listen(v)] = {'version': version, 'user': users.get(s, ''), 'pool': s, 'file': pf}

full_version_cache = {}


def full_version(short):
    if short in full_version_cache:
        return full_version_cache[short]
    candidates = ['/usr/sbin/php-fpm' + short, '/usr/bin/php' + short]
    if short == '5':
        candidates = ['/usr/sbin/php5-fpm', '/usr/bin/php5']
    result = ''
    for c in candidates:
        if os.access(c, os.X_OK):
            try:
                out = subprocess.check_output([c, '-v'], stderr=subprocess.STDOUT).decode('utf-8', 'replace')
                m = re.search(r'PHP (\S+)', out)
                if m:
                    result = m.group(1)
                    break
            except (subprocess.CalledProcessError, OSError):
                pass
    full_version_cache[short] = result
    return result


# ---- Parse nginx ------------------------------------------------------------

tree = load(NGINX_CONF, [])

upstreams = {}
for up in walk(tree, 'upstream'):
    if up['args']:
        servers = [s['args'][0] for s in (up['block'] or []) if s['name'] == 'server' and s['args']]
        if servers:
            upstreams[up['args'][0]] = servers[0]


def resolve_php(target):
    # Returns (version, pool) - pool is the matching PHP-FPM pool dict, or None
    target = upstreams.get(target, target)
    if 'hhvm' in target.lower():
        return 'hhvm', None
    pool = pools.get(norm_listen(target)) if not target.startswith('$') else None
    if pool:
        return pool['version'], pool
    m = re.search(r'php[-_]?(\d)\.(\d{1,2})', target) or re.search(r'php(\d)(\d)(?!\d)', target)
    if m:
        return m.group(1) + '.' + m.group(2), None
    m = re.search(r'php(\d)-fpm', target)  # Ubuntu 14.04 era: /var/run/php5-fpm.sock
    if m:
        return m.group(1), None
    return 'unknown', None


sites, seen = [], set()

for server in walk(tree, 'server'):
    block = server['block']
    if block is None:
        continue  # "server" inside an upstream block
    top = dict((n['name'], n['args']) for n in block if n['block'] is None)

    names = []
    for n in block:
        if n['name'] == 'server_name':
            names.extend(n['args'])
    names = [x for x in names if x not in ('_', '""', '')]

    fastcgi = [n['args'][0] for n in walk(block, 'fastcgi_pass') if n['args']]
    proxies = [n['args'][0] for n in walk(block, 'proxy_pass') if n['args']]
    root = (top.get('root') or [''])[0]
    if not root:
        roots = [n['args'][0] for n in walk(block, 'root') if n['args']]
        root = roots[0] if roots else ''

    if not fastcgi and not proxies:
        if 'return' in top or not names or names[0] in ('localhost',):
            continue  # redirect-only or catch-all block

    domain = names[0] if names else '(default)'
    aliases = ' '.join(names[1:])

    pool = None
    if fastcgi:
        version, pool = resolve_php(fastcgi[0])
        handler, site_type, is_fpm = fastcgi[0], 'php', version != 'hhvm'
    elif proxies:
        version, handler, site_type, is_fpm = 'none', proxies[0], 'proxy', False
    else:
        version, handler, site_type, is_fpm = 'none', '', 'static', False
    user = pool['user'] if pool else ''

    if not user:
        m = re.match(r'^/home/([^/]+)/', root)
        user = m.group(1) if m else ''

    key = (domain, handler, root)
    if key in seen:
        continue  # same site defined for both :80 and :443
    seen.add(key)

    sites.append({
        'domain': domain,
        'aliases': aliases,
        'account': user,
        'document_root': root,
        'php_version': version,
        'php_full_version': full_version(version) if re.match(r'^\d', version) else '',
        'php_handler': handler,
        'php_fpm': 'yes' if is_fpm else 'no',
        'php_fpm_pool': pool['pool'] if pool else '',
        'php_fpm_pool_file': pool['file'] if pool else '',
        'site_type': site_type,
        'config_file': server['file'],
    })

print(json.dumps({'hostname': os.environ['HOSTNAME_FQDN'], 'platform': 'nginx', 'sites': sites}))
PY
)"

site_count="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sites"]))')"
if [ "$site_count" -eq 0 ]; then
  echo "No nginx sites found from $NGINX_CONF - nothing to report." >&2
  exit 1
fi

if [ "${1:-}" = "--dry-run" ]; then
  printf '%s\n' "$payload" | python3 -m json.tool
  exit 0
fi

curl -fsS --max-time 60 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload"
echo
