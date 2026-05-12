# Proxy::Job::FetchProxies

Пайплайн завантаження, валідації та збереження публічних проксі. Запускається через SolidQueue.

## Три фази

```ruby
def perform
  candidates = Proxy::Operation::FetchCandidates.call.model        # Phase 1
  valid      = Proxy::Operation::ValidateCandidates.call(          # Phase 2
                 candidates: candidates
               ).model
  Proxy::Operation::PersistProxies.call(proxies: valid)            # Phase 3
end
```

Фази виконуються **послідовно**. Async-паралелізм всередині Phase 1 і Phase 2.

---

## Phase 1 — `Proxy::Operation::FetchCandidates`

Завантажує публічні proxy-списки. Підтримує рекурсивний обхід: деякі списки містять посилання на інші списки (catalog URLs).

### Константи

| Константа | Значення | ENV | Роль |
|-----------|----------|-----|------|
| `FETCH_CONCURRENCY` | 50 | `FETCH_PROXIES_FETCH_CONCURRENCY` | Кількість файберів-воркерів |
| `FETCH_OPEN_TIMEOUT` | 10 с | — | Timeout підключення |
| `FETCH_READ_TIMEOUT` | 60 с | — | Timeout читання відповіді |
| `FETCH_RETRIES` | 2 | — | Повторні спроби при помилці |

### Стартові URL (6 джерел)

Два провайдери: `gfpcom/free-proxy-list` і `proxifly/free-proxy-list`, по три протоколи кожен: socks5, https, http.

### Скільки файберів

```
Async do
  FETCH_CONCURRENCY.times.map do    # 50 fibers
    Async do
      loop { url = fetch_queue.dequeue; break unless url; ... }
    end
  end.each(&:wait)
end
```

Завжди рівно **50 файберів**, незалежно від кількості URL у черзі.

### Умови завершення файбера

Єдина умова: `fetch_queue.dequeue` повернув `nil` (nil-sentinel).

Sentinels вприскуються автоматично: коли лічильник `pending` досягає нуля (всі URL оброблено), будь-який воркер що це виявив вприскує `FETCH_CONCURRENCY` (50) nil-ів у чергу. Кожен воркер отримає рівно один nil і вийде.

```ruby
pending -= 1
FETCH_CONCURRENCY.times { fetch_queue.enqueue(nil) } if pending.zero?
```

> **Важливо**: нові child-URL додаються в `pending` **до** декременту `self`, щоб `pending` ніколи не досяг нуля поки є незавершена робота.

### Розпізнавання типів рядків

Кожен рядок у файлі або catalog URL, або proxy endpoint:

```
catalog URL  → yield { type: :catalog, url: ... }  → додається в чергу для рекурсивного обходу
proxy entry  → yield { host:, port:, protocol: }   → додається в масив candidates
```

**Catalog URL** — посилання на GitHub/GitLab/Bitbucket raw-файл або будь-який URL на дефолтному порту з шляхом до `.txt`/`.csv`. Такі URL завантажуються рекурсивно.

**Proxy endpoint** розпізнається двома способами:
1. URI з явним протоколом (`socks5://1.2.3.4:1080`)
2. Рядок у форматі `host:port` (IPv4 або hostname)

### Нормалізація протоколу

| Вхід | Результат | Причина |
|------|-----------|---------|
| `https` | `http` | Проксі з `https.txt` говорить HTTP CONNECT, а не TLS |
| `socks5a` | `socks5h` | Ruby-канонічна назва |

### `infer_protocol` — з назви URL, не домену

Протокол береться з **шляху** URL (path), а не зі схеми (`https://cdn...`):

```
/socks5a/data.txt  → socks5h
/socks5/data.txt   → socks5
/https.txt         → http    ← не https!
/http.txt          → http
інше               → http
```

`include?('https')` для всього URL не використовується — кожен URL починається з `https://cdn...` і дав би false positive.

---

## Phase 2 — `Proxy::Operation::ValidateCandidates`

Перевіряє кожного кандидата реальним HTTP-запитом через проксі.

### Константи

| Константа | Значення | ENV |
|-----------|----------|-----|
| `VALIDATION_CONCURRENCY` | 5000 | `FETCH_PROXIES_VALIDATION_CONCURRENCY` |
| `VALIDATION_ATTEMPTS` | 20 | — |

### Попередня фільтрація (до Async)

```ruby
candidates
  .uniq  { |p| "#{p[:protocol]}:#{p[:host]}:#{p[:port]}" }
  .select { |p| p[:host].match?(/\A(\d{1,3}\.){3}\d{1,3}\z/) }  # тільки IPv4
  .select { |p| VALID_PROTOCOLS.include?(p[:protocol]) }
  .shuffle
```

