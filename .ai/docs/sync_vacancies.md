# Vacancy::Operation::SyncVacancies

Операція повної синхронізації вакансій із зовнішніх джерел. Запускається через `Vacancy::Job::SyncVacancies` (SolidQueue).

> **Один запуск за раз.** Джоба має `limits_concurrency to: 1, duration: 12.hours` — ліміт використань проксі (`MAX_USES` / `USE_INTERVAL`, див. нижче) живе в RAM одного запуску, а сесії ProxyMate в кожного запуску свої: другий паралельний запуск отримав би ті самі проксі у своїх сесіях і використовував би їх понад ліміт першого.

> **Дані живуть у RAM.** Пул проксі БД не чіпає зовсім (проксі — з ProxyMate). БД чіпають лише вакансії: RAM-буфер досяг `VACANCY_BUFFER_LIMIT` → bulk-flush (`VacancyBuffer#maybe_flush`), фінальний flush у кінці джерела, курсор і bulk-UPDATE Phase 2, лічильники/чистка. Увесь доступ до БД іде через `DbGateway` → щонайбільше `DB_CONCURRENCY` фізичних з'єднань на весь джоб.

## Константи

| Константа | Значення | Роль |
|-----------|----------|------|
| `WORKERS_PER_SOURCE` | 32 | Файберів-воркерів на джерело у Phase 1 (лістинг) |
| `DESCRIPTION_WORKERS` | 32 | Файберів-воркерів на джерело у Phase 2 (описи). Два джерела одночасно × 32 = `ImpersonateHttp::MAX_PROCESSES` (64 curl-процеси на Pi); більше файберів лише чекали б слот curl, а темп і так задає пул (проксі — раз на `USE_INTERVAL`) |
| `MAX_PAGES` | 2000 | Верхня межа черги сторінок |
| `LAST_PAGE_CONFIRMATIONS` | 50 | Скільки разів сторінка має повернути порожній результат, щоб вважатись останньою |
| `VACANCY_FETCH_BATCH` | 1000 | Розмір пачки вакансій, що тягнуться з БД у Phase 2 |
| `VACANCY_BUFFER_LIMIT` | 1000 | Скільки скрапнутих вакансій тримається в RAM перед bulk-flush у БД (Phase 1) |
| `DB_CONCURRENCY` | 5 | Макс. одночасних DB-операцій (== фізичних конектів) у `DbGateway` |
| `MAX_VACANCY_RETRIES` | 20 | Скільки порожніх відповідей опису до відмови від вакансії (Phase 2) |
| `HTTP_REQUEST_TIMEOUT` | 25 | Загальний таймаут запиту (curl `--max-time`), з'єднання з проксі входить у нього |
| `HTTP_CONNECT_TIMEOUT` | 10 | Таймаут з'єднання з проксі (curl `--connect-timeout`; 3 с вбивав повільні, але живі проксі). Входить у `HTTP_REQUEST_TIMEOUT` (curl `--max-time`) |

`ProxyPool` (вкладений клас):

| Константа | Значення | Роль |
|-----------|----------|------|
| `MAX_USES` | 10 | Скільки запитів (невдалі теж) один проксі робить на сайт за **раунд**; далі — «на пенсії» до наступного раунду |
| `USE_INTERVAL` | 60 | Мінімум секунд між двома використаннями одного проксі на сайті (від кінця попереднього) |
| `MIN_READY` | 10 | Скільки проксі мають бути готові **зараз**, інакше `acquire` запускає refill |
| `SEED_BATCH` | 1000 (`ProxyMate::MAX_LIMIT`) | Скільки проксі просимо в ProxyMate на старті |
| `REFILL_BATCH` | 300 | Скільки проксі просимо за один refill |
| `ORDER` | `'stable'` | Порядок ProxyMate: найвищий stability score першим |
| `REFILL_INTERVAL` | 5 | Мінімум секунд між refill-ами (стартове значення backoff) |
| `MAX_REFILL_INTERVAL` | 60 | Стеля backoff, поки ProxyMate не дає нового / падає |
| `MAX_REFILL_FAILURES` | 3 | Скільки refill-ів поспіль, що нічого не додали (помилки теж), поки пул **порожній**, — і раунд закінчується (раніше — при `remaining: 0`) |
| `MAX_EMPTY_ROUNDS` | 2 | Скільки раундів **поспіль** без жодного успішного використання — і пул вичерпано (`NoProxiesError`) |

