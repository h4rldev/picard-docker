FROM alpine:3.22 AS build

ENV ERL_ROOT=/usr/lib/erlang REBAR_PROFILE=prod

RUN apk add --no-cache erlang28 erlang28-dev git bash curl gcc musl-dev pkgconf file-dev; \
  curl -fsSL -o /usr/local/bin/rebar3 https://s3.amazonaws.com/rebar3/rebar3 \
  && chmod +x /usr/local/bin/rebar3; \
  curl -fsSL -o /tmp/just.tar.gz https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-x86_64-unknown-linux-musl.tar.gz \
  && tar -xzf /tmp/just.tar.gz -C /usr/local/bin just \
  && rm /tmp/just.tar.gz

COPY picard_rt/ /build/picard_rt/

RUN cd /build/picard_rt && DIAGNOSTIC=1 rebar3 as prod compile

FROM alpine:3.22

RUN apk add --no-cache \
    picard \
    qt5-qtwayland \
    sway \
    wayvnc \
    grim \
    foot \
    fuzzel \
    font-noto \
    xdg-utils \
    curl \
    jq \
    libcap \
    swaybg \
    erlang28 \
    file \
    ca-certificates \
    && setcap -r /usr/bin/sway

RUN adduser -D -u 1000 -s /bin/sh app

RUN set -eu; \
    URL=$(curl -fsSL https://api.github.com/repos/pkgforge-dev/Helium-Browser-AppImage-Enhanced/releases/latest | jq -r '.assets[] | select(.name | endswith(".AppImage") and contains("x86_64")) | .browser_download_url' | head -n1); \
    curl -fsSL "$URL" -o /tmp/helium.AppImage; \
    chmod +x /tmp/helium.AppImage; \
    /tmp/helium.AppImage --appimage-extract >/dev/null; \
    if [ -L squashfs-root ]; then rm -f squashfs-root; mv AppDir /opt/helium; \
    elif [ -d squashfs-root ]; then mv squashfs-root /opt/helium; \
    elif [ -d AppDir ]; then mv AppDir /opt/helium; \
    else echo "unknown extraction layout"; ls; exit 1; fi; \
    rm -f /tmp/helium.AppImage

RUN set -eu; \
    mkdir -p /usr/local/share/applications /usr/share/icons/hicolor/256x256/apps /usr/share/icons/hicolor/48x48/apps; \
    find /opt/helium -maxdepth 4 -name '*.desktop' -exec cp {} /usr/local/share/applications/ \;; \
    ICON=$(find /opt/helium -maxdepth 4 -name 'product_logo_256.png' | head -n1); \
    if [ -n "$ICON" ]; then cp "$ICON" /usr/share/icons/hicolor/256x256/apps/helium.png; cp "$ICON" /usr/share/icons/hicolor/48x48/apps/helium.png; fi

RUN printf '%s\n' \
    '#!/bin/sh' \
    'export APPDIR=/opt/helium' \
    'export LD_LIBRARY_PATH=/opt/helium/lib' \
    'export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
    'ln -sfn /opt/helium/lib /tmp/1DY 2>/dev/null || true' \
    'exec /opt/helium/lib/ld-linux-x86-64.so.2 --library-path /opt/helium/lib:/opt/helium/bin /opt/helium/bin/helium --ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"' \
    > /usr/local/bin/helium; \
    chmod +x /usr/local/bin/helium

RUN set -eu; \
    curl -fsSL -o /tmp/novnc.tar.gz https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.tar.gz; \
    mkdir -p /opt/web/novnc; \
    tar xzf /tmp/novnc.tar.gz -C /opt/web/novnc --strip-components=1; \
    rm -f /tmp/novnc.tar.gz; \
    sed -i '/encs.push(encodings.pseudoEncodingQEMUExtendedKeyEvent);/d' /opt/web/novnc/core/rfb.js

COPY --from=build /build/picard_rt/_build/prod/lib/picard_rt /opt/picard_rt/picard_rt
COPY --from=build /build/picard_rt/_build/default/lib/errm_http /opt/picard_rt/errm_http
COPY --from=build /build/picard_rt/_build/default/lib/errm_ws /opt/picard_rt/errm_ws

RUN mkdir -p /data/snapshots /data/work /run/picard

COPY image/rootfs/ /

CMD ["/opt/picard_rt/start.sh"]
