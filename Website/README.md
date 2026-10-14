# Omega website

The public product site at <https://omega.naridon.com>. Plain HTML, CSS, and JavaScript; no framework, visitor database, analytics, or tracking cookies.

## Preview

From the repository root:

```sh
node Website/build.mjs
python3 -m http.server 8765 --bind 127.0.0.1 --directory Website/dist
```

Open <http://127.0.0.1:8765>. The build copies the Omega icon and native app screenshots into `dist/`. Notes/Tasks switches between captures of the real Mac app. Screenshots are passive images with no click action; a proportional edge mask cleans up the native capture corners without changing the UI. There is no browser editor, recreated app chrome, fictional chat interface, or simulated live session. No relay connection is made by the website.

## Product screenshots

`screenshots/` contains unretouched native window captures made on October 14, 2026 from release **v1.3.6** (`d57a454c36a7bddc4cc799b6dce4495210cc76a7`):

- `notes.jpg`: notes, native sidebar, document controls, search, archive, and footer.
- `tasks-board.jpg`: board with actual task/subtask cards and goal progress.
- `tasks-list.jpg`: list with an expanded task and its subtasks.
- `writing.jpg`: document appearance popover.

The release's unmodified views and editor were run in an isolated capture app with a synthetic notebook, separate defaults and recovery, dark appearance, default 140% app zoom, and a 1440 × 900 window. Captures are 2880 × 1800. Only launch setup and sample content differed; no view, icon, typography, spacing, color, or editor style was changed. No personal notebooks or credentials appear in the images.

When refreshing screenshots, use the current released app UI and fresh sample content. Capture through the native app; do not redraw controls, overlay invented features, recolor the interface, or patch the screenshot. Keep the entire window's aspect ratio when displaying it.

Download links begin at GitHub's latest release page, then resolve the latest official DMG through GitHub's public release API. If that request is unavailable or rate-limited, the release page remains usable. Visitors' browsers contact GitHub for that lookup; no analytics identifiers are used.

## Open source and self-hosting

The files section explains local files, recovery, and Git history. The dedicated self-hosting section links to `Relay/README.md` for Docker Compose, automatic HTTPS, repository allowlists, and connecting the Mac app. The relay diagram is an architecture explanation, not a simulated live session. Do not imply that the public relay accepts arbitrary repositories or stores notes.

## Existing AWS host

The site shares the current relay domain. Keep `/live` and `/health` proxied to the existing loopback service. The website is served from `/srv/omega-website/current`; that symlink points at an immutable, timestamped directory in `/srv/omega-website/releases/`. Only public website files belong here. Notes, tokens, and relay state must never be included.

`Caddyfile` is the complete configuration for this dedicated host. Validate with `caddy validate` before installing; preserve a copy of the old configuration and release. Upload the built directory, switch the symlink atomically, and reload Caddy. Do not restart or replace the relay service to deploy website changes. Later static updates only need a symlink change. Retain old releases for rollback.

For a different host or domain, change the hostname and website root in `Caddyfile`, the canonical/social URLs in `index.html`, and `robots.txt`/`sitemap.xml`. There are no deployment credentials in this repository.

## Verify

Check Notes/Tasks screenshot switching, absence of screenshot links/click actions, self-hosting links, keyboard tab switching, FAQ expansion, release links, image loading, and narrow screens. Verify that every app image comes from `screenshots/`, without added HTML controls or cropping. After deployment, verify the homepage and `/health`, and make a WebSocket handshake to `/live`. The relay process should have the same PID and start time before and after the website deployment.
