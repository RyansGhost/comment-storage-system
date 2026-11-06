# rf-comments

[![Tests](https://github.com/RyansGhost/comment-storage-system/actions/workflows/test.yml/badge.svg?branch=master)](https://github.com/RyansGhost/comment-storage-system/actions/workflows/test.yml)

A tiny, self-hosted comment service for the `*.ryanfleck.ca` sites, written in
Common Lisp and served from **https://comments.ryanfleck.ca**.

- **One script tag to install**, like Disqus. Each comment thread is an
  auto-resizing iframe.
- **Many sites, one service.** Each site has its own allowed origins and theme,
  managed in a tiny admin GUI.
- **Email-verified comments.** Commenters give a display name and email. Each
  comment stays hidden until the emailed link is clicked. Emails go through
  **Amazon SES** (API v2, signed with SigV4; no SDK needed).
- **Gravatar profile images**, proxied through the server, so pages never
  expose a hash of anyone's email and readers' browsers never contact
  Gravatar.
- **Passwordless accounts.** Users sign in with a magic link to see their
  profile and every comment they've posted, and can delete them.
- **SQLite on the host.** Users, comment content, dates, and pages are stored
  in `./data/comments.db`, bind-mounted into the container.
- **Docker-first.** The image is a single 16 MB SBCL executable on Debian
  slim, runs as non-root, includes a healthcheck, and listens on localhost
  behind your existing reverse proxy.

The design notes and the reasoning behind each decision are in
[DESIGN.md](DESIGN.md).

---

## Contents

1. [Embedding comments on a page](#embedding-comments-on-a-page)
2. [Deploying on a VPS](#deploying-on-a-vps)
3. [Setting up Amazon SES](#setting-up-amazon-ses)
4. [Configuration](#configuration)
5. [Admin GUI](#admin-gui)
6. [Developing in Emacs](#developing-in-emacs)
7. [Testing](#testing)
8. [Project layout](#project-layout)
9. [Contributing: branching workflow](#contributing-branching-workflow)
10. [Operations: backups, upgrades, troubleshooting](#operations)

---

## Embedding comments on a page

First create a site in the admin GUI, for example key `blog` with origin
`https://blog.ryanfleck.ca`. Then paste this where the comments should go:

```html
<div id="rf-comments"></div>
<script src="https://comments.ryanfleck.ca/embed.js" data-site="blog" async></script>
```

Optional attributes on the `<script>` tag:

| Attribute | Default | Purpose |
|---|---|---|
| `data-site` | — (required) | Site key from the admin GUI |
| `data-page-id` | none | Stable thread id that survives URL changes (like `disqus_identifier`), e.g. `post-42` or a Hugo `.File.UniqueID`. 1–200 of `A-Z a-z 0-9 . _ : / -`. |
| `data-page-url` | `location.href` | Canonical URL for the thread. Use it when one article is reachable at several URLs. |
| `data-page-title` | `document.title` | Title shown on profile and admin pages |
| `data-target` | `rf-comments` | Id of the container element |

Without `data-page-id`, a thread is identified by the page's **origin +
path**. The query string and `#fragment` are ignored, and a trailing
`index.html` is dropped, so `/post/?utm=x` and `/post/index.html` share one
thread. Renaming a slug or moving domains would then start a new, empty
thread. With `data-page-id`, the thread follows the page and records its
new URL the next time it loads. Threads that already exist can be re-keyed
or merged from the admin.

For Hugo, a partial such as `layouts/partials/comments.html` holding the
snippet with `data-page-url="{{ .Permalink }}"` works well.

### Comment counts on index pages

To show "3 comments" next to each post on a list page, mark the spots and
include `count.js` once:

```html
<a href="/posts/hello/" data-rf-count></a>          <!-- counts the link's href -->
<span data-rf-count="post-42"></span>                <!-- a data-page-id -->
<script src="https://comments.ryanfleck.ca/count.js" data-site="blog" async></script>
```

An empty `data-rf-count` uses the element's `href`. A value starting with
`http(s):` is a page URL; anything else is a page id. One request fetches
every count on the page:
`GET /api/counts?site=blog&page=<url>&id=<page-id>…`, up to 100 keys,
cached for 60 s. The response is JSON keyed exactly as sent, with CORS for
the site's origins.

For static-site builds there is also a read-only JSON endpoint:
`GET /api/comments?site=blog&page=<url>`. It sends CORS headers for the
site's own origins.

> **Why an iframe?** It isolates styles in both directions and keeps all
> cookies on `comments.ryanfleck.ca`. Every blog is a `*.ryanfleck.ca`
> subdomain, so the iframe is *same-site* and its `SameSite=Lax` login cookie
> keeps working in browsers that block third-party cookies.

---

## Deploying on a VPS

Prerequisites: Docker with the compose plugin, and a reverse proxy that
already terminates TLS for your other programs (Caddy, nginx, Traefik…).

```bash
git clone <this repo> rf-comments && cd rf-comments
```

```bash
cp .env.example .env && $EDITOR .env      # PUBLIC_URL, ADMIN_PASSWORD, SES settings
```

```bash
mkdir -p data && sudo chown 10001:10001 data   # the container runs as uid 10001
```

```bash
docker compose up -d --build
```

```bash
curl -s http://127.0.0.1:8080/healthz      # → ok
```

1. Point a DNS `A`/`AAAA` record for `comments.ryanfleck.ca` at the server.
2. Add the reverse-proxy block: [`deploy/Caddyfile`](deploy/Caddyfile) or
   [`deploy/nginx.conf`](deploy/nginx.conf). Keep `TRUST_PROXY=true` so
   rate limiting sees real client IPs.
3. Open `https://comments.ryanfleck.ca/admin`, sign in with `ADMIN_PASSWORD`,
   and create a site.

The container only publishes `127.0.0.1:8080`, so it doesn't clash with other
services. Change the host port with `RF_COMMENTS_HOST_PORT` in `.env`. If your
proxy runs in Docker, uncomment the `networks:` lines in
[`docker-compose.yml`](docker-compose.yml) and point the proxy at
`rf-comments:8080`.

**The database lives outside the container** at `./data/comments.db`. It runs
in WAL mode, so `comments.db-wal` and `comments.db-shm` sit next to it. Always
mount the *directory*, not just the file.

---

## Setting up Amazon SES

1. **Verify a sending identity.** In the SES console (same region as
   `AWS_REGION`), create a *domain* identity for `ryanfleck.ca` and add the
   DKIM CNAME records it gives you. A domain identity is better than a single
   address because it signs mail with DKIM. Adding a custom MAIL FROM
   subdomain and a DMARC record further improves deliverability.
2. **Leave the sandbox.** New SES accounts can only send to verified
   addresses. Request production access ("Get set up" → *Request production
   access*) and describe the use: transactional verification emails for a
   comment system.
3. **Create an IAM user (or role) that can only send.** Attach
   [`deploy/ses-policy.json`](deploy/ses-policy.json), which allows
   `ses:SendEmail` from `comments@ryanfleck.ca` only. Create an access key and
   put it in `.env`.
4. Set `EMAIL_BACKEND=ses` and `SES_FROM="Ryan Fleck Comments <comments@ryanfleck.ca>"`.
   Optionally set `SES_CONFIGURATION_SET` for bounce/complaint tracking.

If a send fails, the comment is still saved, the user sees "we couldn't send
the confirmation email", and the SES error is logged
(`docker compose logs comments`).

---

## Configuration

All configuration comes from environment variables (`.env`):

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_URL` | `http://localhost:8080` | External origin. Used in email links and to check the `Origin` of every POST (CSRF defence). |
| `PORT` | `8080` | Listen port inside the container |
| `DB_PATH` | `/data/comments.db` | SQLite file |
| `ADMIN_PASSWORD` | *(unset)* | Admin password. Unset disables `/admin`. |
| `ADMIN_EMAIL` | *(unset)* | Address to notify whenever a commenter publishes a comment. Unset disables notifications. |
| `EMAIL_BACKEND` | `log` | `ses`, or `log` to print emails (with links) to the log |
| `SES_FROM` | | From address; must be a verified SES identity |
| `AWS_REGION` | `us-east-1` | SES region |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | | Credentials for `ses:SendEmail` |
| `AWS_SESSION_TOKEN` | | For temporary credentials |
| `SES_CONFIGURATION_SET` | | Optional SES configuration set |
| `AVATARS` | `gravatar` | `gravatar` shows profile images next to comments; `off` hides them |
| `AVATAR_DEFAULT` | `identicon` | Image for addresses with no Gravatar: `identicon`, `mp`, `monsterid`, `wavatar`, `retro`, `robohash`, `blank` |
| `TRUST_PROXY` | `false` | Take the client IP from the last `X-Forwarded-For` entry |
| `COOKIE_SECURE` | on if `PUBLIC_URL` is https | Mark cookies `Secure` |
| `SLYNK_PORT` | *(unset: no REPL)* | Port for the [live REPL](#live-repl-in-production) |
| `SLYNK_SECRET` | | Required with `SLYNK_PORT`, 16+ characters |
| `SLYNK_INTERFACE` | `127.0.0.1` | Interface the REPL binds to (`0.0.0.0` inside Docker, via the override file) |

Tunables (limits, token lifetimes) are special variables at the top of
[`src/config.lisp`](src/config.lisp).

---

## Admin GUI

`/admin` (password from `ADMIN_PASSWORD`, session cookie scoped to `/admin`,
12 h):

- **Sites:** create, edit, enable/disable, or delete. Set the allowed origins
  (one per line); only pages on those origins can embed or post to the site.
  The thread iframe sends a matching `Content-Security-Policy: frame-ancestors`.
- **Style:** colour scheme (light/dark/auto), accent, text, muted, background,
  surface and border colours, font stack, corner radius, and free-form custom
  CSS. All are applied inside the iframe. A live preview and the embed snippet
  appear on the edit page.
- **Moderation:** recent comments, filterable by status, with publish, hide,
  and delete actions.
- **Stats:** published, pending and hidden counts per site; comments per day
  over the last 30 days; and the most-commented threads. All are computed
  by SQLite `GROUP BY`, with no JavaScript in the admin.
- **Threads:** each site's page lists its threads (key, current URL,
  comment count). A *Move* form changes a thread's key and/or URL, for
  example to adopt a `data-page-id` after the fact. Moving onto a key another
  thread already uses merges the two.
- **Activity:** an audit log of the last 50 publish/hide/delete actions and
  who did them (`author` or `admin`). Entries outlive deleted comments.
- **Notifications:** with `ADMIN_EMAIL` set, you get an email each time a
  commenter publishes a comment (via the verify link or while signed in),
  with a link to the moderation queue. Your own admin actions never notify.

### How commenting works

1. A visitor enters a name, email, and comment. The comment is stored as
   `pending`, and SES sends a "Publish my comment" link (single use, 48 h).
   The author sees their own pending comment marked *awaiting email
   confirmation*.
2. Clicking the link shows a confirmation button. GET never changes state, so
   mail-scanner prefetches can't burn the token. Confirming publishes the
   comment, marks the email verified, signs the user in, and returns them to
   the page.
3. Signed-in users' comments publish immediately. A comment typed anonymously
   with someone else's address never appears unless that person clicks the
   link.
4. Anyone can sign in at `/login` with a magic link. `/me` shows their
   profile (display name editable) and all their comments, each with its
   status and a delete button.

**Profile images.** Each comment shows its author's
[Gravatar](https://gravatar.com), or a generated identicon if they don't
have one. A note at the bottom of every comment section says where the
images come from, and the profile page tells users how to change theirs.

Gravatar looks people up by the SHA-256 of their email. Linking to it
directly would put that hash in every page, where it can be reversed by
guessing addresses. So pages use `/avatar/<random key>`, and the server
fetches from Gravatar itself. It caches each image for 24 hours and only
accepts PNG/JPEG/GIF/WebP. If Gravatar can't be reached, it draws the
person's initial instead. Set `AVATARS=off` to disable all of this.

Spam defences: a hidden honeypot field, a per-IP posting rate limit, a
per-address email limit (5/hour), a 5000-character limit, and moderation.

---

## Developing in Emacs

The project is a plain ASDF system, and any SBCL + Quicklisp + SLY setup can
load it. The steps below take you from nothing to a live-reloading dev server
with tests running in the REPL.

### 1. Install SBCL

Use a recent SBCL (2.4 or newer; Docker uses Debian trixie's 2.5.x):

| OS | Command |
|---|---|
| macOS | `brew install sbcl` |
| Debian 13 / Ubuntu 25.04+ | `sudo apt install sbcl` |
| Arch | `sudo pacman -S sbcl` |
| Anything, newest release | Download the binary from [sbcl.org/platform-table.html](https://www.sbcl.org/platform-table.html), then run `sh install.sh` |

Also install the native libraries the project loads through CFFI:
`libsqlite3` and OpenSSL. They're already present on macOS. On Debian/Ubuntu:

```bash
sudo apt install libsqlite3-0 libssl3 sqlite3
```

### 2. Install Quicklisp (the library manager)

```bash
curl -O https://beta.quicklisp.org/quicklisp.lisp
```

```bash
sha256sum quicklisp.lisp   # expect 4a7a5c2aebe0716417047854267397e24a44d0cce096127411e9ce9ccfeb2c17
```

```bash
sbcl --non-interactive --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' --eval '(ql-util:without-prompting (ql:add-to-init-file))'
```

This installs `~/quicklisp/` and makes `~/.sbclrc` load it at startup. To make
sure your libraries are the **latest** available, update the dists now and
then from a REPL:

```lisp
(ql:update-client)
(ql:update-all-dists)
```

Optional: for libraries newer than the monthly Quicklisp dist, add
[Ultralisp](https://ultralisp.org), which rebuilds from upstream every few
minutes:

```lisp
(ql-dist:install-dist "http://dist.ultralisp.org/" :prompt nil)
```

(The Docker build pins Quicklisp dist `2026-01-01` for reproducibility.
Change `QL_DIST` in the `Dockerfile` to move it forward.)

Make the project visible to Quicklisp by linking it into `local-projects`:

```bash
ln -s "$PWD" ~/quicklisp/local-projects/rf-comments
```

### 3. Configure Emacs

Use Emacs 29 or newer, which has `use-package` built in. Add this to
`~/.emacs.d/init.el`:

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless package-archive-contents (package-refresh-contents))
(setq use-package-always-ensure t)

;; SLY: the Common Lisp IDE (REPL, debugger, inspector, xref, stepper).
(use-package sly
  :custom
  (inferior-lisp-program "sbcl --dynamic-space-size 2048")
  (sly-lisp-implementations '((sbcl ("sbcl" "--dynamic-space-size" "2048")))))

;; Quicklisp and ASDF commands inside SLY (M-x sly-quickload, sly-asdf-test-system…).
(use-package sly-quicklisp :after sly)
(use-package sly-asdf :after sly)

;; Structural editing and readable parens.
(use-package paredit
  :hook ((lisp-mode emacs-lisp-mode sly-mrepl-mode) . enable-paredit-mode))
(use-package rainbow-delimiters
  :hook ((lisp-mode emacs-lisp-mode sly-mrepl-mode) . rainbow-delimiters-mode))

;; In-buffer completion popups (SLY feeds it flex-matched symbols).
(use-package corfu
  :init (global-corfu-mode)
  :custom (corfu-auto t))

;; Optional: highlight the matching paren, and show docs in the echo area.
(show-paren-mode 1)
```

Restart Emacs, or `M-x eval-buffer`. To pull the newest Emacs packages later,
run `M-x package-upgrade-all` (Emacs 29+).

> Prefer SLIME? Replace the SLY block with `(use-package slime :custom
> (inferior-lisp-program "sbcl"))` and use `M-x slime`. Everything below works
> the same; only the key prefixes differ slightly. SLY is recommended: it's a
> maintained fork of SLIME with a better REPL, stickers, and backreferences.

### 4. Daily workflow

Open any file in the project, then:

| Step | How |
|---|---|
| Start Lisp | `M-x sly` |
| Load the project and start the dev server | `(load "dev/start.lisp")` in the REPL. This seeds a `dev` site for `http://localhost:8000`, uses admin password `admin`, and prints emails (with links) to the REPL. |
| Admin | <http://localhost:8080/admin> |
| Try the widget | Serve any page with the embed snippet (`data-site="dev"`) from port 8000, e.g. `python3 -m http.server 8000`. Or open <http://localhost:8080/thread?site=dev&page=http://localhost:8000/>. |
| Recompile one definition | `C-c C-c` on a `defun`/`defroute`. The **running server uses it immediately**, no restart. |
| Recompile the file | `C-c C-k` |
| Jump to definition / back | `M-.` / `M-,` |
| Describe a symbol | `C-c C-d d` |
| Inspect a value | `C-c I` (e.g. `(rf-comments::site-by-key "dev")`) |
| Macroexpand | `C-c M-m` on a form |
| Query the DB | `(rf-comments:query "SELECT * FROM comments")` |
| Restart the server | `(rf-comments:start)`; stop with `(rf-comments:stop)` |
| Edited `static/*.js` | `(rf-comments::reload-static)` |
| Debug a request error | `(setf hunchentoot:*catch-errors-p* nil)`, and errors in route handlers then open the SLY debugger, where `v` jumps to the source frame. |

### 5. Running tests from Emacs

```lisp
(asdf:test-system :rf-comments)                       ; everything
(rf-comments/tests:run-tests)                         ; same, returns T/NIL
(fiveam:run! 'rf-comments/tests::unit)                ; one suite: unit, sigv4, integration
(fiveam:run! 'rf-comments/tests::magic-link-login)    ; one test
```

You can also run `M-x sly-asdf-test-system RET rf-comments`. Failed checks
print the expression and the actual value. If you set
`(setf fiveam:*on-error* :debug)`, an error inside a test opens the debugger
right where it happened.

The integration tests start a second server on a random port with a
temporary database. They briefly swap the global configuration and the
database handle, then restore them, so it's safe to run them with the dev
server up (dev requests made *during* a test run would hit the test
database).

---

## Testing

From a shell:

```bash
make test          # FiveAM suite on your local SBCL
```

```bash
make docker-test   # the same suite inside the Docker build image
```

**CI:** [`.github/workflows/test.yml`](.github/workflows/test.yml) runs on
every push to any branch and on pull requests. It runs the suite in the
Dockerfile's `test` stage, builds the runtime image, and smoke-tests the
container: `/healthz`, `embed.js`, the admin login page, a database file on
the host, Docker's healthcheck, and a clean shutdown.

The suite has 177 checks:

- **unit:** URL canonicalisation, origins, validation, escaping, rate limiting,
  tokens and sessions, migrations, and theme CSS containment.
- **sigv4:** the signer checked against AWS's published signing-key example,
  AWS's `get-vanilla` test-suite vector, and signatures generated by botocore
  for an SES `SendEmail` request.
- **integration:** a real HTTP server driven through admin login and site
  setup, the CSRF check, posting, verification, login, profile, rename,
  delete, spoofing attempts, moderation, the honeypot, rate and email limits,
  themes, the JSON API, and the healthcheck.

---

## Project layout

```
rf-comments.asd        ASDF systems: rf-comments and rf-comments/tests
src/
  package.lisp         package definition
  config.lisp          env-var configuration + tunables
  util.lisp            time, crypto, URL canonicalisation, validation, rate limiter
  db.lisp              SQLite connection, migrations, data model queries
  events.lisp          publish/hide/remove as generic functions; :after observers
  avatars.lisp         Gravatar proxy + cache, SVG-initial fallback
  email.lisp           SES v2 SendEmail + SigV4 signer + email templates
  views.lisp           Spinneret layout, CSS, per-site themes
  routes.lisp          request helpers, decorators, defpage/defaction/with-valid-inputs
  web.lisp             public routes: /thread, /verify, /login, /me, /api, /embed.js
  admin.lisp           /admin: sites, themes, moderation
  repl.lisp            opt-in live REPL (Slynk) with secret + hardening
  main.lisp            start/stop, executable entry point, healthcheck
static/embed.js        the loader script sites include
static/thread.js       iframe height reporting (postMessage)
static/count.js        fills in "N comments" on index pages
tests/                 FiveAM suites (unit, sigv4, integration)
dev/start.lisp         REPL bootstrap for development
build.lisp             builds bin/rf-comments (save-lisp-and-die)
Dockerfile             build → test → runtime stages
docker-compose.yml     production service definition
docker-compose.repl.yml  opt-in override exposing the live REPL on loopback
deploy/                Caddy / nginx examples, SES IAM policy
DESIGN.md              requirements, gaps filled, architecture
```

Libraries: hunchentoot and easy-routes (HTTP), sqlite (cl-sqlite), spinneret
(HTML), com.inuoe.jzon (JSON), ironclad (SHA-256/HMAC/random), dexador (HTTPS
client), quri, cl-ppcre, bordeaux-threads, and fiveam for tests.

---

## Contributing: branching workflow

`master` is always deployable. For every feature or fix:

1. Create a new, descriptively named branch from the latest `master`, such as
   `feature/reply-threads`, `fix/ses-retry-on-throttle`, or `docs/backup-guide`.
2. Work on that branch until the feature is complete and tested (`make test`,
   plus `make docker-test` for build changes). Push it so GitHub Actions
   runs, and wait for a green run.
3. Merge it into `master` with `git merge --no-ff`, then push `master`.
4. Leave the merged branch in place as a record of the work. The next change
   gets a fresh branch.

The same rules, plus project conventions for AI agents, are in
[AGENTS.md](AGENTS.md). [CLAUDE.md](CLAUDE.md) imports AGENTS.md.

---

## Operations

**Backups.** SQLite's online backup is safe while the service runs:

```bash
sqlite3 data/comments.db ".backup 'data/backup-$(date +%F).db'"
```

`make backup` does the same. Copy the result off-host, for example from a
daily cron job.

**Upgrades.** Pull the new code, then rebuild. Schema migrations run
automatically at startup.

```bash
git pull && docker compose up -d --build
```

### Live REPL in production

As in the book, you can attach SLY to the **running** service: inspect
state, try a query, or redefine a function without a restart. It's off by
default and should stay off unless you need it, because **anyone who can
reach the port and knows the secret can run arbitrary code** in the
service.

1. Pick a long random secret. Put it in `.env` as `SLYNK_SECRET=…`, and the
   same value as the first line of `~/.sly-secret` on your own machine (SLY
   sends it when connecting).
2. Start with the override, which publishes port 4005 on the server's
   loopback only:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.repl.yml up -d
   ```

3. Tunnel from your machine, then in Emacs run
   `M-x sly-connect RET localhost RET 4005`:

   ```bash
   ssh -N -L 4005:127.0.0.1:4005 your-vps
   ```

4. You're in the production image: `(in-package :rf-comments)`, then
   `(query "SELECT count(*) FROM comments")`, `C-c C-c` a fixed `defun`,
   and so on. Changes live only in memory, so commit real fixes and
   redeploy.
5. Turn it off by going back to the plain compose file:

   ```bash
   docker compose up -d
   ```

Safeguards:
- no REPL unless `SLYNK_PORT` is set;
- it refuses to start without a 16+ character secret;
- it binds 127.0.0.1 unless `SLYNK_INTERFACE` says otherwise;
- connections with the wrong secret are logged and dropped, and can't crash
  the service.

Don't enable it while the container is attached to a shared Docker
network.

**Logs.** Access and error logs go to the container log:

```bash
docker compose logs -f comments
```

**Troubleshooting**

| Symptom | Fix |
|---|---|
| `unable to open database file` at startup | `sudo chown 10001:10001 data` |
| Verification emails never arrive | Check the logs for `SES error`. SES may still be in the sandbox, the identity may be unverified, or the region may be wrong. |
| Widget shows "Comments are not enabled for this domain" | Add the page's exact origin (scheme + host + port) to the site in `/admin` |
| Widget doesn't render; console shows a `frame-ancestors` error | Same as above: the embedding origin isn't in the site's list |
| POSTs return 403 | `PUBLIC_URL` must exactly match the public origin (scheme and host) |
| Docker Hub rate limits during build | `docker build --build-arg DEBIAN_IMAGE=public.ecr.aws/docker/library/debian:trixie-slim .` |
