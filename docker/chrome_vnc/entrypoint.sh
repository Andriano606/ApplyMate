#!/bin/bash
set -e

Xvfb :99 -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" &
sleep 1
DISPLAY=:99 fluxbox &

if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -display :99 -passwd "$VNC_PASSWORD" -listen 0.0.0.0 -xkb -forever -rfbport 5900 &
else
  x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever -rfbport 5900 &
fi

websockify --web /usr/share/novnc/ 6080 localhost:5900 &

# Chrome binds CDP to 127.0.0.1 only. nginx proxies 0.0.0.0:9222 → 127.0.0.1:19222
# and rewrites the Host header to "localhost" so Chrome accepts cross-container requests.
# EXTERNAL_CHROME_HOST controls what host Ferrum uses to connect back:
#   staging: chrome-vnc:9222 (Docker network alias, default)
#   dev:     localhost:9222   (host machine port mapping)
EXTERNAL_CHROME_HOST="${EXTERNAL_CHROME_HOST:-chrome-vnc:9222}"

cat > /etc/nginx/sites-enabled/default << EOF
server {
    listen 9222;
    location /json {
        proxy_pass http://127.0.0.1:19222;
        proxy_http_version 1.1;
        proxy_set_header Host localhost;
        proxy_set_header Connection "";
        sub_filter_types application/json;
        sub_filter_once off;
        sub_filter '"ws://localhost:19222/' '"ws://${EXTERNAL_CHROME_HOST}/';
        sub_filter '"ws://localhost/' '"ws://${EXTERNAL_CHROME_HOST}/';
    }
    location / {
        proxy_pass http://127.0.0.1:19222;
        proxy_http_version 1.1;
        proxy_set_header Host localhost;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
nginx &

DISPLAY=:99 chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-setuid-sandbox \
  --remote-debugging-port=19222 \
  --start-maximized \
  about:blank

wait
