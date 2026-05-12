# Vacancy::Operation::SyncVacancies

Операція повної синхронізації вакансій із зовнішніх джерел. Запускається через `Vacancy::Job::SyncVacancies` (SolidQueue).

## Константи

| Константа | Значення | Роль |
|-----------|----------|------|
| `WORKERS_PER_SOURCE` | 200 | Кількість файберів-воркерів на одне джерело |
| `MAX_PAGES` | 2000 | Верхня межа черги сторінок |
| `LAST_PAGE_CONFIRMATIONS` | 50 | Скільки разів сторінка має повернути порожній результат, щоб вважатись останньою |

---

## Дві фази виконання

```
Phase 1: sync_source       — scrape listing pages  → upsert vacancies to DB + ES
Phase 2: fetch_description — fetch description URLs → update vacancy.description + re-index
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
    barrier.async { scrape_pages(...) }      # 200 fibers на source
  end
end
```

При N джерелах:
- **N** файберів-coordin­ators (по одному на джерело)
- **N × 200** файберів-воркерів (скрейпять сторінки)
- **Разом: N × 201** файберів у Phase 1

### Phase 2

Аналогічна структура:
- **N** файберів-coordinators
- **N × 200** файберів-воркерів (качають description)
- **Разом: N × 201** файберів у Phase 2

> При двох джерелах (наприклад Djinni + DOU) одночасно активні **402 файбери** в кожній фазі.

---

## Умови завершення файбера

### `scrape_pages` воркер

Файбер виходить із `loop` через `break` у будь-якому з цих випадків:

| # | Умова | Причина |
|---|-------|---------|
| 1 | `stop[0]` є `true` | Глобальний stop-сигнал: хтось із воркерів виявив, що проксі в базі 0 |
| 2 | `pages_queue.shift` повернув `nil` | Черга вичерпана: всі сторінки 1..2000 вже розібрані |
| 3 | `last_page[:boundary]` встановлений і `page >= last_page[:boundary]` | Підтверджено кінець списку; сторінки після межі не мають сенсу |

Додатково на кожній ітерації: якщо проксі не вдалося захопити і БД порожня → `stop[0] = true` + `break`. Якщо проксі немає але є в базі → `sleep(5)` + `next` (файбер продовжує чекати).

### `fetch_description_worker` воркер

| # | Умова |
|---|-------|
| 1 | `stop[0]` є `true` |
| 2 | `vacancies_queue.shift` повернув `nil` (всі вакансії оброблені) |

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
DeadProxyError  → proxy.increment_fail!       → release proxy → proxy = nil → page/vacancy back to queue → retry
StandardError   → log error              → release proxy → proxy = nil → page/vacancy back to queue → retry
```

`retry` **не запускає** `ensure` — тому `proxy = nil` перед `retry` критичний: `ensure` бачить `nil` і пропускає подвійний release.

`stop[0] = true` при відсутності проксі в БД → після `barrier.wait` операція кидає `NoProxiesError`.

---

## Phase 1: результат після всіх воркерів

```ruby
barrier.wait
raise NoProxiesError if stop[0]
clean_old_vacancies(source, external_ids)
```

`clean_old_vacancies` видаляє всі вакансії цього джерела, яких **не було** серед зібраних `external_ids`. Захищений від порожнього запуску: `return if active_ids.empty?`.

## Phase 2: результат після всіх воркерів

```ruby
barrier.wait
raise NoProxiesError if stop[0]
Vacancy.where(id: updated_ids).import if updated_ids.any?
```

Bulk re-index в Elasticsearch лише оновлених вакансій.

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
| `in_use_proxy_ids` | `Set` | Однопотоковий доступ |
| `external_ids` / `updated_ids` | `Concurrent::Array` | `concat` / `<<` від N воркерів |
| `last_page` | `Hash` | Однопотоковий |
| `scraped_pages` | `Set` | Сторінки, що повернули дані; однопотоковий доступ |
| `stop` | `[false]` | Mutable ref — `stop[0] = true` видно всім воркерам |
| `done` | `[0]` | Лічильник прогресу, безпечний без mutex |

---

## Логування

Кожен рядок лога містить `ctx`-тег:

```
[Djinni|p42|1.2.3.4|f7890] 20 items
[DOU|p501|—|f1234] confirmed last page (50 empty hits)
```

Формат: `[source|сторінка_або_external_id|proxy_host|fiber_id(останні 4 символи)]`
