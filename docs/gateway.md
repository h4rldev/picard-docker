# Running behind a reverse proxy

The node trusts the `X-Forwarded-User` header on protected routes (`/route`, `/vnc`,
`/sleep`, `/alive`, `/users`) when there is no valid `session` JWT. It maps that header
to a plain `user` account (no role, no admin endpoints).

Two rules:

1. **Never expose the node directly.** Any client that can reach port 8080 can send
   `X-Forwarded-User` themselves, or — if no users exist — land on the `generic`
   account. Bind the node to a private network and let only the proxy reach it.
2. **Terminate TLS at the proxy.** The `session` cookie is `Secure`, so it is only sent
   over HTTPS.

The app's own login (superadmin) still works through the proxy; the JWT cookie takes
precedence over `X-Forwarded-User`, so use it when you need admin.

## Docker Compose (node, no published port)

```yaml
services:
  picard:
    image: picard-node:test
    stop_grace_period: 60s
    volumes: [picard-data:/data, storage:/storage]
    environment:
      - PICARD_JWT_SECRET=${PICARD_JWT_SECRET}
    networks: [picard]
  gateway:
    image: caddy:2
    ports: ["443:443", "80:80"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    networks: [picard]
volumes: {picard-data: {}, caddy-data: {}, storage: {}}
networks: {picard: {}}
```

## Caddy (`Caddyfile`)

```caddy
picard.example.com {
    tls admin@example.com
    basic_auth {
        # generate: caddy hash-password
        alice $2a$14$REPLACE_WITH_HASH
    }
    reverse_proxy picard:8080 {
        # overwrites any client-supplied header with the authenticated name
        header_up X-Forwarded-User {http.auth.user.id}
    }
}
```

Caddy proxies WebSocket upgrades automatically; `{http.auth.user.id}` is the basic-auth
username.

## nginx

```nginx
server {
    listen 443 ssl;
    server_name picard.example.com;
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    auth_basic "Picard";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://picard:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       $host;
        proxy_set_header X-Forwarded-User $remote_user;   # overwrites client value
    }
}
```

The `Upgrade`/`Connection` headers are required for `/vnc` (the noVNC WebSocket).

## Traefik

Traefik's `basicauth` middleware does **not** forward the username, so a per-user
`X-Forwarded-User` needs `forwardAuth`. For a single shared identity, set it directly:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.picard.rule=Host(`picard.example.com`)
  - traefik.http.routers.picard.tls.certresolver=le
  - traefik.http.routers.picard.middlewares=picard-auth,picard-user
  - traefik.http.middlewares.picard-auth.basicauth.users=alice:$$apr1$$REPLACE
  - traefik.http.middlewares.picard-user.headers.customrequestheaders.X-Forwarded-User=alice
  - traefik.http.services.picard.loadbalancer.server.port=8080
```

Traefik handles WebSocket upgrades automatically.