# Tiles Proxy Cache

Высокопроизводительный сервис кеширования тайлов карт с интеллектуальным кешированием, фоновой предзагрузкой и комплексным мониторингом. Сервис работает как промежуточный слой между клиентами карт и провайдерами тайлов, оптимизируя производительность через локальное кеширование и автоматизированное управление тайлами.

[![Ruby](https://img.shields.io/badge/ruby-3.4+-red.svg)](https://ruby-lang.org)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](../../docker/)
[![Sinatra](https://img.shields.io/badge/sinatra-web_framework-lightgrey.svg)](http://sinatrarb.com/)
[![English](https://img.shields.io/badge/english-documentation-blue.svg)](../../../README.md)

## Основные возможности

- **Кеширование тайлов**: Локальное кеширование с использованием SQLite и схемы MBTiles для оптимальной производительности
- **Фоновая загрузка тайлов**: Автоматизированная система предзагрузки с настраиваемыми стратегиями сканирования и дневными лимитами
- **Поддержка множества источников**: Одновременное кеширование из различных провайдеров тайлов (спутниковые, топографические, DEM данные, LERC данные высот и др.)
- **Поддержка формата LERC**: Нативная поддержка ArcGIS LERC (Limited Error Raster Compression) с автоматической конвертацией в Mapbox Terrain-RGB PNG
- **Обработка DEM данных**: Специализированная обработка цифровых моделей рельефа с поддержкой кодирования Terrarium и Mapbox RGB
- **Продвинутая обработка ошибок**: Интеллектуальное отслеживание промахов с настраиваемыми тайлами ошибок для различных HTTP статусов
- **Интерактивный веб-интерфейс**: Статистика в реальном времени, анализ покрытия, интеграция с maplibre-preview для предварительного просмотра карт
- **Оптимизация производительности**: SQLite в режиме WAL, пулинг соединений, файловый ввод-вывод с отображением в память и JIT компиляция Ruby
- **Криптография GOST**: Встроенная поддержка криптографических алгоритмов GOST для повышенной безопасности
- **Готов к Docker**: Контейнеризованное развертывание с монтированием томов для конфигурации и постоянства данных

## Обзор архитектуры

Сервис состоит из нескольких интегрированных компонентов:

### Основные компоненты

- **[Движок прокси тайлов](../../config.ru)** - Основное Sinatra приложение для обработки запросов тайлов с интеллектуальным кешированием и обработкой LERC
- **[Фоновый загрузчик тайлов](../../background_tile_loader.rb)** - Автоматическая предзагрузка тайлов с настраиваемыми стратегиями сканирования
- **[Менеджер базы данных](../../database_manager.rb)** - Оптимизация SQLite базы данных и управление схемой MBTiles
- **[Менеджер метаданных](../../metadata_manager.rb)** - Настраиваемое или автоматическое определение формата и инициализация метаданных
- **[LERC расширение](../../ext/lerc_extension.cpp)** - C++ расширение для декодирования формата LERC и конвертации в Mapbox Terrain-RGB
- **[Интерфейс мониторинга](../../views/)** - Веб-панель с интеграцией maplibre-preview для предварительного просмотра карт

### Поток данных

1. **Запрос тайла** → Проверка кеша → Выдача кешированного тайла или получение из источника
2. **Промах кеша** → HTTP запрос к источнику → Обработка формата (конвертация LERC при необходимости) → Сохранение в SQLite → Выдача клиенту
3. **Фоновое сканирование** → Систематическая предзагрузка тайлов на основе границ зума
4. **Управление ошибками** → Отслеживание промахов с механизмами тайм-аута и очистки
5. **Обработка LERC** → Настраиваемая конвертация LERC данных в формат Mapbox Terrain-RGB PNG

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

# DEM сервис рельефа (формат Terrarium)
DEM_Terrain:
  path: "/dem/:z/:x/:y"
  target: "https://example-dem.com/terrain/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "dem_terrain.mbtiles"
  metadata:
    encoding: "terrarium"
    type: "overlay"
  autoscan: { enabled: false, daily_limit: 10000 }

# LERC сервис высот
LERC_Elevation:
  path: "/lerc/:z/:x/:y"
  target: "https://example-lerc.com/elevation/tiles/{z}/{y}/{x}"
  source_format: "lerc"
  mbtiles_file: "lerc_elevation.mbtiles"
  metadata:
    encoding: "mapbox"
    type: "overlay"
  autoscan: { enabled: false, daily_limit: 5000 }
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
| `/api/stats` | GET | JSON статистика для всех источников | JSON данные |
| `/db?source=name` | GET | Просмотрщик базы данных для конкретного источника | HTML табличное представление |
| `/map?source=name` | GET | Предварительный просмотр карты через maplibre-preview | HTML интерфейс карты |
| `/admin/vacuum` | GET | Обслуживание базы данных (операция VACUUM) | JSON статус |
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
- **Ручной VACUUM**: Обслуживание базы данных по запросу для оптимальной производительности

### Стратегия кеширования

- **Интеллектуальное отслеживание промахов**: Предотвращает повторные запросы отсутствующих тайлов
- **Механизмы очистки**: Автоматическое удаление старых данных на основе настроенных лимитов
- **Блокировочная конкурентность**: Per-tile mutex для предотвращения дублирующих запросов
- **Выдача тайлов ошибок**: Предопределенные тайлы ошибок для различных HTTP статусов
- **Определение формата**: Настраиваемое или автоматическое определение форматов тайлов и инициализация метаданных

### Фоновая загрузка

- **Сеточная стратегия**: Систематическое сканирование от минимального до максимального уровня зума
- **Дневные лимиты**: Настраиваемое ограничение запросов для соблюдения политик источников
- **Постоянство прогресса**: Возобновляемое сканирование после перезапуска сервиса
- **WAL Checkpointing**: Фоновое обслуживание SQLite для оптимальной производительности

### Обработка LERC

- **Нативное C++ расширение**: Высокопроизводительное декодирование LERC с использованием библиотеки Esri LERC
- **Автоматическая конвертация**: Бесшовная конвертация из LERC в Mapbox Terrain-RGB PNG
- **Оптимизация памяти**: Эффективное управление памятью с принципами RAII
- **Обработка ошибок**: Комплексная обработка ошибок для поврежденных LERC данных

## Структура файлов

```
src/
├── config.ru                 # Основное Sinatra приложение
├── background_tile_loader.rb  # Автоматизированная система предзагрузки тайлов
├── database_manager.rb       # Управление SQLite базой данных
├── metadata_manager.rb       # Определение формата тайлов и метаданные
├── view_helpers.rb           # Статистика панели и утилиты
├── gost.conf                 # Конфигурация криптографии GOST
├── Gemfile                   # Ruby зависимости
├── configs/
│   └── tile-services.yaml   # Конфигурация сервиса
├── views/                    # Шаблоны веб-интерфейса
│   ├── index.slim           # Главная панель
│   ├── database.slim        # Браузер базы данных
│   └── layout.slim          # Базовый макет
├── assets/
│   └── error_tiles/         # Изображения тайлов ошибок
├── ext/                      # C++ расширения
│   ├── lerc_extension.cpp   # Обработка формата LERC
│   ├── extconf.rb           # Конфигурация расширения
│   └── stb_image_write.h    # Библиотека записи изображений
├── docs/                     # Документация
│   ├── en/                  # Английская документация
│   └── ru/                  # Русская документация
└── spec/                    # Набор тестов
```

## Разработка

### Предварительные требования

- Ruby 3.4+
- SQLite 3
- Bundler
- C++ компилятор с поддержкой C++23
- Библиотека LERC (v4.0.0)
- Docker (опционально)

### Настройка

```bash
# Установка зависимостей
bundle install

# Сборка C++ расширений
cd ext && ruby extconf.rb && make

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
- **Интерактивные карты**: Предварительный просмотр через интеграцию с maplibre-preview гемом
- **Браузер базы данных**: Прямая инспекция и запросы SQLite данных с операциями VACUUM
- **Мониторинг производительности**: Мониторинг FPS, использования памяти и загрузки тайлов в реальном времени
- **Управление слоями**: Динамические элементы управления видимостью слоев и системы фильтров
- **Анализ рельефа**: Всплывающие подсказки с высотами и интерактивная генерация профилей высот

## Поддержка формата LERC

Сервис включает нативную поддержку формата ArcGIS LERC (Limited Error Raster Compression), обычно используемого для данных о высотах:

### Возможности

- **Настраиваемая обработка**: Обработка формата LERC включается через конфигурацию `source_format: "lerc"`
- **Нативная конвертация**: C++ расширение конвертирует LERC данные в формат Mapbox Terrain-RGB PNG
- **Высокая производительность**: Оптимизированная C++ реализация с агрессивными оптимизациями компилятора
- **Эффективность памяти**: Управление памятью на основе RAII с автоматической очисткой
- **Обработка ошибок**: Комплексная обработка ошибок для поврежденных или некорректных LERC данных

### Конфигурация

```yaml
LERC_Elevation:
  path: "/lerc/:z/:x/:y"
  target: "https://example-lerc.com/elevation/tiles/{z}/{y}/{x}"
  source_format: "lerc"  # Включить обработку LERC
  mbtiles_file: "lerc_elevation.mbtiles"
  metadata:
    encoding: "mapbox"   # Формат вывода для совместимости с MapLibre
    type: "overlay"
```

### Технические детали

- **Библиотека LERC**: Использует Esri LERC v4.0.0 для декодирования
- **Кодирование**: Конвертирует в Mapbox Terrain-RGB с точностью 0.1м
- **Диапазон высот**: Поддерживает высоты от -10,000м до +16,777,215м
- **Производительность**: Оптимизировано флагами компилятора `-O3`, `-march=native` и `-flto`

Для подробной технической документации см. [Документацию LERC расширения](lerc_extension.md).

## Вклад в проект

1. Форкните репозиторий
2. Создайте ветку функции (`git checkout -b feature/amazing-feature`)
3. Запустите тесты (`bundle exec rspec`)
4. Закоммитьте изменения (`git commit -m 'Add amazing feature'`)
5. Запушьте в ветку (`git push origin feature/amazing-feature`)
6. Откройте Pull Request

## Лицензия

Этот проект лицензирован под MIT License - смотрите файл [LICENSE](../../../LICENSE) для деталей.
