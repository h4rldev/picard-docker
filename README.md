# picard-docker

A Docker image for [Picard](https://picard.musicbrainz.org/), served as a remote
desktop in the browser. The runtime is an Erlang/OTP application, so the same
image runs as a single node or as a small cluster with sessions spread across
nodes.

## What it does

Opening the page gives you a desktop of your own: sway runs headless under a
per-session OS user with Picard inside it, and wayvnc streams the framebuffer
over a WebSocket that noVNC renders in the browser. Leaving the page freezes the
session into a per-account snapshot, and your next visit resumes it. A new
connection never attaches to a session that is already running, so two people
cannot steer one desktop.

Helium (a Chromium build), foot, and fuzzel are bundled as the in-session
browser, terminal, and launcher.

## Running one node

Prebuilt images are published to the GitHub Container Registry, so you can pull
one directly:

```sh
sudo docker run -d --name picard-node -p 8080:8080 --stop-timeout 60 \
  -e PICARD_STORAGE_GID=1000 \
  -v picard-data:/data -v /path/to/media:/storage \
  ghcr.io/h4rldev/picard-docker:latest
```

To build it yourself (the build downloads Helium from GitHub and needs a token,
passed as a build secret and never written to disk):

```sh
export GH_TOKEN=$(gh auth token)
sudo -E docker build --network host --secret id=gh_token,env=GH_TOKEN \
  -f image/Dockerfile -t ghcr.io/h4rldev/picard-docker:latest .
unset GH_TOKEN
```

Then open <http://localhost:8080/> and sign in. The first boot seeds a
`superadmin` / `superadmin` account, so change that password straight away.

`--stop-timeout 60` gives the container time to snapshot every running session on
shutdown. Docker's default of 10 seconds can kill a large home directory copy
mid-write.

### Configuration

Environment variables:

- `PICARD_JWT_SECRET`: base64url, unpadded, 32 bytes, used to sign session
  cookies. If it is unset, the app generates one and saves it to
  `/data/picard_jwt_secret.txt`, reusing it on restart. Generate your own with
  `openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'`; cluster nodes must
  share the same value.
- `PICARD_SUPERADMIN_USER` and `PICARD_SUPERADMIN_PASSWORD`: upserts the single
  superadmin on boot. If neither is set and no superadmin exists, the app seeds
  `superadmin` / `superadmin` and logs a warning.
- `PICARD_STORAGE_DIR`: shared directory mounted at `/storage` by default.
- `PICARD_STORAGE_GID`: group ID that owns the `/storage` mount, default `1000`.
  Set it to match the group that owns your media so sessions can save tags.
- `PICARD_CONFIG`: path to an optional JSON config file, default
  `/data/picard.config.json`. Environment variables win over the file, and the
  file wins over built-in defaults.
- `PICARD_COOKIE`: Erlang distribution cookie. If unset, the container generates
  one on first start and saves it to `/data/picard_erlang_cookie.txt`. All nodes
  in a cluster must share the same value, so set it explicitly there.

### Authentication

Authentication turns on as soon as the users table has at least one row. You log
in with a username and password and get an HttpOnly session cookie, which
authorizes both the session and the realtime desktop. An admin can list, create,
reset, kick, and delete users; only the superadmin can change roles.

Behind a reverse proxy, the proxy can identify the caller as a plain user with an
`X-Forwarded-User` header, which fits existing single sign-on. The node must not
be exposed directly in that setup, since any client could spoof the header.
Terminate TLS at the proxy, because the session cookie is marked Secure. See
[docs/gateway.md](docs/gateway.md) and the ready-made compose files in
[docs/compose](docs/compose) for Caddy, nginx, and Traefik.

## Running a cluster

The node starts a named Erlang node and joins peers over a shared cookie. A
cluster shares one user database and lets any node serve a session that another
node created.

```sh
cd cluster
sudo docker compose up -d
```

The example starts two nodes. Set `PICARD_COOKIE` and `PICARD_JWT_SECRET` in
`cluster/.env` first. A login on one node is then valid on the other, and a
desktop can be opened through any node.

Nodes find each other through `PICARD_SEED_NODES`, a comma separated list of
`picard@<hostname>`. Exactly one node sets `PICARD_DB_OWNER=1` and owns the
SQLite file; every other node forwards queries to it over Erlang distribution.
If the owner goes down, logins stop but running sessions keep running.

If every node mounts the same host directory at `/data/snapshots`, a session that
was on a node which dies is restored on a survivor the next time that account
connects. Only the last clean freeze is kept.

## Verifying a session

Freeze and resume through the API:

```sh
TOKEN=$(curl -s http://localhost:8080/route | jq -r .token)
curl http://localhost:8080/sleep/$TOKEN
curl http://localhost:8080/alive/$TOKEN
```

There is also a host-side self check:

```sh
./test/session_selfcheck.sh
```

## Building multi-arch images

The image builds for `linux/amd64` and `linux/arm64`. The CI workflow in
[.github/workflows/build.yml](.github/workflows/build.yml) builds each
architecture on a native runner and merges the two into one manifest, publishing
to the GitHub Container Registry.

## Shared storage

A directory is mounted at `/storage` (override with `PICARD_STORAGE_DIR`) and
symlinked into every session at `~/storage`. It is shared across sessions and
both nodes, and kept out of the per-account snapshot, so it is the place to keep
files you want to tag from Picard.

Sessions do not share a user, so read and write access goes through a group
instead: every session joins the `picard` group (`PICARD_STORAGE_GID`), and on
start the whole tree is made group-writable with setgid directories. Existing
media owned by that group becomes editable, and new files inherit the group.

## License

This project is licensed under the BSD 3-Clause License - see the
[LICENSE](LICENSE) file for details.
