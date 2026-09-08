# egress-proxy

tinyproxy between `sandbox-net` and the internet — the only way a sandbox container reaches
anything outside itself. Containers get `HTTP_PROXY`/`HTTPS_PROXY` pointed at this service;
`network:"none"` sandboxes never reach it at all.

`tinyproxy.conf`'s `Allow` restricts *who* can connect (sandbox-net's CIDR, pinned in
`deploy/compose.yml`). `Filter`/`filter` restrict *where* they can go.

## Policy: open web, closed inside

Agents are meant to browse like a person (Grok-Bot style), so the proxy runs in **denylist
mode** (`FilterDefaultDeny No`): any public host on ports 80/443 is allowed, and `filter`
blocks everything that must never be reachable from a sandbox:

- single-label names (`localhost`, and every compose service: `core`, `postgres`,
  `pgbouncer`, `valkey`, `agent-runtime`, `sandbox-gateway`, …),
- `.local` / `.internal` / `.lan` / `.arpa` / … suffixes,
- loopback, RFC1918, link-local, CGNAT, multicast/reserved IPv4 ranges, IPv6 literals, and
  the decimal/hex/octal IP spellings,
- cloud metadata endpoints.

Each line is a POSIX extended regex matched against the request host — escape dots and
anchor with `^`/`$`. Add project-specific blocks below the marked line.

Known limit: DNS rebinding (a public name resolving to a private IP) is not caught at the
proxy. The internal HTTP services all require a signed `vibe-internal-auth/v1` header or the
gateway token, so a rebound request still gets 401 — keep it that way when adding services.

## Strict allowlist instead

Set `FilterDefaultDeny Yes` and list the allowed hosts in `filter` (e.g.
`^(.*\.)?github\.com$`). Everything unlisted is then blocked — a policy decision, not a
quick tweak: every reachable domain is also an exfiltration path.

Image: `vimagick/tinyproxy` or the official `tinyproxy` image, this directory mounted at
`/etc/tinyproxy/`.
