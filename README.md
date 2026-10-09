# ApplyMate

## Local Development

| Service       | URL                          | Notes                                                                              |
| ------------- | ---------------------------- | ---------------------------------------------------------------------------------- |
| App           | http://localhost:3000        |                                                                                    |
| MinIO API     | http://localhost:9000        | S3-compatible endpoint                                                             |
| MinIO Console | http://localhost:9001        | user: minioadmin / minioadmin                                                      |
| browserd      | http://localhost:9300/health | Camoufox lease daemon for `bin/dev` (`docker compose up -d browserd`)              |
| browserd-test | http://localhost:9310/health | Test-only browserd for the `:browser` specs (`docker compose up -d browserd-test`) |

browserd variables (Conductor workspaces get them from `bin/conductor/setup.rb`; with `BROWSERD_URL` set in the test
env the `:browser` specs run against the container). Development (`.env` / `.env.development.local`):

```bash
BROWSERD_URL=http://localhost:9300
BROWSERD_TOKEN=dev-browserd-token   # = the docker-compose.yml default
```

Test (`.env.test.local`): the same token and `BROWSERD_URL=http://localhost:9310`. Only `browserd-test` may reach the
docker host (where the specs serve their fixture pages); the dev `browserd` loads real job pages and reaches public
addresses only.

## Deployment

