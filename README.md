# picard-docker

A Docker image for [Picard](https://picard.musicbrainz.org/), served as a remote
desktop in the browser. The runtime is an Erlang/OTP application, so the same
image can run as a single node or as a small cluster with sessions distributed
across nodes.

## What it does

Each browser connection gets its own desktop by launching sway (headless) and
Picard under a per-session OS user, then streaming the framebuffer with wayvnc
over a WebSocket that noVNC renders in the page. Sessions are scoped to the
account, not the container: a user can have one session at a time, frozen when
they leave and resumed when they return, with their home directory preserved.

The image also bundles Helium (a Chromium build) as an in-session browser, foot
as a terminal, and fuzzel as a launcher.

## Running one node

Build and run the image:

```sh
sudo docker build --network host -f image/Dockerfile -t ghcr.io/h4rl/picard-docker:latest .
sudo docker run -d --name picard-node -p 8080:8080 --stop-timeout 60 \
  -v picard-data:/data -v picard-storage:/storage ghcr.io/h4rl/picard-docker:latest
```

Then open <http://localhost:8080/>. Without a proxy the account is `generic`.

The `--stop-timeout 60` gives the container time to snapshot every running
session on shutdown. Docker's default of 10 seconds can kill a large home
directory copy mid-write.

### Configuration

Environment variables:

- `PICARD_JWT_SECRET`: base64url, unpadded, 32 bytes. Required unless the
  secret file already exists on the mounted volume. If it is missing, the app
  writes a value to `/data/picard_jwt_secret.txt` and exits so you can copy it
  into your environment. Generate one with
  `openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'`.
- `PICARD_SUPERADMIN_USER` and `PICARD_SUPERADMIN_PASSWORD`: upserts the single
  superadmin on boot. If neither is set and no superadmin exists, the app seeds
  `superadmin` / `superadmin` and logs a warning.
- `PICARD_STORAGE_DIR`: shared directory mounted at `/storage` by default.
- `PICARD_CONFIG`: path to an optional JSON config file, default
  `/data/picard.config.json`. Environment variables win over the file, and the
  file wins over built-in defaults.

### Authentication

Authentication is enabled as soon as the users table has at least one row. The
browser logs in with a username and password and receives an HttpOnly session
cookie; the same cookie authorizes the session and the realtime desktop. An
admin can list, create, reset, kick, and delete other users, and only the
superadmin can change roles.

If you put the node behind a reverse proxy, the proxy can pass an
`X-Forwarded-User` header to identify the caller as a plain user, which is
useful for existing single sign-on. The node must not be exposed directly in
that setup, because any client could otherwise spoof the header. Terminate TLS
at the proxy, since the session cookie is marked Secure. See
[docs/gateway.md](docs/gateway.md) and the ready-made compose files in
[docs/compose](docs/compose) for Caddy, nginx, and Traefik.

## Running a cluster

The node starts a named Erlang node and can join peers over a shared cookie. A
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

## Verifying a session

Freeze and resume through the API:

```sh
TOKEN=$(curl -s http://localhost:8080/route | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
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
symlinked into every session at `~/storage`. It is shared across all sessions
and both nodes, which makes it a convenient place to keep files you want to tag
from Picard. It is intentionally not part of the per-account snapshot.

## License

This project is licensed under the BSD 3-Clause License - see the
[LICENSE](LICENSE) file for details.
