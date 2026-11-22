# Спостережуваність: події, дашборд Grafana, алерти

Rails пише в STDOUT, Promtail забирає логи контейнерів web/worker і шле їх у Loki з
лейблом `job="rails"`, Grafana (staging: http://192.168.50.155:3001) будує на них дашборд
**«Синхронізація вакансій»** (`uid: applymate-sync-vacancies`) і алерти. Метрик-сервера
(Prometheus) немає: усі графіки — це LogQL поверх JSON-подій з `ApplyMate::Logging`.

| Файл | Що в ньому |
|------|-----------|
| `app/concepts/apply_mate/logging.rb` | `log(event: ...)` — один JSON-рядок на подію |
| `docker/promtail/promtail-config.staging.yml` | збір логів, лейбли, зрізання `[ActiveJob] …` префіксів |
| `docker/grafana/provisioning/dashboards/sync_vacancies.json` | дашборд |
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
| `vacancy_sync_proxy_pool_ready` | пул джерела засіяно (`level: warn`, якщо `alive` = 0 — джерело пропущено) | `source`, `checked` (скільки кандидатів перевірено), `alive` |
| `vacancy_sync_listing_finished` | фаза списку джерела завершилась **або впала** | `source`, `result` (`ok`/`failed`), `duration_s`, `pages`, `vacancies` (унікальні на сайті), `new_vacancies`, `stale_deleted`, `vacancies_total` (у базі після фази) + поля запитів |
| `vacancy_sync_descriptions_finished` | фаза описів (лише `fetches_description?`) | `source`, `result`, `duration_s`, `missing`, `fetched`, `gave_up` (після `MAX_VACANCY_RETRIES`), `max_attempts` + поля запитів |
| `vacancy_sync_finished` | завжди, навіть коли `perform!` кинув | `result` (`ok`/`partial`/`failed`), `duration_s`, `sources_ok`, `sources_failed` |

Поля запитів (з `RequestStats` фази): `requests`, `empty_responses`, `dead_proxies`,
`failed_requests` (= мертві + помилки), `errors` — рядок «Клас×кількість (перше повідомлення)»
для трьох найчастіших класів або `null`.

На провалі фаза чи запуск додають `error_class`, `error`, `error_at` (перший рядок backtrace) і
`level: error`. `new_vacancies` / `stale_deleted` / `vacancies_total` у впалій фазі списку
відсутні (до чистки застарілих справа не дійшла).

## Події пулу проксі

| Подія | Хто | Поля |
|-------|-----|------|
| `proxy_validation_finished` | `Proxy::Operation::Validate`, кожні 5 хв, одна на джерело (і коли перевіряти нічого — нулі) | `source`, `scope` (`untested`/`working`), `checked`, `alive`, `duration_s` |
| `proxy_fetch_finished` | `Proxy::Operation::FetchProxies`, раз на добу | `candidates`, `inserted`, `duration_s` |

## Дашборд

Ряди: **Останній запуск** (stat-плитки: коли, результат, тривалість, у банку / нових / видалено
по джерелах) → **Вакансії** → **Швидкість і проксі під час синхронізації** → **Пул проксі
(фонові задачі)** → **Журнал** (людський опис кожного кроку запуску через `line_format` і
окремо `warn`/`error`). У кожної панелі є опис (іконка ⓘ).

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

Дашборд і алерти — файли аксесуара `grafana` (`config/deploy.staging.yml`), тож після зміни:
`bin/kamal accessory reboot grafana -d staging`. Нові поля подій з'являються після деплою
застосунку і наступного запуску відповідної джоби.

## Перевірка дашборду локально

Підніміть окремі Loki + Grafana (не dev-стек), залийте в Loki синтетичні події через
`POST /loki/api/v1/push` з лейблом `job="rails"` і змонтуйте теку дашбордів. У конфігу Loki для
цього вимкніть `reject_old_samples` і поставте `querier.query_ingesters_within: 0`, інакше
події старші за 3 год не знайдуться, доки не скинуться в сховище.
