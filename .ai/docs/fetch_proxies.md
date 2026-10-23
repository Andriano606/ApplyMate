# Proxy::Operation::FetchProxies

Пайплайн завантаження та збереження публічних проксі. Запускається через SolidQueue
(`Proxy::Job::FetchProxies`, щодня о 0:00 — див. `config/recurring.yml`).

> **Чому все обмежено.** До жовтня 2026 збір складав усі ~1,79 млн рядків трьох gfpcom-дампів
> в один масив і писав їх одним `insert_all`. На Raspberry Pi 5 (без swap) це щоночі з'їдало
> всю пам'ять і вішало весь хост разом з іншими сервісами. Кожен ліміт нижче — частина
> цього фіксу; не знімайте їх, не прочитавши цей розділ.

## Три кроки, один потік

`Proxy::Job::FetchProxies` — тонка обгортка з `limits_concurrency to: 1, key: 'proxy_fetch', duration: 1.hour`
(ручний `perform_later` не перетнеться з нічним запуском).

Уся оркестрація — в `Proxy::Operation::FetchProxies`:

```ruby
def perform!(**)
  inserted = 0
  persist  = ->(batch) { inserted += Proxy::Operation::PersistProxies.call(proxies: batch).model }

  candidates = Proxy::Operation::FetchCandidates.call(on_batch: persist).model             # 1 + 2
  pruned     = Proxy::Operation::PruneProxies.call.model                                    # 3
  ...
  self.model = inserted
end
```

- **Спершу fetch, потім prune.** Нічна партія вже збережена, коли стартує чистка, тож збій prune
  лише валить джобу (видно в логах), а не скасовує fetch. Щойно вставлені рядки набагато молодші
  за `PRUNE_AFTER` — prune їх не чіпає.

- **Без валідації.** Кандидатів реальним запитом ніхто не перевіряє — це робить `Proxy::Job::Validate`.
- **Потоково.** `FetchCandidates` не повертає масив: він віддає кандидатів у `on_batch` слайсами
  по `BATCH_SIZE` (5 000) прямо під час парсингу. Модель — кількість унікальних кандидатів.
- **Модель `FetchProxies`** — кількість *реально вставлених* рядків (конфлікти не рахуються).

---

## 3 — `Proxy::Operation::PruneProxies`

Видаляє проксі, які **не працюють для жодного source** і були вставлені раніше, ніж `PRUNE_AFTER` (3 дні) тому:

- ще не перевірені — `Validate` бере найновіші першими, тож старі untested інакше чекали б вічно;
- перевірені, але скрізь падають (`success_count = 0` у всіх `proxy_source_stats`).

Проксі з `success_count > 0` хоча б для одного source лишаються. Видалення — батчами по 5 000
(`in_batches` по PK + `NOT EXISTS` по `index_proxy_source_stats_on_proxy_id`; спершу їхні
`proxy_source_stats`, потім самі проксі, в одній транзакції).

**Вихід зі стану «мертвий».** Видалений проксі, що досі є в публічних списках, наступний fetch вставить
знову зі свіжим `created_at` — і `Validate` перевірить його ще раз.

**Конкуренція з `Validate`.** Кожен батч у своїй транзакції повторно вибирає id під
`FOR UPDATE SKIP LOCKED` з тією ж умовою `NOT_WORKING`:

- insert статистики від `Validate` тримає KEY SHARE на рядку проксі → prune цей проксі пропускає;
- успіх, закомічений після читання батча, видно в повторній перевірці → проксі лишається;
- insert від `Validate`, що прийшов *після* блокування prune, чекає коміту й падає на FK — цей один
  запуск `Validate` втрачає результати, наступний (через 5 хв) працює нормально.

**Перший запуск** на таблиці з ~1,7 млн рядків видаляє ~1,5 млн рядків (на dev-машині ~85 с,
на Pi — кілька хвилин). Далі таблиця тримається на рівні ≈ 3 нічні партії + робочі проксі.

---

## 1 — `Proxy::Operation::FetchCandidates`

Завантажує публічні proxy-списки через Async-файбери (в межах одного потоку): `Async::Barrier`
+ `Async::Semaphore(FETCH_CONCURRENCY)`.

### Константи

| Константа | Значення | ENV | Роль |
|-----------|----------|-----|------|
| `FETCH_CONCURRENCY` | 6 | `FETCH_PROXIES_FETCH_CONCURRENCY` | Скільки списків качаються/парсяться одночасно. Кожен файбер тримає все тіло списку (~15 МБ у gfpcom), тож це ще й межа пам'яті |
| `MAX_CANDIDATES` | 200 000 | `FETCH_PROXIES_MAX_CANDIDATES` | Жорсткий ліміт унікальних кандидатів за запуск |
| `MAX_PER_LIST` | 50 000 | `FETCH_PROXIES_MAX_PER_LIST` | ~скільки кандидатів дає один список (випадкова вибірка) |
| `MAX_DEPTH` | 1 | `FETCH_PROXIES_MAX_DEPTH` | Скільки рівнів catalog-посилань обходимо |
| `MAX_URLS` | 50 | `FETCH_PROXIES_MAX_URLS` | Скільки списків качаємо всього (з коренями) |
| `BATCH_SIZE` | 5 000 | — | Розмір слайсу для `on_batch` |
| `YIELD_EVERY_LINES` | 10 000 | — | Як часто парсинг віддає реактор іншим файберам |
| `FETCH_OPEN_TIMEOUT` | 10 с | — | Timeout підключення |
| `FETCH_READ_TIMEOUT` | 60 с | — | Timeout читання відповіді |
| `FETCH_RETRIES` | 2 | — | Повторні спроби при помилці |

