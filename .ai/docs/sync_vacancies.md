# Vacancy::Operation::SyncVacancies

Операція повної синхронізації вакансій із зовнішніх джерел. Запускається через `Vacancy::Job::SyncVacancies` (SolidQueue).

> **Один запуск за раз.** Джоба має `limits_concurrency to: 1` — in-memory пул проксі (див. нижче) володіє правилом «1 проксі раз на 5с» у пам'яті, а не в БД, тож два паралельні запуски ділили б проксі частіше за кулдаун.

> **Дані живуть у RAM; БД чіпається лише за двома тригерами:** (1) пул проксі порожній → дотягнути пачку (`ProxyPool#refill`); (2) RAM-буфер вакансій досяг `VACANCY_BUFFER_LIMIT` → bulk-flush у БД + очищення буфера (`VacancyBuffer#maybe_flush`), плюс фінальний flush у кінці кожного джерела. Увесь доступ до БД іде через `DbGateway` → щонайбільше `DB_CONCURRENCY` фізичних з'єднань на весь джоб.

## Константи

| Константа | Значення | Роль |
|-----------|----------|------|
| `WORKERS_PER_SOURCE` | 50 | Файберів-воркерів на джерело у Phase 1 (лістинг) |
| `DESCRIPTION_WORKERS` | 200 | Файберів-воркерів на джерело у Phase 2 (описи) — фаза суто HTTP-очікування, масштабується ширше |
| `MAX_PAGES` | 2000 | Верхня межа черги сторінок |
| `LAST_PAGE_CONFIRMATIONS` | 50 | Скільки разів сторінка має повернути порожній результат, щоб вважатись останньою |
| `VACANCY_FETCH_BATCH` | 1000 | Розмір пачки вакансій, що тягнуться з БД у Phase 2 |
| `VACANCY_BUFFER_LIMIT` | 1000 | Скільки скрапнутих вакансій тримається в RAM перед bulk-flush у БД (Phase 1) |
| `DB_CONCURRENCY` | 5 | Макс. одночасних DB-операцій (== фізичних конектів) у `DbGateway` |
| `HTTP_REQUEST_TIMEOUT` | 6 | request-таймаут клієнта для sync (агресивний — швидко відсіює мертві проксі) |
| `HTTP_CONNECT_TIMEOUT` | 3 | TCP-connect таймаут клієнта для sync |

`ProxyPool` (вкладений приватний клас):

| Константа | Значення | Роль |
|-----------|----------|------|
| `BURST_LIMIT` | 15 | Скільки запитів проксі робить поспіль перед відпочинком |
| `BURST_COOLDOWN` | 10 | Секунд відпочинку проксі після burst-серії (виміряно: ~15 запитів витримує CF) |
| `MIN_LIVE` | 1000 | Поріг живих проксі, нижче якого запускається refill |
| `BATCH_SIZE` | 3000 | Скільки `ready_for_use` проксі тягнеться за один load/refill |
| `REFILL_INTERVAL` | 5 | Мінімум секунд між refill-ами, коли пул малий (захист від частих запитів у БД) |

---

## In-memory пул проксі (`ProxyPool`)

Замість `Proxy.transaction { FOR UPDATE SKIP LOCKED }` на **кожен** запит, проксі завантажуються в пам'ять **пачками** і ротуються там. Один екземпляр `ProxyPool` створюється в `perform!` і спільний для обох фаз і всіх джерел.

### Ротація

- `acquire` — повертає `Proxy`, у якого `available_at <= now` і `!in_use`, без запиту в БД. Виставляє `in_use = true`. Якщо нічого вільного зараз — повертає `nil` (воркер чекає `sleep(0.2)` і ретраїть).
- `release(proxy, status:)`:
  - `:success` — буферизує +1 до лічильника успіхів; рахує запит у burst (відпочинок лише після `BURST_LIMIT`);
  - `:keep` — порожня сторінка / транзієнтна помилка: рахує запит у burst, без статистики;
  - `:dead` (`DeadProxyError`) — **видаляє** проксі з ротації (in-memory) і буферизує +1 до лічильника фейлів.
- `exhausted?` — `@drained && @entries.empty?`: проксі скінчились і в БД, і в пам'яті → воркер виставляє `stop[0]`.

Burst-модель кулдауну: проксі лишається одразу доступним (`available_at = now`), поки не зробить `BURST_LIMIT` (15) запитів, тоді відпочиває `now + BURST_COOLDOWN` (10с). Заміри: проксі витримує ~15 запитів через `ImpersonateHttp` проти Cloudflare, тоді його варто відпустити «відпочити». Лічильник `burst` — у `Entry`. Без запису `last_used_at` у БД на кожен запит.

### Refill і flush

`acquire` тригерить `refill`, коли `@entries` порожній **або** `live < MIN_LIVE` (не частіше за `REFILL_INTERVAL`). `refill` (під прапором `@refilling`, щоб лише один файбер тягнув):

