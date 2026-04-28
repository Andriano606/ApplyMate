# ApplyMate

## Local Development

| Service        | URL                        | Notes                        |
|----------------|----------------------------|------------------------------|
| App            | http://localhost:3000      |                              |
| MinIO API      | http://localhost:9000      | S3-compatible endpoint       |
| MinIO Console  | http://localhost:9001      | user: minioadmin / minioadmin |

## Deployment

Deployed via [Kamal](https://kamal-deploy.org/).

| Environment       | URL                                                 | Port |
|-------------------|-----------------------------------------------------|------|
| localhost (Caddy) | https://dev.applymate.io                            | 443  |
| Production        | http://applymate.local                              | 80   |
| Staging           | http://staging.applymate.local                      | 80   |
| Staging           | https://gauge-unpredatory-unnormally.ngrok-free.dev | 443  |

### Staging infrastructure

| Role            | Host             | Description                                           |
|-----------------|------------------|-------------------------------------------------------|
| `web`           | 192.168.31.58    | Puma (Raspberry Pi 5, arm64)                          |
| `worker`        | 192.168.31.58    | Solid Queue — всі черги, fallback (повільний polling) |
| `render_worker` | 192.168.50.37    | Solid Queue — `heavy_processing` + `default` (PC, x86_64, швидкий polling) |
| PostgreSQL      | 192.168.31.58:5433 | Аксесуар Kamal                                      |
| MinIO           | 192.168.31.58:9000 | S3-сумісне сховище (Active Storage)                 |

### Prerequisites

Add to `/etc/hosts` on your machine (for local access):
```
192.168.31.58 applymate.local staging.applymate.local
```

### First deploy (sets up Docker, proxy, database)

```bash
bin/kamal setup -d staging
bin/kamal setup -d production
```

Перед першим деплоєм staging потрібно також піднять аксесуари та налаштувати MinIO — дивись розділ [MinIO (staging)](#minio-staging) нижче.

### Deploy

Use the deploy scripts — they automatically tag the image with the environment prefix
so staging and production images are distinguishable on Docker Hub:

```bash
bin/deploy-staging      # → andriano606/apply_mate:staging-<git-sha>
bin/deploy-production   # → andriano606/apply_mate:production-<git-sha>
```

### Деплой окремих ролей (staging)

```bash
# Тільки web + основний worker (коли PC вимкнений)
bin/kamal deploy -d staging --roles=web,worker

# Тільки render_worker на PC (після увімкнення PC)
bin/kamal deploy -d staging --roles=render_worker

# Перезапуск render_worker без нового білду
bin/kamal app boot -d staging --roles=render_worker

# Деплой тільки на конкретний хост
bin/kamal deploy -d staging --hosts=192.168.31.58
```

### Useful commands

```bash
# Logs (всі ролі)
bin/kamal logs -d staging
bin/kamal logs -d production

# Logs конкретної ролі
bin/kamal app logs -d staging --roles=worker
bin/kamal app logs -d staging --roles=render_worker

# Rails console
bin/kamal console -d staging
bin/kamal console -d production

# App shell
bin/kamal shell -d staging
bin/kamal shell -d production

# DB console
bin/kamal dbc -d staging
bin/kamal dbc -d production

# Seed database
bin/kamal seed -d staging
bin/kamal seed -d production

# Rollback to a previous version
bin/kamal rollback <git-sha> -d staging
bin/kamal rollback <git-sha> -d production

# Truncate and re-seed database (replant)
bin/kamal app exec --interactive --reuse "bin/rails db:seed:replant" -d staging
bin/kamal app exec --interactive --reuse "bin/rails db:seed:replant" -d production

# Повний скид БД в нуль (drop → create → migrate → seed)
bin/kamal app exec --interactive --reuse "bin/rails db:drop db:create db:migrate db:seed" -d staging

# Зняти завислий deploy lock
bin/kamal lock release -d staging
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
Це дозволяє `render_worker` на PC читати/записувати файли незалежно від RPi.

**Перший запуск:**

```bash
# 1. Піднять контейнер
bin/kamal accessory boot minio -d staging

# 2. Відкрити порти на RPi (одноразово)
ssh andrii@192.168.31.58 "sudo ufw allow from 192.168.50.0/24 to any port 9000 && sudo ufw allow from 192.168.31.0/24 to any port 9001 && sudo ufw reload"

# 3. Створити bucket через веб-консоль: http://192.168.31.58:9001
#    Логін: значення minio.access_key_id / minio.secret_access_key зі staging credentials
#    Bucket name: apply-mate-staging
```

**Доступ:**
- S3 API: `http://192.168.31.58:9000`
- Веб-консоль: `http://192.168.31.58:9001`

> Файли роздаються через Rails (proxy mode), тому завантаження працюють і через ngrok.

### Credentials

Secrets are stored in encrypted Rails credentials per environment:

```bash
# View / edit
EDITOR=nano bin/rails credentials:edit
EDITOR=nano bin/rails credentials:edit --environment staging
EDITOR=nano bin/rails credentials:edit --environment production
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

> Keep `config/credentials/staging.key` and `config/credentials/production.key` in a password manager — without them the credentials cannot be decrypted.

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

---

## ⚠️ Тимчасове рішення: ngrok

Staging наразі доступний через ngrok (`gauge-unpredatory-unnormally.ngrok-free.dev`) як тимчасове рішення для отримання HTTPS і публічного домену.

**Після купівлі реального домену потрібно:**

1. Revert коміт `feature/ngrok-staging-https` або вручну:
    - Прибрати ngrok домен з `config/deploy.staging.yml` → `proxy.hosts`
    - Оновити `proxy.hosts` на реальний домен із `ssl: true`

2. Видалити ngrok з RPI:
   ```bash
   ssh andrii@192.168.31.58
   sudo systemctl stop ngrok
   sudo systemctl disable ngrok
   sudo ngrok service uninstall
   sudo apt remove ngrok -y
   rm ~/.config/ngrok/ngrok.yml
   ```

3. Оновити Google Cloud Console → authorized redirect URIs на новий домен.

4. Задеплоїти staging з новим доменом:
   ```bash
   bin/deploy-staging
   ```
