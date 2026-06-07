# Proxy::Operation::FetchProxies

Пайплайн завантаження та збереження публічних проксі. Запускається через SolidQueue
(`Proxy::Job::FetchProxies`, щодня о 0:00 — див. `config/recurring.yml`).

## Дві фази, один потік

`Proxy::Job::FetchProxies` — тонка обгортка, що викликає операцію:

```ruby
class Proxy::Job::FetchProxies < ApplicationJob
  def perform
    Proxy::Operation::FetchProxies.call
  end
end
```

Уся оркестрація — в `Proxy::Operation::FetchProxies`:

```ruby
def perform!(**)
  candidates = Proxy::Operation::FetchCandidates.call.model   # Phase 1
  persisted  = Proxy::Operation::PersistProxies.call(         # Phase 2
                 proxies: candidates
               ).model
  self.model = persisted
end
```

- **Без валідації.** Зберігаємо всіх кандидатів, яких завантажили — реальним запитом їх ніхто не перевіряє.
- **Без шардів.** Уся робота — в одному виконанні джоби (один потік). Жодних `ValidateShard`, кешу чи `FETCH_PROXIES_SHARD_COUNT`.

---

## Phase 1 — `Proxy::Operation::FetchCandidates`

Завантажує публічні proxy-списки. Підтримує рекурсивний обхід: деякі списки містять посилання на інші списки (catalog URLs). Завантаження паралелиться через Async-файбери (в межах одного потоку).

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

## Phase 2 — `Proxy::Operation::PersistProxies`

```ruby
records = proxies
  .uniq { |p| [p[:host], p[:port], p[:protocol]] }     # дедуп по host+port+protocol
  .map  { |p| p.merge(created_at: now, updated_at: now) }

Proxy.insert_all(records, unique_by: %i[host port protocol])
```

- **Дедуп по `[host, port, protocol]`** — той самий `host:port` з різними протоколами = різні рядки.
- **`insert_all` (ON CONFLICT DO NOTHING)** — наявні проксі зберігають свій `created_at` (він керує сортуванням `:by_reliability`) і `updated_at`; вставляються лише нові рядки.
- Повертає кількість збережених рядків через `self.model`.
- При `proxies.empty?` → ранній вихід, нічого не пишеться в БД.

---

## Спільні структури даних (FetchCandidates)

| Структура | Тип | Чому |
|-----------|-----|------|
| `fetch_queue` | `Async::Queue` | Блокуючий dequeue — файбер чекає без `sleep` |
| `visited` | `Set` | Дедуп URL між файберами |
| `proxies` | `Array` | Файбери однопотокові — гонок немає |
| `pending` | `Integer` | Лічильник незавершених URL |
