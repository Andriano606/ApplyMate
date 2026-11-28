# Спостережуваність: події, дашборд Grafana, алерти

Rails пише в STDOUT, Promtail забирає логи контейнерів web/worker і шле їх у Loki з
лейблом `job="rails"`, Grafana (staging: http://192.168.50.155:3001) будує на них дашборди
**«Синхронізація вакансій»** (`uid: applymate-sync-vacancies`) з алертами і **«Використання MCP»**
(`uid: applymate-mcp-usage`). Метрик-сервера
(Prometheus) немає: усі графіки — це LogQL поверх JSON-подій з `ApplyMate::Logging`.

| Файл | Що в ньому |
|------|-----------|
| `app/concepts/apply_mate/logging.rb` | `log(event: ...)` — один JSON-рядок на подію |
| `docker/promtail/promtail-config.staging.yml` | збір логів, лейбли, зрізання `[ActiveJob] …` префіксів |
| `docker/grafana/provisioning/dashboards/sync_vacancies.json` | дашборд синхронізації |
| `docker/grafana/provisioning/dashboards/mcp_usage.json` | дашборд використання MCP |
| `docker/grafana/provisioning/alerting/sync_vacancies.yml` | алерти |

## Формат події

```json
{"event":"vacancy_sync_listing_finished","operation":"Vacancy::Operation::SyncVacancies","level":"info","session_id":1795309200323,"source":"Djinni",…}
```

- `operation` — клас, що написав подію; `level` — `info | warn | error` (Grafana фарбує за ним рядки).
- `source` — **завжди назва джерела** (Djinni, Dou), ніколи клас.
- Не називайте поля `status`, `method`, `controller`, `path`, `action`: Promtail піднімає ці
  JSON-ключі в лейбли потоку (вони для request-логу), і `| json` у запиті перейменує поле.
- Масиви Loki `| json` відкидає — пишіть рядком (`sources: "Djinni, Dou"`).
- Числові поля — числа (їх читає `unwrap`), не рядки.

## Події синхронізації (`Vacancy::Operation::SyncVacancies`)

Усі мають `session_id` (мс старту, однаковий для всього запуску).

| Подія | Коли | Поля |
|-------|------|------|
| `vacancy_sync_started` | старт | `started_at_ms`, `sources` |
| `vacancy_sync_proxy_mate_lookup_failed` | на старті не вдався `GET /api/v1/meta` (`level: warn`; синк іде далі, лише з `chrome146`) | `lookup` (`meta`), `error_class`, `error` |
| `vacancy_sync_curl_impersonate_mismatch` | release curl-impersonate у ProxyMate ≠ нашому піну (`ImpersonateHttp::RELEASE`) (`level: warn`) | `release` (наш), `proxy_mate_release`, `targets` (що просимо замість: `chrome146`) |
| `vacancy_sync_proxy_pool_ready` | пул джерела засіяно з ProxyMate (`level: warn`, якщо `alive` = 0 — ProxyMate не дав жодного проксі, джерело пропущено; `level: error` + `error_class`/`error`/`error_at`, якщо запит до ProxyMate впав: не налаштовано, недоступний, 401, невідомий сайт — теж пропущено) | `source`, `alive` (скільки проксі ProxyMate віддав у пул; ApplyMate їх більше не перевіряє), `with_clearance` (з них — з токеном Cloudflare) |
| `vacancy_sync_proxy_refill_failed` | дозапит проксі в ProxyMate посеред фази впав (`level: warn`; не частіше за інтервал refill з backoff до 60 с; після `MAX_REFILL_FAILURES` (3) поспіль на порожньому пулі раунд пулу закінчується) | `source`, `error_class`, `error`, `failures` (поспіль, через раунди — до першого вдалого дозапиту), `alive` (скільки лишилось у пулі) |
| `vacancy_sync_proxy_round_started` | пул джерела порожній, а ProxyMate нового не дає — почався новий раунд: усі проксі запуску (мертві й «на пенсії») повернулись у пул зі свіжими `MAX_USES` (`level: info`; після `MAX_EMPTY_ROUNDS` (2) раундів поспіль без жодного успішного запиту нового раунду немає — джерело зупиняється з `NoProxiesError`) | `source`, `round` (номер раунду, що почався: 2, 3, …), `proxies` (скільки проксі повернулось) |
| `vacancy_sync_listing_finished` | фаза списку джерела завершилась **або впала** | `source`, `result` (`ok`/`failed`), `duration_s`, `pages`, `vacancies` (унікальні на сайті), `new_vacancies`, `stale_deleted`, `vacancies_total` (у базі після фази) + поля запитів |
| `vacancy_sync_descriptions_finished` | фаза описів (лише `fetches_description?`) | `source`, `result`, `duration_s`, `missing`, `fetched`, `gave_up` (після `MAX_VACANCY_RETRIES`), `max_attempts` + поля запитів |
| `vacancy_sync_finished` | завжди, навіть коли `perform!` кинув | `result` (`ok`/`partial`/`failed`), `duration_s`, `sources_ok`, `sources_failed` |

Поля запитів (з `RequestStats` фази): `requests`, `empty_responses`, `dead_proxies`
(`DeadProxyError`), `failed_requests` (= мертві + помилки), `errors` — рядок «Клас×кількість
(перше повідомлення)» для трьох найчастіших класів або `null`.

Поля пулу (з `ProxyPool#take_counts!`): `retired_proxies` (за фазу — вичерпали `MAX_USES` у
своєму раунді), `proxy_rounds` (у якому раунді пул наприкінці фази; 1 — проксі ProxyMate
вистачило без повторів; пул спільний для обох фаз джерела, тож у фазі описів лічба продовжується).

На провалі фаза чи запуск додають `error_class`, `error`, `error_at` (перший рядок backtrace) і
`level: error`. `new_vacancies` / `stale_deleted` / `vacancies_total` у впалій фазі списку
відсутні (до чистки застарілих справа не дійшла).

## Подія MCP (`Mcp::Operation::Handle`)

`mcp_request` — одна на кожне JSON-RPC повідомлення до `/mcp` (пише `around_request` гема `mcp`;
запити без токена до нього не доходять і не логуються).

| Поле | Що в ньому |
|------|-----------|
| `rpc` | JSON-RPC метод: `initialize`, `tools/list`, `tools/call`, `ping`, … (не `method` — це лейбл Promtail) |
| `tool` | назва інструмента для `tools/call`, інакше `null` |
| `user`, `user_name` | hashid і ім'я власника токена |
| `client` | лише в `initialize`: як клієнт себе назвав (`clientInfo.name`: `claude-ai`, `claude-code`, …) |
| `result` | `ok` / `failed` (`level: warn`) |
| `error_type` | на `failed`: причина від гема (`invalid_params` — немає такого інструмента, `invalid_schema`, `missing_required_arguments`, `internal_error` — виняток) або `tool_error` — операція відмовила (`isError: true`) |
| `duration_s` | скільки обробляли повідомлення |

## Дашборд «Використання MCP»

Ряди: **За вибраний період** (stat-плитки: різних користувачів, активних за добу, викликів, підключень
= `initialize`, невдалих, p95 часу відповіді) → **Динаміка** (користувачі по днях, виклики по днях
за користувачами та за інструментами, p95 за інструментами) → **Хто і чим користується** (таблиця
користувачів, частки інструментів і клієнтів) → **Журнал** (кожне підключення і виклик).

- «Користувачів» — `count(sum by (user) (count_over_time(… [$__range])))`: instant-запит за весь період.
- Графіки по днях і кругові діаграми — `interval: 1d`: вікна не перетинаються, тож сума точок =
  підсумок за період (кругові діаграми — `calcs: sum`). Доба — за UTC.
- Таблиця — два instant-запити (виклики, підключення) по `user_name, user`, злиті трансформацією `merge`.
- Loki за замовчуванням не дає запит довший за 30 днів (`max_query_length` 721h) — період не більше `now-30d`.

## Дашборд «Синхронізація вакансій»

Ряди: **Останній запуск** (stat-плитки: коли, результат, тривалість, у банку / нових / видалено
по джерелах) → **Вакансії** → **Швидкість і проксі під час синхронізації** (зокрема «Проксі від
ProxyMate на старті» — `alive`) → **Журнал** (людський опис кожного кроку запуску через `line_format` і
окремо `warn`/`error`; рядки фаз показують і `proxy_rounds`, коли пул пішов на другий раунд;
головний журнал має рядок для `vacancy_sync_proxy_round_started`, журнал попереджень — власні
рядки для `…_proxy_refill_failed`, `…_proxy_mate_lookup_failed`, `…_curl_impersonate_mismatch`). У кожної панелі є опис (іконка ⓘ).

Як побудовані запити:

- Потік: `{job="rails"} |= "<event>" | json | __error__="" | event="<event>"` — дешевий
  підрядковий фільтр, потім точний.
- Графіки «на запуск» мають `interval: 1h` і `max by (source) (max_over_time(… | unwrap X [$__interval]))`:
  кожна точка — один запуск, без зсуву на добу, який дає крок `1d` (вікна Loki вирівняні по UTC-півночі).
- Завжди агрегуйте (`max by (source)`, `sum by (source)`): `| json` робить лейблом кожне поле,
  а `container` міняється з кожним деплоєм — без агрегації будуть десятки дубльованих серій.
- Stat-плитки беруть `lastNotNull` з того ж ряду.
- Кольори серій прив'язані до назв через overrides (`/.*Djinni.*/` синій, `/.*Dou.*/` помаранчевий).
  Нове джерело отримає колір з палітри; додайте йому override.

Змінюєте поле події — оновіть панелі, що його читають (`grep` по назві поля в JSON), і цей файл.

## Алерти (`sync_vacancies.yml`)

| UID | Спрацьовує |
|-----|-----------|
| `applymate-sync-failed` | `result` **останнього** `vacancy_sync_finished` за 26 год ≠ `ok` (зникає, щойно пройде чистий запуск) |
| `applymate-sync-missing` | за 26 год не було жодного `vacancy_sync_finished` (NoData теж = алерт): джоба не стартує або процес вбили/завис посеред запуску |

`vacancy_sync_finished` пишеться з `ensure`, тому його пропускає лише вбитий або завислий
процес — саме тому «missing» дивиться на кінець запуску, а не на старт. «Останній» результат
береться так: `| label_format failed=… | keep failed | unwrap failed` — `keep` прибирає лейбл
`container`, що міняється з кожним деплоєм, і `last_over_time` бачить одну серію. Плитка
«Результат» на дашборді рахується тим самим виразом.

Видалений з файлу provisioned-алерт лишається в базі Grafana — додавайте його UID у
`deleteRules`, як зроблено для старих `applymate-proxy-*`.

## Розгортання змін на staging

Дашборди і алерти — файли аксесуара `grafana` (`config/deploy.staging.yml`), тож після зміни:
`bin/kamal accessory reboot grafana -d staging`. Нові поля подій з'являються після деплою
застосунку і наступного запуску відповідної джоби.

## Перевірка дашборду локально

Підніміть окремі Loki + Grafana (не dev-стек), залийте в Loki синтетичні події через
`POST /loki/api/v1/push` з лейблом `job="rails"` і змонтуйте теку дашбордів. У конфігу Loki для
цього вимкніть `reject_old_samples` і поставте `querier.query_ingesters_within: 0`, інакше
події старші за 3 год не знайдуться, доки не скинуться в сховище.