1. **flush** буферів (`flush_pending`): один `Proxy.upsert_all(rows, unique_by: :id, update_only: %i[success_count fail_count failed_at reliability])` замість N окремих `increment_succeeded!`/`increment_fail!`. Рядки складаються з завантажених у пам'ять проксі: `success_count = поточний + N`, `fail_count = поточний + кількість фейлів`, `failed_at = now` для тих, що падали, і перерахований `reliability`. **Видалення ненадійних проксі тут НЕ робиться** — це винесено в окрему джобу;
2. дотягує `Proxy.ready_for_use.where.not(id: @known_ids).limit(BATCH_SIZE)` — `by_reliability` тепер сортує за **збереженою індексованою колонкою `proxies.reliability`** (success-ratio, default 1.0 для нетестованих), тож refill по ~1M проксі — index-scan + рання зупинка на LIMIT, а не full scan + sort. Колонка підтримується і в bulk-flush, і в модельних `increment_*`. Індекси: `reliability`, `failed_at`, `last_used_at`;
3. якщо нічого не дотягнулось і пул порожній → `@drained = true`.

`flush!` викликається один раз у `ensure` блоці `perform!` — допише всі залишкові лічильники одним upsert-ом.

> **Видалення проксі — окремою джобою (TODO).** Раніше `increment_fail!` робив `destroy`, коли проксі перевищував `MAX_FAIL_RATIO`/`MAX_FAIL_COUNTER`. Тепер flush лише інкрементує `fail_count`/`failed_at`; фактичне прибирання ненадійних проксі має робити окрема джоба за тими ж порогами. Модельний `increment_fail!` (з логікою `destroy`) лишається для іншого коду/тестів, але цей пайплайн його більше не викликає.

`increment_succeeded!` приймає необов'язковий аргумент-лічильник (`by = 1`), щоб флашити агреговані успіхи одним апдейтом на проксі.

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

Один екземпляр створюється в `perform!` і передається в `ProxyPool.new(@db)`; операційний і ProxyPool-івський `with_db` делегують у `@db.call`. У критичній секції одночасно щонайбільше `DB_CONCURRENCY` файберів → пул відкриває щонайбільше стільки фізичних конектів. Пул (а не строго 1) потрібен, щоб **повільний refill проксі не блокував** швидкі читання/per-batch записи. Безпечно: джоба йде в окремому worker-процесі (не Puma), далеко під лімітом Postgres.

**Семафор не реентрантний.** Правила, щоб уникнути deadlock:
- жоден `with_db`-блок не містить вкладений `with_db`;
- **HTTP-запити скрапера** (`fetch_listing` / `fetch_description`) завжди **поза** `with_db` — інакше повільний мережевий I/O серіалізував би всі файбери (а ще ризик deadlock);
- ES `.import` (SELECT на вже взятому конекшені + HTTP bulk у ES) семафор повторно **не** входить → безпечно.

---

## RAM-буфер вакансій (`VacancyBuffer`, Phase 1)

Замість запису в БД на **кожну** сторінку, скрапнуті вакансії складаються в RAM-буфер. Один `VacancyBuffer` на джерело (джерела йдуть паралельно, `clean_old_vacancies` — per-source).

- `add(structs)` — `@buf.concat(structs)` (плейн `Array`: файбери однопотокові, `concat` не має точок yield).
- `maybe_flush` — `flush`, якщо `@buf.size >= VACANCY_BUFFER_LIMIT`.
- `flush` — yield-free swap `batch = @buf; @buf = []`, тоді `@db.call { persist(batch) }`. `@flushing` (дзеркало `@refilling` у ProxyPool) гарантує, що флашить лише один файбер, поки інші скрапають далі; appends, що приходять під час (yield-ливого) `persist`, потрапляють у новий `@buf` — нічого не губиться.
- `persist` — `Vacancy.upsert_all(... unique_by: [:source_id, :external_id], update_only: [...])` + `Vacancy.where(...).import` (це перенесений сюди колишній `sync_vacancies_batch`).