Ліміти — це також keyword-параметри `perform!` (`max_candidates:`, `max_per_list:`, `max_depth:`,
`max_urls:`, `urls:`) з константами як дефолтами.

200 000 узгоджено з `Validate`: ~2000 проксі кожні 5 хв ≈ 576k на добу, тож нічна партія
повністю перевіряється за день.

### Стартові URL (6 джерел)

Два провайдери: `gfpcom/free-proxy-list` (wiki `lists/*.txt`) і `proxifly/free-proxy-list`, по три
протоколи кожен: socks5, https, http. Станом на жовтень 2026 це ~560–600k рядків на кожен gfpcom-список
і 1–76k на proxifly; **catalog-посилань у них немає** — увесь обсяг дають самі дампи.

### Вибірка зі списку (Бернуллі)

```ruby
sample = [ max_per_list.fdiv(body.count("\n") + 1), 1.0 ].min
...
elsif rand < sample
  add(entry)
```

Кожен рядок береться з імовірністю `p = max_per_list / рядків`. Не «перші N»: gfpcom-дампи
відсортовані за IP, і «перші N» щоночі давали б ті самі `1.x–13.x`. Вибірка потокова — пам'ять
не залежить від розміру списку.

### Дедуп

`@seen` — `Set` рядків `"protocol://host:port"` усіх кандидатів, уже відданих у цьому запуску.
Окремого `uniq` по масиву немає. Розмір `@seen` ≤ `max_candidates`.

### Запис (`flush`)

- Буфер свопається без yield (`batch = @buffer; @buffer = []`) перед записом — кандидати, яких
  інші файбери парсять тим часом, падають у новий буфер.
- `on_batch` викликається під `Async::Semaphore.new(1)` в `connection_pool.with_connection`:
  під `isolation_level = :fiber` кожен файбер у запиті тримає власне з'єднання, а так їх
  лише одне додаткове.
- Якщо запис падає, батч повертається в буфер; фінальний `flush` у `ensure` після
  `@barrier.wait` пробує ще раз, потім помилка летить нагору.

### Умови завершення

- `@barrier.wait` повертається, коли завершився кожен запланований список (catalog-діти,
  заплановані під час очікування, теж входять у barrier).
- Список не качається і рядки не парсяться далі, щойно `full?` (`@seen.size >= max_candidates`).
- Catalog-рекурсія обмежена `max_depth` і `max_urls` (`@visited`) — набір URL скінченний.
- Помилка запису в одному файбері → `@barrier.wait` її перекидає → `ensure` скасовує решту
  (`@barrier.cancel`) і робить фінальний `flush`.

> `schedule` не чекає слоту семафора (`@barrier.async { @semaphore.acquire { ... } }`):
> список, що планує catalog-дітей, тримаючи слот, інакше заблокувався б, щойно так зробили б усі слоти.

### Розпізнавання типів рядків

Кожен рядок у файлі або catalog URL, або proxy endpoint:

```
catalog URL  → yield { type: :catalog, url: ... }  → schedule(url, depth: depth + 1), якщо depth < max_depth
proxy entry  → yield { host:, port:, protocol: }   → add(entry) з імовірністю sample
```

**Catalog URL** — посилання на GitHub/GitLab/Bitbucket raw-файл або будь-який URL на дефолтному порту з шляхом до `.txt`/`.csv`.

**Proxy endpoint** розпізнається двома способами:
1. URI з явним протоколом (`socks5://1.2.3.4:1080`)
2. Рядок у форматі `host:port` (IPv4 або hostname) — через `String#match`, а не `match?`
   (`match?` не заповнює captures; до жовтня 2026 через це рядки `host:port` мовчки відкидались)

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

## 2 — `Proxy::Operation::PersistProxies`

```ruby
proxies.each_slice(BATCH_SIZE).sum do |slice|                     # BATCH_SIZE = 5_000
  records = slice.map { |p| p.slice(:host, :port, :protocol).merge(created_at: now, updated_at: now) }
  Proxy.insert_all(records, unique_by: %i[host port protocol]).length
end
```

- **`insert_all` (ON CONFLICT DO NOTHING)** — наявні проксі зберігають свій `created_at` (від нього
  залежать сортування в `Validate` і cutoff у `PruneProxies`) і `updated_at`; вставляються лише нові рядки.
  Дублікати в одному слайсі теж безпечні — другий просто конфліктує з першим.
- **Слайси** — навіть якщо викликати з великим масивом, жоден `INSERT` не більший за 5 000 рядків.
- Модель — кількість реально вставлених рядків (`RETURNING id` повертає лише вставлені).
- Порожній вхід → 0, без запитів.

---

## Інфраструктура (staging)

`config/deploy.staging.yml`: `memory: "3g"` для ролі `worker`, `memory: "2g"` для accessory `db`.
Якщо щось знову розростеться, OOM-killer вб'є контейнер, а не заморозить хост
(на Pi немає swap, поруч живуть taxmate і VM Home Assistant). Ліміт для `db` застосовується лише після
`bin/kamal accessory reboot db -d staging`.

## Перевірка на staging

```bash
bin/kamal app exec -d staging --roles=worker "bin/rails runner 'Proxy::Job::FetchProxies.perform_now'"
# паралельно на хості:
docker stats
```

Очікування: worker і Postgres — у межах кількох сотень МБ, у лозі `Performed Proxy::Job::FetchProxies … in`
через кілька хвилин (на dev-машині сам fetch займає ~25 с, пік RSS процесу ~290 МБ).