Deployed via [Kamal](https://kamal-deploy.org/).

| Environment       | URL                            | Notes                       |
| ----------------- | ------------------------------ | --------------------------- |
| localhost (Caddy) | https://dev.applymate.io       |                             |
| Staging (public)  | https://staging.beapply.xyz    | Via Cloudflare Tunnel, SSL  |
| Staging (local)   | http://staging.applymate.local | Requires `/etc/hosts` entry |

### Staging infrastructure

| Role                   | Host           | Description                                                                                                                       |
| ---------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `web`                  | 192.168.50.155 | Puma (Raspberry Pi 5, arm64)                                                                                                      |
| `worker`               | 192.168.50.155 | Solid Queue — черга default (`SQ_ROLE=general`)                                                                                   |
| `apply_worker`         | 192.168.50.155 | Solid Queue — черга apply, threads = `APPLY_SLOTS` (браузер/AI-джоби)                                                             |
| `browserd` (accessory) | 192.168.50.155 | Camoufox lease daemon, `MAX_BROWSERS = APPLY_SLOTS = 3`, 6 GB / 3 CPU; портів назовні немає (лише мережа kamal, alias `browserd`) |

### Staging accessory URLs

| Accessory     | URL                                                              | Notes                        |
| ------------- | ---------------------------------------------------------------- | ---------------------------- |
| App (public)  | [https://staging.beapply.xyz](https://staging.beapply.xyz)       | Via Cloudflare Tunnel        |
| App (local)   | [http://staging.applymate.local](http://staging.applymate.local) | Requires `/etc/hosts` entry  |
| PostgreSQL    | `192.168.50.155:5434`                                            | No web UI                    |
| MinIO S3 API  | [http://192.168.50.155:9002](http://192.168.50.155:9002)         | S3-compatible endpoint       |
| MinIO Console | [http://192.168.50.155:9003](http://192.168.50.155:9003)         | Web UI for bucket management |
| Elasticsearch | [http://192.168.50.155:9201](http://192.168.50.155:9201)         | REST API                     |

### Prerequisites

Add to `/etc/hosts` on your machine (for local access):

```
192.168.50.155 staging.applymate.local
```

### Cloudflare Tunnel (staging)

Staging is publicly accessible via a named Cloudflare Tunnel — no port forwarding required.

| What               | Value                                                                        |
| ------------------ | ---------------------------------------------------------------------------- |
| Domain             | `staging.beapply.xyz` (DNS managed by Cloudflare)                            |
| Tunnel name        | `apply-mate-staging`                                                         |
| Tunnel credentials | `/home/andrii/.cloudflared/19a80cfc-968d-48cc-9197-9494e6b1071a.json` on RPi |
| Config             | `/etc/cloudflared/config.yml` on RPi                                         |

The `cloudflared` daemon runs as a systemd service on the RPi and maintains 4 persistent connections to Cloudflare edge (Warsaw). SSL is handled automatically by Cloudflare.

```bash
# Status
ssh andrii@192.168.50.155 "sudo systemctl status cloudflared"

# Restart tunnel
ssh andrii@192.168.50.155 "sudo systemctl restart cloudflared"

# Logs
ssh andrii@192.168.50.155 "sudo journalctl -u cloudflared -f"
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
bin/kamal deploy -d staging --hosts=192.168.50.155
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
```

### MinIO (staging)

Active Storage на staging використовує MinIO як S3-сумісне сховище (замість disk storage).

**Перший запуск:**

```bash
# 1. Піднять контейнер
bin/kamal accessory boot minio -d staging

# 2. Відкрити порти на RPi (одноразово)
ssh andrii@192.168.50.155 "sudo ufw allow from 192.168.31.0/24 to any port 9002 && sudo ufw allow from 192.168.31.0/24 to any port 9003 && sudo ufw reload"

# 3. Створити bucket через веб-консоль: http://192.168.50.155:9003
#    Логін: значення minio.access_key_id / minio.secret_access_key зі staging credentials
#    Bucket name: apply-mate-staging
```

**Доступ:**

- S3 API: `http://192.168.50.155:9002`
- Веб-консоль: `http://192.168.50.155:9003`

### browserd (Camoufox)

`browserd` видає застосунку короткоживучі браузери Camoufox (Firefox з фінгерпринтом на рівні C++) — «лізи» —
по протоколу Playwright. Кожен ліз — окремий процес браузера з власним TTL (дедлайн скоупу + 60 с, не більше `LEASE_TTL_S` = 1800 с); кількість одночасних браузерів обмежена
`MAX_BROWSERS`. Браузери ходять в інтернет лише через проксі smokescreen (тільки публічні адреси) і не бачать
внутрішніх сервісів. Повний опис (API лізів, reaper, ізоляція мережі, версії): `.ai/docs/browser.md`.
Dockerfile: `docker/browserd/Dockerfile`; образ: `andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0-r2`
(тег = версії Camoufox і playwright-core + ревізія `BROWSERD_REVISION`; будь-яка зміна в `docker/browserd/` піднімає ревізію,
інакше Kamal і compose не стягнуть новий образ).

| Змінна                | Значення                                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `BROWSERD_TOKEN`      | Bearer-токен (обов'язковий, ≥ 16 символів); у dev за замовчуванням `dev-browserd-token`                                              |
| `MAX_BROWSERS`        | 1..3, ліміт одночасних браузерів (у dev = `APPLY_SLOTS`, за замовчуванням 1)                                                         |
| `LEASE_TTL_S`         | найдовше життя лізу, за замовчуванням 1800; `POST /leases` просить `ttl_s` = дедлайн скоупу + 60 с                                   |
| `HEADLESS`            | `true` / `virtual` (Xvfb) / `false`                                                                                                  |
| `BROWSERD_OS`         | ОС фінгерпринту, `windows`                                                                                                           |
| `EGRESS_ALLOW_RANGES` | лише для тестів (`browserd-test`, CI): `host.docker.internal` → /32 для fixture_site. Не задавати ні в dev `browserd`, ні на staging |

**Локально:**

```bash
docker compose up -d browserd browserd-test   # перша збірка завантажує ~1.3 ГБ Camoufox
curl -s localhost:9300/health        # {"ok":true,"leases":0,"max":1,...,"proxy_ok":true}
curl -s localhost:9310/health        # browserd-test: "max":3
curl -s -H 'Authorization: Bearer dev-browserd-token' localhost:9300/health/deep   # запуск браузера → about:blank
```

**Збірка і публікація мульти-арх образу (лише власник репозиторію):**

```bash
# Одноразово — multi-platform builder (якщо ще не створений)
docker buildx create --name multiarch --driver docker-container --use
# Якщо вже існує:
docker buildx use multiarch

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t andriano606/apply_mate_browserd:156.0.1-beta.36-pw1.63.0-r2 \
  --push \
  docker/browserd
```

**Staging (Kamal accessory `browserd`):**

```bash
bin/kamal accessory boot browserd -d staging      # перший запуск
bin/kamal accessory reboot browserd -d staging    # після зміни образу або env
bin/kamal accessory logs browserd -d staging -f
```

`config/deploy.staging.yml` задає `<% apply_slots = 3 %>` — одне значення для `APPLY_SLOTS` ролі `apply_worker` і
`MAX_BROWSERS` аксесуара. `BROWSERD_URL=http://browserd:9300` є лише в `apply_worker`.

**Токен `BROWSERD_TOKEN`** зберігається у staging credentials як `browserd.token` і потрапляє в Kamal через
`.kamal/secrets.staging` (так само, як секрети MinIO). Згенерувати й додати:

```bash
openssl rand -hex 32
EDITOR=nano bin/rails credentials:edit --environment staging   # browserd: token: <значення>
```

Ротація токена: змінити `browserd.token`, потім `bin/kamal accessory reboot browserd -d staging` і
`bin/kamal deploy -d staging --roles=apply_worker`. Деталі (CI, розміри, stop_timeout): `.ai/docs/browser.md`.

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

secret_key_base: your_secret_key_base # generate with: bin/rails secret

google:
  client_id: your_google_client_id
  client_secret: your_google_client_secret

# Staging only
minio:
  access_key_id: your_minio_user # мінімум 3 символи
  secret_access_key: your_minio_pass # мінімум 8 символів

browserd:
  token: your_browserd_token # openssl rand -hex 32 (browserd вимагає ≥ 16 символів)
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
