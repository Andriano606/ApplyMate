# ApplyMate

## Local Development

| Service        | URL                        | Notes                        |
|----------------|----------------------------|------------------------------|
| App            | http://localhost:3000      |                              |
| MinIO API      | http://localhost:9000      | S3-compatible endpoint       |
| MinIO Console  | http://localhost:9001      | user: minioadmin / minioadmin |

## Deployment

Deployed via [Kamal](https://kamal-deploy.org/).

| Environment       | URL                                                         | Notes                          |
|-------------------|-------------------------------------------------------------|--------------------------------|
| localhost (Caddy) | https://dev.applymate.io                                    |                                |
| Staging (public)  | https://staging.beapply.xyz                                 | Via Cloudflare Tunnel, SSL     |
| Staging (local)   | http://staging.applymate.local                              | Requires `/etc/hosts` entry    |

### Staging infrastructure

| Role       | Host          | Description                                           |
|------------|---------------|-------------------------------------------------------|
| `web`      | 192.168.31.58 | Puma (Raspberry Pi 5, arm64)                          |
| `worker`   | 192.168.31.58 | Solid Queue — всі черги                               |

### Staging accessory URLs

| Accessory      | URL                                                               | Notes                          |
|----------------|-------------------------------------------------------------------|--------------------------------|
| App (public)   | [https://staging.beapply.xyz](https://staging.beapply.xyz)       | Via Cloudflare Tunnel          |
| App (local)    | [http://staging.applymate.local](http://staging.applymate.local) | Requires `/etc/hosts` entry    |
| PostgreSQL     | `192.168.31.58:5434`                                             | No web UI                      |
| MinIO S3 API   | [http://192.168.31.58:9002](http://192.168.31.58:9002)           | S3-compatible endpoint         |
| MinIO Console  | [http://192.168.31.58:9003](http://192.168.31.58:9003)           | Web UI for bucket management   |
| Elasticsearch  | [http://192.168.31.58:9201](http://192.168.31.58:9201)           | REST API                       |
| Chrome noVNC   | [http://192.168.31.58:6081/vnc.html](http://192.168.31.58:6081/vnc.html) | Browser-based VNC UI  |
| Chrome VNC     | `192.168.31.58:5901`                                             | VNC client (RealVNC/TigerVNC)  |
| Chrome CDP     | `192.168.31.58:9222`                                             | Chrome DevTools Protocol       |

### Prerequisites

Add to `/etc/hosts` on your machine (for local access):
```
192.168.31.58 staging.applymate.local
```

### Cloudflare Tunnel (staging)

Staging is publicly accessible via a named Cloudflare Tunnel — no port forwarding required.

| What               | Value                                              |
|--------------------|----------------------------------------------------|
| Domain             | `staging.beapply.xyz` (DNS managed by Cloudflare) |
| Tunnel name        | `apply-mate-staging`                               |
| Tunnel credentials | `/home/andrii/.cloudflared/19a80cfc-968d-48cc-9197-9494e6b1071a.json` on RPi |
| Config             | `/etc/cloudflared/config.yml` on RPi               |

The `cloudflared` daemon runs as a systemd service on the RPi and maintains 4 persistent connections to Cloudflare edge (Warsaw). SSL is handled automatically by Cloudflare.

```bash
# Status
ssh andrii@192.168.31.58 "sudo systemctl status cloudflared"

# Restart tunnel
ssh andrii@192.168.31.58 "sudo systemctl restart cloudflared"

# Logs
ssh andrii@192.168.31.58 "sudo journalctl -u cloudflared -f"
```

### First deploy (sets up Docker, proxy, database)

```bash
bin/kamal setup -d staging
```

Перед першим деплоєм staging потрібно також піднять аксесуари та налаштувати MinIO — дивись розділ [MinIO (staging)](#minio-staging) нижче.

### Deploy

```bash
bin/kamal deploy -d staging
```

### Деплой окремих ролей (staging)

```bash
# Тільки web або worker
bin/kamal deploy -d staging --roles=web,worker

# Деплой тільки на конкретний хост
bin/kamal deploy -d staging --hosts=192.168.31.58
```

### Useful commands

```bash
# ── Deploy ────────────────────────────────────────────────────────────────────
bin/kamal deploy -d staging                          # full deploy
bin/kamal deploy -d staging --roles=web,worker       # specific roles only
bin/kamal rollback <git-sha> -d staging              # rollback to a version
bin/kamal lock release -d staging                    # release a stuck deploy lock

# ── Logs ──────────────────────────────────────────────────────────────────────
bin/kamal app logs -d staging -f                     # web logs live (follow)
bin/kamal app logs -d staging -f --roles=worker      # worker logs live
bin/kamal app logs -d staging --lines=100            # last N lines

# ── Rails console / shell ─────────────────────────────────────────────────────
bin/kamal console -d staging                         # Rails console
bin/kamal shell -d staging                           # bash inside container
bin/kamal dbc -d staging                             # psql DB console

# ── Database ──────────────────────────────────────────────────────────────────
bin/kamal seed -d staging                            # db:seed
bin/kamal app exec --interactive --reuse "bin/rails db:seed:replant" -d staging
bin/kamal app exec --interactive --reuse "bin/rails db:drop db:create db:migrate db:seed" -d staging
```

### Аксесуари (staging)

```bash
# Статус всіх аксесуарів
bin/kamal accessory details -d staging

# Перезапуск БД (після зміни port binding)
bin/kamal accessory reboot db -d staging

# Перезапуск MinIO
bin/kamal accessory reboot minio -d staging

# Логи MinIO
bin/kamal accessory logs minio -d staging

# Перезапуск Chrome VNC
bin/kamal accessory reboot chrome_vnc -d staging

# Логи Chrome VNC
bin/kamal accessory logs chrome_vnc -d staging -f
```

### MinIO (staging)

Active Storage на staging використовує MinIO як S3-сумісне сховище (замість disk storage).

**Перший запуск:**

```bash
# 1. Піднять контейнер
bin/kamal accessory boot minio -d staging

# 2. Відкрити порти на RPi (одноразово)
ssh andrii@192.168.31.58 "sudo ufw allow from 192.168.31.0/24 to any port 9002 && sudo ufw allow from 192.168.31.0/24 to any port 9003 && sudo ufw reload"

# 3. Створити bucket через веб-консоль: http://192.168.31.58:9003
#    Логін: значення minio.access_key_id / minio.secret_access_key зі staging credentials
#    Bucket name: apply-mate-staging
```

**Доступ:**
- S3 API: `http://192.168.31.58:9002`
- Веб-консоль: `http://192.168.31.58:9003`

### Chrome VNC (staging)

Chrome з VNC-доступом для автоматизації та дебагу скрейпінгу.
Dockerfile: `docker/chrome_vnc/Dockerfile`.

Архітектура всередині контейнера:
- **Xvfb** — віртуальний дисплей
- **Fluxbox** — мінімальний window manager
- **x11vnc** — VNC-сервер (порт 5900)
- **websockify + noVNC** — веб-інтерфейс для VNC (порт 6080)
- **Chromium** — браузер з CDP на `127.0.0.1:19222`
- **nginx** — проксі на порт 9222 → 19222, переписує `Host: localhost` та `webSocketDebuggerUrl` у відповідях, щоб Ferrum міг підключитися з worker-контейнера

Застосунок підключається через `BrowserClient` → `CHROME_HOST=chrome-vnc` (мережевий аліас контейнера) → nginx → Chromium CDP.

**Перший запуск:**

```bash
# 0. Одноразово — створити multi-platform builder (якщо ще не створений)
docker buildx create --name multiarch --driver docker-container --use
# Якщо вже існує:
docker buildx use multiarch

# 1. Збудувати мульти-арх образ і запушити (amd64 + arm64 для RPi)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t andriano606/apply_mate_chrome_vnc:latest \
  --push \
  docker/chrome_vnc

# 2. Підняти контейнер
bin/kamal accessory boot chrome_vnc -d staging
```

**Доступ:**
- noVNC (веб): [http://192.168.31.58:6081/vnc.html](http://192.168.31.58:6081/vnc.html)
- VNC клієнт: `192.168.31.58:5901`
- Chrome CDP: `192.168.31.58:9222`

**Після зміни Dockerfile або entrypoint.sh:**

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t andriano606/apply_mate_chrome_vnc:latest \
  --push \
  docker/chrome_vnc

bin/kamal accessory reboot chrome_vnc -d staging
```

### Credentials

Secrets are stored in encrypted Rails credentials per environment:

```bash
# View / edit
EDITOR=nano bin/rails credentials:edit
EDITOR=nano bin/rails credentials:edit --environment staging
```

Expected structure:
```yaml
kamal:
  registry_password: your_docker_hub_access_token
  postgres_password: your_secure_db_password

secret_key_base: your_secret_key_base  # generate with: bin/rails secret

google:
  client_id: your_google_client_id
  client_secret: your_google_client_secret

# Staging only
minio:
  access_key_id: your_minio_user      # мінімум 3 символи
  secret_access_key: your_minio_pass  # мінімум 8 символів
```

> Keep `config/credentials/staging.key` in a password manager — without it the credentials cannot be decrypted.

### Running in SSL mode in development
The benefits of running in SSL mode are:
1. You run closer to what we do in production
2. You get the benefit of http2.
3. Some features only work over SSL such as using javascript to access the clipboard (copy/paste)

You need to have Caddy installed, eg with `brew install Caddy`

Put the following line in `/etc/hosts`:
```
127.0.0.1       dev.applymate.io
```

Then run Caddy:
```bash
caddy run --config config/Caddyfile.dev
```
(this is also in Procfile.dev, so it should be automatically run with `bin/dev`)

The first time you should probably run it manually, since it will then request some root privileges to install
necessary root certificates locally.

**Trust the Caddy local CA:**
```bash
caddy trust
```

**Chrome on Linux** uses its own NSS database and requires an extra step:
```bash
# Install certutil if needed
sudo apt install libnss3-tools

# Create NSS database if it doesn't exist
mkdir -p ~/.pki/nssdb && certutil -d sql:$HOME/.pki/nssdb -N --empty-password

# Add Caddy CA to Chrome's NSS store
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Caddy Local Authority" \
  -i ~/.local/share/caddy/pki/authorities/local/root.crt
```

Then fully restart Chrome (`chrome://restart`).

You can now access your local instance using https://dev.applymate.io