У `scrape_pages` гілка успішної сторінки: `buffer.add(listing)` → `external_ids.concat(...)` → `buffer.maybe_flush`. `external_ids` (лише рядки, мало пам'яті) накопичується окремо для `clean_old_vacancies`.

**Фінальний flush — перед `clean_old_vacancies`.** Після `barrier.wait` (усі воркери джерела зупинились → буфер стабільний) викликається `buffer.flush`, і лише потім видаляються застарілі рядки — щоб БД відображала всі скрапнуті вакансії, коли запускається `where.not(external_id: active_ids)`.

Retry/ensure-логіка (`proxy = nil` перед `retry`) буфера не торкається: повторно доданий лістинг дедуплікується через `uniq(&:external_id)` у `persist`.

---

## Дві фази виконання

```
Phase 1: sync_source       — scrape listing pages  → буфер у RAM → bulk upsert + ES (на ліміті/в кінці)
Phase 2: fetch_description — fetch description URLs → buffer {id,description} → bulk UPDATE + re-index (на пачку)
```

Фази виконуються **послідовно** (два окремі `Async do` блоки). Всередині кожної фази джерела обробляються **паралельно**.

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

Джерело обробляється **пачками**: вакансії тягнуться з БД курсором по `id` (`WHERE id > last_id LIMIT VACANCY_FETCH_BATCH`), щоб не матеріалізувати всю таблицю в пам'яті. На **кожну пачку** піднімається `DESCRIPTION_WORKERS` файберів (більше, ніж у Phase 1 — фаза суто HTTP-очікування). Воркери не пишуть у БД по одному: успішний опис іде в RAM-масив `updates << { id:, description: }`; після `barrier.wait` робиться **один bulk-UPDATE на пачку** (`bulk_update_descriptions` — `UPDATE … FROM (VALUES …)`, чистий UPDATE, не `upsert_all`, бо INSERT-гілка впала б на NOT NULL для id+description рядків), потім ES `.import` по пачці.

---

## Умови завершення файбера

### `scrape_pages` воркер

Файбер виходить із `loop` через `break` у будь-якому з цих випадків:

| # | Умова | Причина |
|---|-------|---------|
| 1 | `stop[0]` є `true` | Глобальний stop-сигнал: воркер отримав `nil` від пулу і `@proxy_pool.exhausted?` |
| 2 | `pages_queue.shift` повернув `nil` | Черга вичерпана: всі сторінки 1..2000 вже розібрані |
| 3 | `last_page[:boundary]` встановлений і `page >= last_page[:boundary]` | Підтверджено кінець списку; сторінки після межі не мають сенсу |

Додатково на кожній ітерації: якщо `@proxy_pool.acquire` повернув `nil` і `@proxy_pool.exhausted?` → `stop[0] = true` + `break`. Якщо пул просто зайнятий (всі проксі на кулдауні / у роботі) → `sleep(0.2)` + `next` (файбер чекає, поки звільниться проксі).

### `fetch_description_worker` воркер

| # | Умова |
|---|-------|
| 1 | `stop[0]` є `true` |
| 2 | `skip[0]` є `true` (скрейпер повернув `'SKIPP'` — джерело не має окремих сторінок з описом, напр. Djinni) |
| 3 | `vacancies_queue.shift` повернув `nil` (пачка оброблена) |

`skip[0] = true` зупиняє не лише воркер, а й зовнішній цикл по пачках для цього джерела.

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
DeadProxyError  → @proxy_pool.release(proxy, status: :dead)  → proxy = nil → page/vacancy back to queue → retry
StandardError   → log error → @proxy_pool.release(proxy, status: :keep) → proxy = nil → page/vacancy back to queue → retry
```

`:dead` прибирає проксі з ротації і буферизує `increment_fail!` (фактичний запис у БД — під час наступного `refill` або фінального `flush!`). `:keep` лише ставить проксі на кулдаун, без зміни статистики.

`retry` **не запускає** `ensure` — тому `proxy = nil` перед `retry` критичний: `ensure` (який робить `release(..., status: :keep)`) бачить `nil` і пропускає подвійний release. Успішна гілка робить `release(..., status: :success)` і теж виставляє `proxy = nil`.

`stop[0] = true` при вичерпаному пулі (`@proxy_pool.exhausted?`) → після `barrier.wait` операція кидає `NoProxiesError`.

---

## Phase 1: результат після всіх воркерів

```ruby
barrier.wait
raise NoProxiesError if stop[0]
clean_old_vacancies(source, external_ids)
```

`clean_old_vacancies` видаляє всі вакансії цього джерела, яких **не було** серед зібраних `external_ids`. Захищений від порожнього запуску: `return if active_ids.empty?`.

## Phase 2: результат після кожної пачки

```ruby
loop do
  break if skip[0] || stop[0]
  vacancies_queue = with_db { ...WHERE id > last_id LIMIT VACANCY_FETCH_BATCH... }
  break if vacancies_queue.empty?
  # ...DESCRIPTION_WORKERS файберів складають updates << {id:, description:}, barrier.wait...
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
| `@proxy_pool` | `ProxyPool` | Спільний пул проксі; стан (`@entries`, буфери) — звичайні колекції, бо файбери однопотокові |
| `@db` | `DbGateway` | Семафор(`DB_CONCURRENCY`) обмежує доступ до БД → невеликий пул конектів |
| `buffer` | `VacancyBuffer` | Per-source RAM-буфер скрапнутих вакансій; плейн `Array` + `@flushing`, бо файбери однопотокові |
| `external_ids` (Phase 1) / `updates` (Phase 2) | `Concurrent::Array` | `concat` / `<<` від N воркерів |
| `last_page` | `Hash` | Однопотоковий |
| `scraped_pages` | `Set` | Сторінки, що повернули дані; однопотоковий доступ |
| `stop` / `skip` | `[false]` | Mutable ref — `stop[0]`/`skip[0] = true` видно всім воркерам |
| `done` | `[0]` | Лічильник прогресу, безпечний без mutex |

---

## Логування

Кожен рядок лога містить `ctx`-тег:

```
[Djinni|p42|1.2.3.4|f7890] 20 items
[DOU|p501|—|f1234] confirmed last page (50 empty hits)
```

Формат: `[source|сторінка_або_external_id|proxy_host|fiber_id(останні 4 символи)]`
