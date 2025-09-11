# Tiles Proxy Cache

Высокопроизводительный сервис кеширования тайлов карт с интеллектуальным кешированием, фоновой предзагрузкой и комплексным мониторингом. Сервис работает как промежуточный слой между клиентами карт и провайдерами тайлов, оптимизируя производительность через локальное кеширование и автоматизированное управление тайлами.

[![Ruby](https://img.shields.io/badge/ruby-3.4+-red.svg)](https://ruby-lang.org)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](../../docker/)
[![Sinatra](https://img.shields.io/badge/sinatra-web_framework-lightgrey.svg)](http://sinatrarb.com/)
[![English](https://img.shields.io/badge/english-documentation-blue.svg)](../../../README.md)

## Основные возможности

- **Кеширование тайлов**: Локальное кеширование с использованием SQLite и схемы MBTiles для оптимальной производительности
- **Фоновая загрузка тайлов**: Автоматизированная система предзагрузки с настраиваемыми стратегиями сканирования и дневными лимитами
- **Поддержка множества источников**: Одновременное кеширование из различных провайдеров тайлов (спутниковые, топографические, векторные и др.)
- **Обработка ошибок**: Продвинутое отслеживание промахов с настраиваемыми тайлами ошибок для различных HTTP статусов
- **Веб-интерфейс мониторинга**: Статистика в реальном времени, анализ покрытия и интерактивный предварительный просмотр карт
- **Оптимизация производительности**: SQLite в режиме WAL, пулинг соединений и файловый ввод-вывод с отображением в память
- **Готов к Docker**: Контейнеризованное развертывание с монтированием томов для конфигурации и постоянства данных

## Обзор архитектуры

Сервис состоит из нескольких интегрированных компонентов:

### Основные компоненты

- **[Движок прокси тайлов](../../config.ru)** - Основное Sinatra приложение для обработки запросов тайлов с интеллектуальным кешированием
- **[Фоновый загрузчик тайлов](../../background_tile_loader.rb)** - Автоматическая предзагрузка тайлов с настраиваемыми стратегиями сканирования
- **[Менеджер базы данных](../../database_manager.rb)** - Оптимизация SQLite базы данных и управление схемой MBTiles
- **[Менеджер метаданных](../../metadata_manager.rb)** - Автоматическое определение формата и инициализация метаданных
- **[Интерфейс мониторинга](../../views/)** - Веб-панель для статистики и предварительного просмотра карт

### Поток данных

1. **Запрос тайла** → Проверка кеша → Выдача кешированного тайла или получение из источника
2. **Промах кеша** → HTTP запрос к источнику → Сохранение в SQLite → Выдача клиенту
3. **Фоновое сканирование** → Систематическая предзагрузка тайлов на основе границ зума
4. **Управление ошибками** → Отслеживание промахов с механизмами тайм-аута и очистки

## Быстрый старт

### Использование Docker

```bash
# Создание файла конфигурации
cat > tile-services.yaml << EOF
World_Imagery:
  path: "/wi/:z/:x/:y"
  target: "https://example-satellite.com/imagery/tiles/{z}/{y}/{x}.png"
  minzoom: 1
  maxzoom: 20
  mbtiles_file: "world_imagery.mbtiles"
  autoscan:
    enabled: false
    daily_limit: 5000
    max_scan_zoom: 10
EOF

# Запуск с Docker
docker run --rm \
  -v $(pwd)/tile-services.yaml:/configs/tile-services.yaml \
  -v $(pwd)/tiles_data:/app \
  -p 7000:7000 \
  tiles-proxy-cache

# Доступ к сервису
open http://localhost:7000
```

### Локальная разработка

```bash
# Клонирование репозитория
git clone <repository-url>
cd tiles-proxy-cache

# Установка зависимостей
cd src && bundle install

# Настройка сервисов тайлов
cp configs/tile-services.yaml.example configs/tile-services.yaml

# Запуск сервера разработки
bundle exec rackup -p 7000

# Запуск тестов
bundle exec rspec
```

## Конфигурация

Сервис использует YAML файлы конфигурации для определения источников тайлов и поведения кеширования:

```yaml
# configs/tile-services.yaml
Source_Name:
  path: "/tiles/:z/:x/:y"                           # URL шаблон для выдачи тайлов
  target: "https://example.com/tiles/{z}/{x}/{y}"   # URL сервера источника тайлов
  minzoom: 1                                        # Минимальный уровень зума
  maxzoom: 20                                       # Максимальный уровень зума
  miss_timeout: 300                                 # Секунды для кеширования ошибочных ответов
  miss_max_records: 10000                           # Максимум записей ошибок перед очисткой
  mbtiles_file: "tiles.mbtiles"                     # Имя файла SQLite базы данных
  
  # Конфигурация заголовков запроса/ответа
  headers:
    request:
      User-Agent: "TilesProxyCache/1.0"
      Referer: "https://example.com"
    response:
      Cache-Control:
        max-age:
          hit: 86400    # 24 часа для попаданий в кеш
          miss: 300     # 5 минут для промахов кеша
  
  # Метаданные для совместимости с MapBox/MapLibre
  metadata:
    bounds: "-180,-85.0511,180,85.0511"             # Географические границы
    center: "0,0,2"                                 # Центр и зум по умолчанию
    type: "baselayer"                               # Тип слоя (baselayer|overlay)
  
  # Фоновая предзагрузка тайлов
  autoscan:
    enabled: true                                   # Включить фоновое сканирование
    daily_limit: 30000                             # Максимум тайлов в день
    max_scan_zoom: 12                               # Максимальный уровень зума для сканирования
    strategy: "grid"                                # Стратегия сканирования
```

### Пример множественных источников

```yaml
# Спутниковые изображения
World_Imagery:
  path: "/wi/:z/:x/:y"
  target: "https://example-satellite.com/imagery/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "world_imagery.mbtiles"
  autoscan: { enabled: false, daily_limit: 5000 }

# Топографические карты
Topographic:
  path: "/topo/:z/:x/:y"
  target: "https://example-topo.com/maps/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "topographic.mbtiles"
  headers:
    response:
      Cache-Control:
        max-age:
          hit: 604800     # 7 дней
          miss: 3600      # 1 час

# Карты открытых источников
OSM:
  path: "/osm/:z/:x/:y"
  target: "https://example-osm.org/tiles/{z}/{x}/{y}.png"
  mbtiles_file: "openstreetmap.mbtiles"
  autoscan: { enabled: true, daily_limit: 10000, strategy: "grid" }
```

## API Справочник

### Эндпоинты тайлов

| Эндпоинт | Метод | Описание | Ответ |
|----------|--------|-------------|----------|
| `/{path}/:z/:x/:y` | GET | Получение тайла карты | Бинарные данные тайла |
| `/{path}` | GET | Получение Mapbox style JSON | JSON определение стиля |

### Эндпоинты управления

| Эндпоинт | Метод | Описание | Ответ |
|----------|--------|-------------|----------|
| `/` | GET | Панель с статистикой сервиса | HTML интерфейс |
| `/db?source=name` | GET | Просмотрщик базы данных для конкретного источника | HTML табличное представление |
| `/map?source=name` | GET | Интерактивный предварительный просмотр карты | HTML интерфейс карты |
| `/{path}` | GET | MapLibre стиль для источника | JSON стиль |

### Заголовки ответа

Все ответы тайлов включают заголовки статуса кеша:

```http
Cache-Control: public, max-age=86400
X-Cache-Status: HIT|MISS|ERROR
Content-Type: image/png|image/jpeg|image/webp
```

## Схема базы данных

Каждый источник тайлов использует SQLite базу данных со схемой, совместимой с MBTiles:

### Таблицы

**tiles** - Кешированные данные тайлов
```sql
CREATE TABLE tiles (
  zoom_level INTEGER NOT NULL,
  tile_column INTEGER NOT NULL,
  tile_row INTEGER NOT NULL,
  tile_data BLOB NOT NULL,
  UNIQUE (zoom_level, tile_column, tile_row)
);
```

**metadata** - Метаданные источника
```sql
CREATE TABLE metadata (
  name TEXT NOT NULL,
  value TEXT
);
```

**misses** - Отслеживание ошибок
```sql
CREATE TABLE misses (
  z INTEGER, x INTEGER, y INTEGER, 
  ts INTEGER, reason TEXT, details TEXT,
  status INTEGER, response_body BLOB
);
```

**tile_scan_progress** - Состояние фонового сканирования
```sql
CREATE TABLE tile_scan_progress (
  source TEXT NOT NULL,
  zoom_level INTEGER NOT NULL,
  last_x INTEGER DEFAULT 0,
  last_y INTEGER DEFAULT 0,
  status TEXT DEFAULT 'waiting'
);
```

## Возможности производительности

### Оптимизации SQLite

- **Режим WAL**: Write-Ahead Logging для одновременных операций чтения/записи
- **Отображение в память**: 512MB mmap_size для более быстрого доступа к файлам
- **Пулинг соединений**: До 8 одновременных соединений на источник
- **Оптимизированные Pragma**: Настроенные для рабочих нагрузок кеширования тайлов

### Стратегия кеширования

- **Интеллектуальное отслеживание промахов**: Предотвращает повторные запросы отсутствующих тайлов
- **Механизмы очистки**: Автоматическое удаление старых данных на основе настроенных лимитов
- **Блокировочная конкурентность**: Per-tile mutex для предотвращения дублирующих запросов
- **Выдача тайлов ошибок**: Предопределенные тайлы ошибок для различных HTTP статусов

### Фоновая загрузка

- **Сеточная стратегия**: Систематическое сканирование от минимального до максимального уровня зума
- **Дневные лимиты**: Настраиваемое ограничение запросов для соблюдения политик источников
- **Постоянство прогресса**: Возобновляемое сканирование после перезапуска сервиса
- **WAL Checkpointing**: Фоновое обслуживание SQLite для оптимальной производительности

## Структура файлов

```
src/
├── config.ru                 # Основное Sinatra приложение
├── background_tile_loader.rb  # Автоматизированная система предзагрузки тайлов
├── database_manager.rb       # Управление SQLite базой данных
├── metadata_manager.rb       # Определение формата тайлов и метаданные
├── view_helpers.rb           # Статистика панели и утилиты  
├── gost.rb                   # Поддержка криптографии ГОСТ
├── Gemfile                   # Ruby зависимости
├── configs/
│   └── tile-services.yaml   # Конфигурация сервиса
├── views/                    # Шаблоны веб-интерфейса
│   ├── index.slim           # Главная панель
│   ├── database.slim        # Браузер базы данных
│   ├── map.slim             # Интерактивная карта
│   └── layout.slim          # Базовый макет
├── assets/
│   └── error_tiles/         # Изображения тайлов ошибок
└── spec/                    # Набор тестов
```

## Разработка

### Предварительные требования

- Ruby 3.4+
- SQLite 3
- Bundler
- Docker (опционально)

### Настройка

```bash
# Установка зависимостей
bundle install

# Настройка конфигурации
cp configs/tile-services.yaml.example configs/tile-services.yaml

# Запуск тестов
bundle exec rspec

# Запуск сервера разработки
bundle exec rackup -p 7000

# Запуск с Falcon сервером (продакшн)
bundle exec rackup -s falcon -p 7000
```

### Тестирование

```bash
# Запуск всех тестов
bundle exec rspec

# Запуск с покрытием кода
COVERAGE=true bundle exec rspec

# Запуск интеграционных тестов
bundle exec rspec spec/integration_spec.rb
```

### Тестирование производительности

Сервис включает бенчмарк тесты для критических операций:

```bash
# Запуск бенчмарков производительности
bundle exec rspec spec/ --tag benchmark
```

## Развертывание

### Docker развертывание

```yaml
# docker-compose.yml
version: '3.8'
services:
  tiles-proxy-cache:
    build: 
      context: src
      dockerfile: ../docker/ruby/Dockerfile
    ports:
      - "7000:7000"
    volumes:
      - ./configs:/configs
      - ./data:/app/data
    environment:
      - RACK_ENV=production
      - RUBY_YJIT_ENABLE=1
    restart: unless-stopped
```

### Переменные окружения

- `RACK_ENV`: Режим окружения (development/production)
- `PORT`: Порт сервера (по умолчанию: 7000)
- `RUBY_YJIT_ENABLE`: Включить JIT компиляцию Ruby для лучшей производительности


## Мониторинг

### Возможности панели

Веб-интерфейс обеспечивает комплексный мониторинг:

- **Статистика сервиса**: Общие источники, кешированные тайлы, размер кеша, время работы
- **Метрики по источникам**: Попадания/промахи кеша, процент покрытия, размер базы данных
- **Визуализация покрытия**: D3.js графики, показывающие покрытие тайлов по уровням зума
- **Интерактивные карты**: Предварительный просмотр на основе MapLibre с метриками производительности
- **Браузер базы данных**: Прямая инспекция и запросы SQLite данных

## Вклад в проект

1. Форкните репозиторий
2. Создайте ветку функции (`git checkout -b feature/amazing-feature`)
3. Запустите тесты (`bundle exec rspec`)
4. Закоммитьте изменения (`git commit -m 'Add amazing feature'`)
5. Запушьте в ветку (`git push origin feature/amazing-feature`)
6. Откройте Pull Request

## Лицензия

Этот проект лицензирован под MIT License - смотрите файл [LICENSE](../../../LICENSE) для деталей.