Залишаються тільки IPv4, відомі протоколи, без дублікатів. `shuffle` рівномірно розподіляє навантаження між джерелами.

### Скільки файберів

```
VALIDATION_CONCURRENCY.times { queue.enqueue(nil) }   # 5000 nil-sentinels, заздалегідь

Async do
  VALIDATION_CONCURRENCY.times.map do |idx|            # 5000 fibers
    Async do
      loop { candidate = queue.dequeue; break unless candidate; ... }
    end
  end.each(&:wait)
end
```

Рівно **5000 файберів** (за замовчуванням). Sentinels вже в черзі до старту файберів — при порожній черзі кандидатів усі файбери виходять миттєво.

### Умови завершення файбера

Єдина умова: `queue.dequeue` повернув `nil` (sentinel).

### Логіка валідації одного кандидата

```ruby
def valid_proxy?(candidate, source_uris)
  unconfirmed = source_uris.map(&:to_s)      # всі джерела потрібно підтвердити

  VALIDATION_ATTEMPTS.times do |i|
    sleep(0) if i > 0                         # yield scheduler між спробами
    url = unconfirmed.sample                  # довільне підтверджене джерело

    if reachable?(client, url)
      unconfirmed.delete(url)
      return true if unconfirmed.empty?       # всі джерела підтверджено
      sleep(60)                               # антиratelimit між успішними джерелами
    end
  end

  false
end
```

| Ситуація | Результат |
|----------|-----------|
| Всі джерела підтверджені | `true` |
| 20 спроб — хоча б одне джерело не підтверджено | `false` |
| `DeadProxyError` при будь-якому запиті | `false` (rescue в `reachable?`) |

**Критерій досяжності:** статус 200..399 (`(200..399).cover?(response.status)`). 3xx-редирект = проксі доступний.

`sleep(0)` між спробами — це `Kernel.sleep` в Async-фібері, тобто yield планувальнику: інші 4999 файберів отримують шанс виконатися.

`sleep(60)` після успішного джерела — захист від rate-limit: між двома реальними HTTP-запитами через той самий проксі чекаємо хвилину.

### Налаштування VALIDATION_CONCURRENCY

Обмежуючі фактори (не CPU):
- **File descriptors** — кожен файбер тримає 1–2 FD під час пробу. Docker default (`1024`) надто малий. Рішення: `ulimit: ["nofile=65536:65536"]` в `deploy.yml`.
- **RAM** — файбери з `sleep(60)` тримають стек живим хвилинами. За замовчуванням 5000 — прийнятний рівень.
- **Мережева пропускність** — реальна стеля. Ceiling ≈ `CONCURRENCY / 30` проб/с (таймаут AsyncHttp = 30 с).

```bash
FETCH_PROXIES_VALIDATION_CONCURRENCY=500 bin/rails runner "Proxy::Job::FetchProxies.perform_now"
```

---

## Phase 3 — `Proxy::Operation::PersistProxies`

```ruby
records = proxies
  .uniq { |p| [p[:host], p[:port]] }     # дедуп по host+port (без протоколу)
  .map  { |p| p.merge(fail_count: 0, failed_at: nil, created_at: now, updated_at: now) }

Proxy.upsert_all(records, unique_by: %i[host port], update_only: %i[fail_count failed_at])
```

- **Дедуп по `[host, port]`** — два записи з різним протоколом але одним `host:port` → один рядок у БД.
- **`update_only: [fail_count, failed_at]`** — при апсерті існуючого проксі `fail_count` скидається в 0. Це "прощення" проксі що ненадовго виходив з ладу і тепер знову пройшов валідацію.
- Повертає кількість збережених рядків через `self.model`.
- При `proxies.empty?` → ранній вихід, нічого не пишеться в БД.

---

## Спільні структури даних

| Структура | Де | Тип | Чому |
|-----------|-----|-----|------|
| `fetch_queue` | FetchCandidates | `Async::Queue` | Блокуючий dequeue — файбер чекає без `sleep` |
| `visited` | FetchCandidates | `Set` | Дедуп URL між файберами |
| `proxies` | FetchCandidates | `Array` | Файбери однопотокові — гонок немає |
| `pending` | FetchCandidates | `Integer` | Лічильник незавершених URL |
| `queue` | ValidateCandidates | `Async::Queue` | Sentinel-drain pattern |
| `valid` | ValidateCandidates | `Array` | Однопотоковий запис |
| `tested` | ValidateCandidates | `Integer` | Лічильник для логування прогресу |
