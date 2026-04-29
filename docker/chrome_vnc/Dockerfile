FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    SCREEN_WIDTH=1920 \
    SCREEN_HEIGHT=1080 \
    SCREEN_DEPTH=24 \
    VNC_PASSWORD="" \
    DISPLAY=:99

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    x11vnc \
    xvfb \
    fluxbox \
    novnc \
    websockify \
    nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

EXPOSE 5900 6080 9222

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