---

## In-memory пул проксі (`ProxyPool`) і ProxyMate

Проксі бере окремий сервіс **ProxyMate** (`ApplyMate::Client::ProxyMate`, JSON API, конфіг читається один раз на клієнт: спершу збережений `ProxyMateSetting` (singleton-рядок, `api_key` шифрується Active Record encryption; адмін вставляє URL і ключ на сторінці `/admin/proxy_mate`, де під формою видно стан з'єднання — `GET /api/v1/sites` → кількість робочих проксі по сайтах), інакше ENV `PROXY_MATE_URL` / `PROXY_MATE_API_KEY` (для dev); credentials більше не читаються). ProxyMate сам збирає проксі, перевіряє кожен на кожному сайті через curl-impersonate, рахує stability і добуває Cloudflare `cf_clearance`. **ApplyMate не має жодного збереженого стану проксі**: ні таблиць, ні валідації — пул живе лише в RAM одного запуску. ProxyMate нічого не повідомляється: проксі, що не впорався, просто виходить з пулу до наступного раунду.

### Старт запуску: meta

`perform!` до будь-якого пулу (поза реактором) робить `GET /api/v1/meta` → `curl_impersonate.release` / `targets`. Якщо release == `ImpersonateHttp::RELEASE` (пін із `bin/install-curl-impersonate`) — `impersonate_targets` = targets ProxyMate; інакше `vacancy_sync_curl_impersonate_mismatch` і лише `[DEFAULT_IMPERSONATE]` (`chrome146`). Meta не вдалась → `vacancy_sync_proxy_mate_lookup_failed lookup: meta`, теж лише `chrome146`; синк це не зупиняє.

### Запит до ProxyMate

Один `ProxyPool` на джерело (`@pools[source.id]`), спільний для обох фаз цього джерела. Запит формують методи класів, а не рядки у воркері:

```ruby
site:                scraper_class.proxy_site                    # 'djinni' / 'dou'
protocols:           client_class.supported_proxy_protocols      # http socks4 socks4a socks5 socks5h
cloudflare:          client_class.supports_cloudflare_clearance? ? 'any' : 'without'   # ImpersonateHttp → any
impersonate_targets: (лише якщо supports_cloudflare_clearance?) див. вище
session_id:          "applymate-#{session_id}-#{source.id}"      # ProxyApi::Session::ID_FORMAT /\A[\w.:-]{1,100}\z/
order:               'stable'
fields:              'minimal'                                    # додає сам клієнт
```

(`client_class = scraper_class.http_client_class` — для всіх джерел `ImpersonateHttp`.) Завжди `POST /api/v1/sites/:slug/proxies/batch`. **Сесія** (`proxy_session`, одна на запуск і джерело): у межах сесії ProxyMate ніколи не дає той самий проксі вдруге — повтори дає лише сам пул, у наступному раунді. Відповідь — `Batch(proxies, available, remaining)`; `remaining` = скільки ще дозволяють фільтри й сесія після цієї пачки.

Записи пулу — `ApplyMate::Client::ProxyMate::Proxy` (`Data`: `id`, `url`, `protocol`, `clearance`), де `clearance` — `Clearance(cookie, user_agent, impersonate)` або `nil`. Воркер передає `clearance` у клієнт (`build_scraper`): `ImpersonateHttp` тоді бере `--impersonate` цього токена, його `User-Agent` і дописує cookie.

### Seed

`seed_pool` → `ProxyPool#seed!` (поза реактором, до `Async`): `SEED_BATCH` проксі. Помилка ProxyMate (`ConfigurationError` — не налаштовано, `RequestError` — недоступний/таймаут/не-JSON/нема `remaining`, `ResponseError` — 401/404/422) ловиться тут: подія `vacancy_sync_proxy_pool_ready` з `level: error` і `error_class`/`error`, джерело пропускається. Порожня відповідь → `alive: 0`, `level: warn`, теж пропуск. Усі пропущені → `NoProxiesError` з `perform!` → `vacancy_sync_finished result: failed`. Це не crash loop: джоба не має `retry_on`, наступна спроба — за розкладом.

### Ротація і ліміт використань

Стан: `@by_id` (живі записи — вільні й зайняті), `@idle` (вільні, відсортовані за `available_at`, вставка `bsearch` — серед рівних `available_at` новий стає після наявних), `@known` (усі проксі, які запуск мав, — для раундів), `@uses` (на id проксі, **за раунд**), `@last_used_at` (на id, **за весь запуск**).

- `acquire` — перший з `@idle`, якщо його `available_at <= now`, інакше `nil` (воркер `sleep(0.2)` і ретраїть). O(1) + O(log n) на `ready_count`.
- `release(proxy)` — одне використання закінчилось: `uses += 1`; на `MAX_USES` — проксі **на пенсії** до наступного раунду (виходить з пулу, `retired_proxies`); інакше `available_at = кінець використання + USE_INTERVAL`. Без `ok:` — **успішне** використання раунду (сторінка, порожня відповідь, опис); `release(proxy, ok: false)` — ні: його кличуть гілки `rescue StandardError` і `BinaryError` воркерів і гілка лістингу «порожньо нижче вже зіскрейпленої сторінки» (сторінка лише повертається в чергу без ліміту — інакше сторінка, що вперто приходить порожньою, крутила б раунди вічно).
- `drop(proxy)` — `DeadProxyError`: використання теж рахується (не успішне), проксі виходить з пулу до наступного раунду.
- Проксі, якого ProxyMate видав би знову, приймається, лише якщо в нього лишились використання цього раунду, і чекає `last_used_at + USE_INTERVAL`.
- Dou: один `acquire` лістингу — два HTTP-запити (GET CSRF + POST xhr) на тому ж проксі; рахується як одне використання.
- `exhausted?` — `@drained && @by_id.empty?` → воркер виставляє `stop[0]`.

Пропускна здатність: кожен проксі — щонайбільше один запит на хвилину на сайт і `MAX_USES` за раунд. Стабільний розмір пулу ≈ (запитів/с) × `USE_INTERVAL`.

### Refill, раунди і завершення

`acquire` викликає `refill`, коли готових **зараз** проксі менше `MIN_READY`, не частіше за `@refill_interval` і лише одним файбером (`@refilling`; запит до ProxyMate через `Net::HTTP` yield-иться реактору, решта файберів ротують що лишилось). `refill` просить `REFILL_BATCH` у тій самій сесії.

- Refill додав нове → `@refill_interval = REFILL_INTERVAL`.
- Нічого не додав (порожня пачка або лише проксі, вже використані цього раунду `MAX_USES` разів) чи помилка → інтервал подвоюється до `MAX_REFILL_INTERVAL`; помилка пише `vacancy_sync_proxy_refill_failed`.

**Кінець раунду:** пул **порожній** і refill нічого не додав при `remaining: 0` (сесія вже мала все, що ProxyMate може дати) **або** `MAX_REFILL_FAILURES` refill-ів поспіль нічого не додали чи впали, поки пул порожній. Поки в пулі є проксі, що лише вичікують `USE_INTERVAL`, раунд не закінчується. Новий раунд (`next_round`, `vacancy_sync_proxy_round_started`): `@uses` скидається, і **всі** проксі з `@known` — мертві (`drop`) і «на пенсії» — повертаються в пул, відсортовані за `last_used_at` (найдавніше використаний — першим, рівні — у порядку, в якому запуск їх отримав) з `available_at = max(last_used_at + USE_INTERVAL, now)`: ця величина не спадає вздовж такого порядку, а `enqueue` тримає порядок серед рівних, тож `@idle` видає найдавніше використаний першим і кожного — не раніше `USE_INTERVAL` від його останнього використання. Refill-и йдуть далі як були: нове від ProxyMate додається до пулу.

**Що зупиняє джерело, коли світ лишається зламаним:** кожен раунд рахує успішні використання (`release` без `ok: false`). `MAX_EMPTY_ROUNDS` (2) раунди **поспіль** без жодного — або seed без жодного проксі — → `@drained` → `exhausted?` → `stop[0]` → фаза кидає `NoProxiesError`. Чому скінченно: успіхів за запуск скінченно (кожен — сторінка з даними, підтвердження кінця списку (≤ `LAST_PAGE_CONFIRMATIONS` на сторінку, сторінок ≤ `MAX_PAGES`), отриманий опис або порожня відповідь опису (≤ `MAX_VACANCY_RETRIES` на вакансію)), тож після останнього успіху минає щонайбільше `MAX_EMPTY_ROUNDS` раундів; а раунд скінченний — кожен проксі дає йому ≤ `MAX_USES` використань, а сесія не повторює проксі. Гарячого циклу немає: між refill-ами щонайменше `REFILL_INTERVAL`, з backoff.

**Радіус ураження аномалії сайту** (змінений селектор → кожна сторінка `DeadProxyError`): пул вигорає лише в RAM цього запуску (у ProxyMate нічого не потрапляє); кожен проксі — щонайбільше по одному запиту в кожному з `MAX_EMPTY_ROUNDS` раундів, і джерело зупиняється з `NoProxiesError` — без чистки застарілих вакансій.

---

## Невеликий пул з'єднань до БД (`DbGateway`)

Під `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` (`config/initializers/async_active_record.rb`) gem `pg` **yield-иться** під час очікування відповіді Postgres. Тож N паралельних файберів, що роблять DB-запити, тримають N конекшенів **одночасно** — саме це раніше змушувало роздувати пул до 300 і переповнювало серверний `max_connections = 100`.

`DbGateway` обмежує доступ до БД невеликим пулом через `Async::Semaphore.new(DB_CONCURRENCY)`:

```ruby
class DbGateway
  def call(&block)
    @semaphore.acquire do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end
end
```

Один екземпляр створюється в `perform!` і передається в `VacancyBuffer.new(@db, source)`; операційний `with_db` делегує в `@db.call`. У критичній секції одночасно щонайбільше `DB_CONCURRENCY` файберів → пул відкриває щонайбільше стільки фізичних конектів. Пул (а не строго 1) потрібен, щоб **повільний flush вакансій не блокував** швидкі читання/per-batch записи. Безпечно: джоба йде в окремому worker-процесі (не Puma), далеко під лімітом Postgres.

**Семафор не реентрантний.** Правила, щоб уникнути deadlock:
- жоден `with_db`-блок не містить вкладений `with_db`;
- **HTTP-запити скрапера** (`fetch_listing` / `fetch_description`) завжди **поза** `with_db` — інакше повільний мережевий I/O серіалізував би всі файбери (а ще ризик deadlock);
- ES `.import` (SELECT на вже взятому конекшені + HTTP bulk у ES) семафор повторно **не** входить → безпечно.

---

## RAM-буфер вакансій (`VacancyBuffer`, Phase 1)

Замість запису в БД на **кожну** сторінку, скрапнуті вакансії складаються в RAM-буфер. Один `VacancyBuffer` на джерело (джерела йдуть паралельно, `clean_old_vacancies` — per-source).

- `add(structs)` — `@buf.concat(structs)` (плейн `Array`: файбери однопотокові, `concat` не має точок yield).
- `maybe_flush` — `flush`, якщо `@buf.size >= VACANCY_BUFFER_LIMIT`.
- `flush` — yield-free swap `batch = @buf; @buf = []`, тоді `@db.call { persist(batch) }`. `@flushing` (як `@refilling` у ProxyPool) гарантує, що флашить лише один файбер, поки інші скрапають далі; appends, що приходять під час (yield-ливого) `persist`, потрапляють у новий `@buf` — нічого не губиться.
- `persist` — `Vacancy.upsert_all(... unique_by: [:source_id, :external_id], update_only: [...])` + `Vacancy.where(...).import` (це перенесений сюди колишній `sync_vacancies_batch`).

У `scrape_pages` гілка успішної сторінки: `buffer.add(listing)` → `external_ids.concat(...)` → `buffer.maybe_flush`. `external_ids` (лише рядки, мало пам'яті) накопичується окремо для `clean_old_vacancies`.

**Фінальний flush — перед `clean_old_vacancies`.** Після `barrier.wait` (усі воркери джерела зупинились → буфер стабільний) викликається `buffer.flush`, і лише потім видаляються застарілі рядки — щоб БД відображала всі скрапнуті вакансії, коли запускається `where.not(external_id: active_ids)`.

Retry/ensure-логіка (`proxy = nil` перед `retry`) буфера не торкається: повторно доданий лістинг дедуплікується через `uniq(&:external_id)` у `persist`.

---

## Дві фази виконання

```
Phase 1: sync_source       — scrape listing pages  → буфер у RAM → bulk upsert + ES (на ліміті/в кінці)
Phase 2: fetch_description — fetch description URLs → buffer {id,description,description_html} → bulk UPDATE + re-index (на пачку)
```

Фази складені в **конвеєр на кожне джерело**: в одному `Async` блоці кожне джерело йде `sync_source(source)` → `fetch_description_for_source(source)` у власному файбері, а джерела між собою — **паралельно**. Тобто описи Dou стартують одразу після лістингу Dou, не чекаючи на повільніший лістинг Djinni.

Phase 2 запускається **лише для джерел з `Scraper.fetches_description?` == `true`** (Dou). У Djinni опис уже є в лістингу — детальних сторінок відвідувати нічого.

Збій одного джерела не зупиняє інші: `sync_source_pipeline` ловить помилку фази (вона вже записана в підсумкову подію фази) і просто не додає джерело до `@synced`. Джерело, для якого ProxyMate не дав жодного проксі або запит до нього впав (`seed_pool`), пропускається; `NoProxiesError` летить з `perform!` лише коли пропущено всі. `perform!` назовні не кидає помилку джерела — результат запуску видно в події `vacancy_sync_finished` (`result: ok | partial | failed`).

---

## Скільки файберів створюється

### Phase 1

```
Async do |top_task|                          # reactor (1 неявний fiber)
  Source.all.map do |source|
    top_task.async { sync_source(source) }   # 1 fiber на source
  end
end

def sync_source(source)
  WORKERS_PER_SOURCE.times do
    barrier.async { scrape_pages(...) }      # WORKERS_PER_SOURCE fibers на source
  end
end
```

При N джерелах:
- **N** файберів-coordin­ators (по одному на джерело)
- **N × WORKERS_PER_SOURCE** файберів-воркерів (скрейпять сторінки)

### Phase 2

Джерело обробляється **пачками**: вакансії тягнуться з БД курсором по `id` (`WHERE id > last_id LIMIT VACANCY_FETCH_BATCH`), щоб не матеріалізувати всю таблицю в пам'яті. На **кожну пачку** піднімається `DESCRIPTION_WORKERS` файберів (більше, ніж у Phase 1 — фаза суто HTTP-очікування). Курсор бере **лише вакансії без `description_html`** — нові за цей запуск і ті, чий попередній фетч деталей провалився; вже наповнені пропускаються (інакше Dou щоразу переобходив би всю таблицю через rate-limited проксі). Це саме та умова, що поступово добиває `description_html` рядкам, зібраним до того, як опис почали зберігати розміткою. Курсор їде по частковому індексу `index_vacancies_pending_description_html` (`(source_id, id) WHERE description_html IS NULL OR description_html = ''`) — без нього кожен запуск сканував би вперед усі вже заповнені рядки джерела.

Воркери не пишуть у БД по одному: успішний опис іде в RAM-масив `updates << { id:, description_html:, description: }` — розмітка як є плюс її ж плейн-текстова проєкція (`Scraper.to_plain_text`), щоб дві колонки не могли розійтися. Після `barrier.wait` робиться **один bulk-UPDATE на пачку** (`bulk_update_descriptions` — `UPDATE … FROM unnest($1::bigint[], $2::text[], $3::text[])`, тобто пачка їде трьома бінд-масивами, а не інтерпольованим `VALUES (…), (…)`: текст SQL константний за будь-якого розміру пачки, Postgres парсить один statement. Чистий UPDATE, не `upsert_all`, бо INSERT-гілка впала б на NOT NULL для id+description рядків), потім ES `.import` по пачці.

---

## Умови завершення файбера

### `scrape_pages` воркер

Файбер виходить із `loop` через `break` у будь-якому з цих випадків:

| # | Умова | Причина |
|---|-------|---------|
| 1 | `stop[0]` є `true` | Глобальний stop-сигнал: воркер отримав `nil` від пулу і `pool.exhausted?` |
| 2 | `pages_queue.shift` повернув `nil` | Черга вичерпана: всі сторінки 1..2000 вже розібрані |
| 3 | `last_page[:boundary]` встановлений і `page >= last_page[:boundary]` | Підтверджено кінець списку; сторінки після межі не мають сенсу |

Додатково на кожній ітерації: якщо `pool.acquire` повернув `nil` і `pool.exhausted?` → `stop[0] = true` + `break`. Якщо пул просто зайнятий (всі проксі на кулдауні / у роботі) → `sleep(0.2)` + `next` (файбер чекає, поки звільниться проксі).

### `fetch_description_worker` воркер

| # | Умова |
|---|-------|
| 1 | `stop[0]` є `true` |
| 2 | `vacancies_queue.shift` повернув `nil` (пачка оброблена) |

---

## Що відбувається з порожньою сторінкою

Порожня сторінка = `listing&.any?` повертає `false` (nil або пустий масив).

```ruby
last_page[:counts][page] += 1
count = last_page[:counts][page]

if count >= LAST_PAGE_CONFIRMATIONS   # 50
  last_page[:boundary] = [last_page[:boundary], page].compact.min
  log("confirmed last page (#{count} empty hits)", color: :yellow)
  next
elsif count == 1
  # Fan-out: push 49 copies so all remaining confirmations run in parallel.
  (LAST_PAGE_CONFIRMATIONS - 1).times { pages_queue.unshift(page) }
end
```

### Покроково

1. **Перший порожній результат (`count == 1`)** → одразу кладемо в чергу `LAST_PAGE_CONFIRMATIONS - 1` (49) копій сторінки. Всі 49 одразу розбираються різними файберами, які роблять HTTP-запити паралельно.
2. **Наступні підтвердження (`1 < count < 50`)** → нічого не додається в чергу (копії вже там або вже в роботі).
3. **50 підтверджень** → межа встановлюється як `min(поточна_межа, ця_сторінка)`.
4. **Всі інші воркери** при `pages_queue.shift` перевіряють `page >= last_page[:boundary]` і одразу роблять `break` без HTTP-запиту. Невикористані копії в черзі також одразу викидаються таким `break`.

### Навіщо 50 підтверджень, а не одне?

Деякі сайти епізодично повертають порожню сторінку як антискрейпінговий захід. Одна порожня відповідь ≠ кінець пагінації. Лише 50 незалежних підтверджень від різних воркерів (з різними проксі) гарантують, що сторінка справді порожня.

### Чому fan-out тільки при `count == 1`

Якщо копій стає більше ніж потрібно (наприклад, якийсь воркер ретраює сторінку через `DeadProxyError` і знову кладе копію в чергу), зайві копії після встановлення `boundary` одразу ігноруються через `break if last_page[:boundary] && page >= last_page[:boundary]` — жоден зайвий HTTP-запит не відбудеться.

### Як межа тільки зменшується

```ruby
last_page[:boundary] = [last_page[:boundary], page].compact.min
```

Якщо спочатку межу підтвердила сторінка 504, а потім 500 — межа стає 500. Сторінки 500–504 вже не опрацьовуватимуться. Пізніші підтвердження можуть лише звузити діапазон.

---

## Обробка помилок у воркерах

```
DeadProxyError  → stats.dead!      → pool.drop(proxy)             → proxy = nil → page/vacancy back to queue → retry
BinaryError     → pool.release(proxy, ok: false) → page/vacancy back to queue → raise (curl не запускається — ретраї лише спалили б пул)
StandardError   → stats.error!(e)  → pool.release(proxy, ok: false) → proxy = nil → page/vacancy back to queue → retry
```

Помилки не логуються по одній (на поганому пулі це тисячі рядків) — `RequestStats` фази рахує їх за класом і віддає в підсумковій події три найчастіші з першим повідомленням (`errors`), разом з `requests`, `empty_responses`, `dead_proxies`, `failed_requests`.

Кожен `acquire` закінчується рівно одним `release` або `drop` — обидва рахують використання; успішним для раунду є лише `release` без `ok: false` (див. «Ротація»).

`retry` **не запускає** `ensure` — тому `proxy = nil` перед `retry` критичний: `ensure` (який робить `release(proxy)`) бачить `nil` і пропускає подвійний release. Успішна гілка нічого не звільняє сама — це робить `ensure`.

`stop[0] = true` при вичерпаному пулі (`pool.exhausted?`) → після `barrier.wait` операція кидає `NoProxiesError`.

---

## Phase 1: результат після всіх воркерів

```ruby
barrier.wait
buffer.flush
raise NoProxiesError if stop[0]
stale = clean_old_vacancies(source, external_ids.uniq)
Vacancy::Operation::CountBySource.expire!
total = with_db { source.vacancies.count }   # new_vacancies = total − count_before + stale
```

`clean_old_vacancies` видаляє (через `with_db`) всі вакансії цього джерела, яких **не було** серед зібраних `external_ids`, і повертає їх кількість. Захищений від порожнього запуску: `return 0 if active_ids.empty?`. Кількість нових вакансій — це різниця `source.vacancies.count` до і після фази плюс видалені; вона точна, бо джерело пише лише один запуск (`limits_concurrency`).

`expire!` скидає кеш лічильників вакансій по джерелах (`Vacancy::Operation::CountBySource::CACHE_KEY`, TTL 5 хв; його читають віджет «всього вакансій» і MCP-тул `list_sources`) — інакше головна сторінка ще до 5 хвилин після синку показує числа попереднього запуску.

## Phase 2: результат після кожної пачки

```ruby
loop do
  break if stop[0]
  vacancies_queue = with_db { ...WHERE id > last_id LIMIT VACANCY_FETCH_BATCH... }
  break if vacancies_queue.empty?
  # ...DESCRIPTION_WORKERS файберів складають updates << {id:, description:, description_html:}, barrier.wait...
  with_db do
    bulk_update_descriptions(updates.to_a)            # один UPDATE … FROM (VALUES …)
    Vacancy.where(id: updates.map { |r| r[:id] }).import
  end if updates.any?
end
raise NoProxiesError if stop[0]
```

Bulk-UPDATE і re-index в Elasticsearch робляться **по пачці** (а не по одній вакансії / не один раз у кінці) — заради обмеження пам'яті й мінімуму DB-раундтрипів.

---

## Захист від дублювання сторінок

### Проблема

Fan-out додає 49 копій сторінки в чергу. Якщо та сторінка тимчасово повернула порожній результат (антискрейпінг), але насправді має дані, копії будуть опрацьовані іншими файберами і повернуть реальні результати — одна і та сама сторінка парситься багато разів.

Друга проблема: файбер отримав порожній результат для сторінки 100, тоді як сторінка 200 вже успішно зіскрейплена — рахунок пустих відповідей для сторінки 100 досягає 50 і виставляє хибну межу.

### Рішення

**1. Пропуск точних дублів (fan-out копії)**

На початку кожної ітерації, після `pages_queue.shift`:

```ruby
next if scraped_pages.any? && scraped_pages.include?(page)
```

Якщо ця конкретна сторінка вже успішно зіскрейплена — пропустити без HTTP-запиту.

**2. Пропуск хибних порожніх підтверджень**

На початку гілки `else` (порожній результат):

```ruby
next if scraped_pages.any? && scraped_pages.max > page
```

Якщо будь-яка сторінка з номером вищим за поточну вже зіскрейплена — порожній результат для поточної сторінки є хибним сигналом; не рахувати його як підтвердження кінця пагінації.

**3. Очищення застарілих лічильників**

При успішному скрейпінгу сторінки N:

```ruby
last_page[:counts].delete_if { |p, _| p < page }
```

Усі накопичені порожні відповіді для сторінок < N скидаються — вони не можуть бути останньою сторінкою, якщо сторінка N має дані.

---

## Спільні структури даних

| Структура | Тип | Причина |
|-----------|-----|---------|
| `pages_queue` / `vacancies_queue` | `Array` | Файбери однопотокові — гонок немає |
| `@pools[source.id]` | `ProxyPool` | Пул проксі джерела; стан (`@by_id`, `@idle`, `@known`, `@uses`, `@last_used_at`, лічильники раунду) — звичайні колекції, бо файбери однопотокові |
| `@db` | `DbGateway` | Семафор(`DB_CONCURRENCY`) обмежує доступ до БД → невеликий пул конектів |
| `buffer` | `VacancyBuffer` | Per-source RAM-буфер скрапнутих вакансій; плейн `Array` + `@flushing`, бо файбери однопотокові |
| `external_ids` (Phase 1) / `updates` (Phase 2) | `Concurrent::Array` | `concat` / `<<` від N воркерів |
| `last_page` | `Hash` | Однопотоковий |
| `scraped_pages` | `Set` | Сторінки, що повернули дані; однопотоковий доступ |
| `stop` | `[false]` | Mutable ref — `stop[0] = true` видно всім воркерам |
| `done` | `[0]` | Лічильник прогресу, безпечний без mutex |

---

## Логування

Операція пише JSON-події для Grafana/Loki: `vacancy_sync_started` → (`vacancy_sync_proxy_mate_lookup_failed` / `vacancy_sync_curl_impersonate_mismatch` — warn на старті) → `vacancy_sync_proxy_pool_ready` (на джерело; `vacancy_sync_proxy_refill_failed` — коли дозапит у ProxyMate впав, `vacancy_sync_proxy_round_started` — коли пул пішов на новий раунд) → `vacancy_sync_listing_finished` / `vacancy_sync_descriptions_finished` (на джерело і фазу, через `log_phase` — також коли фаза впала) → `vacancy_sync_finished` (завжди, з `result`). Усі несуть `session_id`. Поля кожної події, дашборд і алерти — у `.ai/docs/observability.md`; змінюючи поле, оновлюйте й дашборд.
