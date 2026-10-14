# Omega website

The public product site at <https://omega.naridon.com>. Plain HTML, CSS, and JavaScript; no framework, visitor database, analytics, or tracking cookies.

## Preview

From the repository root:

```sh
node Website/build.mjs
python3 -m http.server 8765 --bind 127.0.0.1 --directory Website/dist
```

Open <http://127.0.0.1:8765>. The build copies the existing Omega icon and bundled editor into `dist/`. The read-only preview uses synthetic notes and tasks with the real editor, isolated from all local notebooks. Other feature illustrations are illustrative, not live sessions. No relay connection is made by the website.

Download links begin at GitHub's latest release page, then resolve the latest official DMG through GitHub's public release API. If that request is unavailable or rate-limited, the release page remains usable. Visitors' browsers contact GitHub for that lookup; no analytics identifiers are used.

## Existing AWS host

The site shares the current relay domain. Keep `/live` and `/health` proxied to the existing loopback service. The website is served from `/srv/omega-website/current`; that symlink points at an immutable, timestamped directory in `/srv/omega-website/releases/`. Only public website files belong here. Notes, tokens, and relay state must never be included.

`Caddyfile` is the complete configuration for this dedicated host. Validate with `caddy validate` before installing; preserve a copy of the old configuration and release. Upload the built directory, switch the symlink atomically, and reload Caddy. Do not restart or replace the relay service to deploy website changes. Later static updates only need a symlink change. Retain old releases for rollback.

For a different host or domain, change the hostname and website root in `Caddyfile`, the canonical/social URLs in `index.html`, and `robots.txt`/`sitemap.xml`. There are no deployment credentials in this repository.

## Verify

Check Notes/Tasks switching, task List/Board navigation, keyboard tab switching, FAQ expansion, release links, image/font loading, and narrow screens. After deployment, verify the homepage and `/health`, and make a WebSocket handshake to `/live`. The relay process should have the same PID and start time before and after the website deployment.
