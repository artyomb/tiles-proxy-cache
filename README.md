# Tiles Proxy Cache

A high-performance tile caching proxy service that provides intelligent tile caching, background preloading, and comprehensive monitoring for map tile services. The service acts as a middleware layer between map clients and tile providers, optimizing performance through local caching and automated tile management.

[![Ruby](https://img.shields.io/badge/ruby-3.4+-red.svg)](https://ruby-lang.org)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](docker/)
[![Sinatra](https://img.shields.io/badge/sinatra-web_framework-lightgrey.svg)](http://sinatrarb.com/)
[![Русский](https://img.shields.io/badge/русский-документация-orange.svg)](src/docs/ru/README_ru.md)

## Key Features

- **Tile Caching**: Local caching using SQLite with MBTiles schema for optimal performance
- **Background Tile Loading**: Automated preloading system with configurable scanning strategies and daily limits
- **Multi-Source Support**: Simultaneous caching from multiple tile providers (satellite, topographic, vector tiles, etc.)
- **Error Handling**: Advanced miss tracking with customizable error tiles for different HTTP status codes
- **Web Monitoring Interface**: Real-time statistics, coverage analysis, and interactive map preview
- **Performance Optimization**: WAL mode SQLite, connection pooling, and memory-mapped I/O
- **Docker Ready**: Containerized deployment with volume mounting for configuration and data persistence

## Architecture Overview

The service consists of several integrated components:

### Core Components

- **[Tile Proxy Engine](src/config.ru)** - Main Sinatra application handling tile requests with intelligent caching
- **[Background Tile Loader](src/background_tile_loader.rb)** - Automated tile preloading with configurable scanning strategies
- **[Database Manager](src/database_manager.rb)** - SQLite database optimization and MBTiles schema management
- **[Metadata Manager](src/metadata_manager.rb)** - Automatic format detection and metadata initialization
- **[Monitoring Interface](src/views/)** - Web-based dashboard for statistics and map preview

### Data Flow

1. **Tile Request** → Cache check → Serve cached tile or fetch from upstream
2. **Cache Miss** → HTTP request to source → Store in SQLite → Serve to client
3. **Background Scanning** → Systematic tile preloading based on zoom bounds
4. **Error Management** → Miss tracking with timeout and cleanup mechanisms

## Quick Start

### Using Docker

```bash
# Create configuration file
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

# Run with Docker
docker run --rm \
  -v $(pwd)/tile-services.yaml:/configs/tile-services.yaml \
  -v $(pwd)/tiles_data:/app \
  -p 7000:7000 \
  tiles-proxy-cache

# Access the service
open http://localhost:7000
```

### Local Development

```bash
# Clone repository
git clone <repository-url>
cd tiles-proxy-cache

# Install dependencies
cd src && bundle install

# Configure tile services
cp configs/tile-services.yaml.example configs/tile-services.yaml

# Start development server
bundle exec rackup -p 7000

# Run tests
bundle exec rspec
```

## Configuration

The service uses YAML configuration files to define tile sources and caching behavior:

```yaml
# configs/tile-services.yaml
Source_Name:
  path: "/tiles/:z/:x/:y"                           # URL pattern for serving tiles
  target: "https://example.com/tiles/{z}/{x}/{y}"   # Upstream tile server URL
  minzoom: 1                                        # Minimum zoom level
  maxzoom: 20                                       # Maximum zoom level
  miss_timeout: 300                                 # Seconds to cache error responses
  miss_max_records: 10000                           # Maximum error records before cleanup
  mbtiles_file: "tiles.mbtiles"                     # SQLite database filename
  
  # Request/Response headers configuration
  headers:
    request:
      User-Agent: "TilesProxyCache/1.0"
      Referer: "https://example.com"
    response:
      Cache-Control:
        max-age:
          hit: 86400    # 24 hours for cache hits
          miss: 300     # 5 minutes for cache misses
  
  # Metadata for MapBox/MapLibre compatibility
  metadata:
    bounds: "-180,-85.0511,180,85.0511"             # Geographic bounds
    center: "0,0,2"                                 # Default center and zoom
    type: "baselayer"                               # Layer type (baselayer|overlay)
  
  # Background tile preloading
  autoscan:
    enabled: true                                   # Enable background scanning
    daily_limit: 30000                             # Maximum tiles per day
    max_scan_zoom: 12                               # Maximum zoom level to scan
    strategy: "grid"                                # Scanning strategy
```

### Multiple Sources Example

```yaml
# Satellite imagery service
World_Imagery:
  path: "/wi/:z/:x/:y"
  target: "https://example-satellite.com/imagery/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "world_imagery.mbtiles"
  autoscan: { enabled: false, daily_limit: 5000 }

# Topographic map service
Topographic:
  path: "/topo/:z/:x/:y"
  target: "https://example-topo.com/maps/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "topographic.mbtiles"
  headers:
    response:
      Cache-Control:
        max-age:
          hit: 604800     # 7 days
          miss: 3600      # 1 hour

# Open source map service
OSM:
  path: "/osm/:z/:x/:y"
  target: "https://example-osm.org/tiles/{z}/{x}/{y}.png"
  mbtiles_file: "openstreetmap.mbtiles"
  autoscan: { enabled: true, daily_limit: 10000, strategy: "grid" }
```

## API Reference

### Tile Endpoints

| Endpoint | Method | Description | Response |
|----------|--------|-------------|----------|
| `/{path}/:z/:x/:y` | GET | Retrieve map tile | Binary tile data |
| `/{path}` | GET | Get Mapbox style JSON | JSON style definition |

### Management Endpoints

| Endpoint | Method | Description | Response |
|----------|--------|-------------|----------|
| `/` | GET | Dashboard with service statistics | HTML interface |
| `/db?source=name` | GET | Database viewer for specific source | HTML table view |
| `/map?source=name` | GET | Interactive map preview | HTML map interface |
| `/map/style?source=name` | GET | MapLibre style for source | JSON style |

### Response Headers

All tile responses include cache status headers:

```http
Cache-Control: public, max-age=86400
X-Cache-Status: HIT|MISS|ERROR
Content-Type: image/png|image/jpeg|image/webp
```

## Database Schema

Each tile source uses an SQLite database with MBTiles-compatible schema:

### Tables

**tiles** - Cached tile data
```sql
CREATE TABLE tiles (
  zoom_level INTEGER NOT NULL,
  tile_column INTEGER NOT NULL,
  tile_row INTEGER NOT NULL,
  tile_data BLOB NOT NULL,
  UNIQUE (zoom_level, tile_column, tile_row)
);
```

**metadata** - Source metadata
```sql
CREATE TABLE metadata (
  name TEXT NOT NULL,
  value TEXT
);
```

**misses** - Error tracking
```sql
CREATE TABLE misses (
  z INTEGER, x INTEGER, y INTEGER, 
  ts INTEGER, reason TEXT, details TEXT,
  status INTEGER, response_body BLOB
);
```

**tile_scan_progress** - Background scanning state
```sql
CREATE TABLE tile_scan_progress (
  source TEXT NOT NULL,
  zoom_level INTEGER NOT NULL,
  last_x INTEGER DEFAULT 0,
  last_y INTEGER DEFAULT 0,
  status TEXT DEFAULT 'waiting'
);
```

## Performance Features

### SQLite Optimizations

- **WAL Mode**: Write-Ahead Logging for concurrent read/write operations
- **Memory Mapping**: 512MB mmap_size for faster file access
- **Connection Pooling**: Up to 8 concurrent connections per source
- **Optimized Pragmas**: Tuned for tile caching workloads

### Caching Strategy

- **Intelligent Miss Tracking**: Prevents repeated requests for missing tiles
- **Cleanup Mechanisms**: Automatic old data removal based on configured limits
- **Lock-based Concurrency**: Per-tile mutex to prevent duplicate requests
- **Error Tile Serving**: Pre-defined error tiles for different HTTP status codes

### Background Loading

- **Grid Strategy**: Systematic scanning from min to max zoom levels
- **Daily Limits**: Configurable request throttling to respect upstream policies
- **Progress Persistence**: Resumable scanning after service restarts
- **WAL Checkpointing**: Background SQLite maintenance for optimal performance

## File Structure

```
src/
├── config.ru                 # Main Sinatra application
├── background_tile_loader.rb  # Automated tile preloading system
├── database_manager.rb       # SQLite database management
├── metadata_manager.rb       # Tile format detection and metadata
├── view_helpers.rb           # Dashboard statistics and utilities  
├── gost.rb                   # GOST cryptographic support
├── Gemfile                   # Ruby dependencies
├── configs/
│   └── tile-services.yaml   # Service configuration
├── views/                    # Web interface templates
│   ├── index.slim           # Main dashboard
│   ├── database.slim        # Database browser
│   ├── map.slim             # Interactive map
│   └── layout.slim          # Base layout
├── assets/
│   └── error_tiles/         # Error tile images
└── spec/                    # Test suite
```

## Development

### Prerequisites

- Ruby 3.4+
- SQLite 3
- Bundler
- Docker (optional)

### Setup

```bash
# Install dependencies
bundle install

# Set up configuration
cp configs/tile-services.yaml.example configs/tile-services.yaml

# Run tests
bundle exec rspec

# Start development server
bundle exec rackup -p 7000

# Run with Falcon server (production)
bundle exec rackup -s falcon -p 7000
```

### Testing

```bash
# Run all tests
bundle exec rspec

# Run with coverage
COVERAGE=true bundle exec rspec

# Run integration tests
bundle exec rspec spec/integration_spec.rb
```

### Performance Testing

The service includes benchmark tests for critical operations:

```bash
# Run performance benchmarks
bundle exec rspec spec/ --tag benchmark
```

## Deployment

### Docker Deployment

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

### Environment Variables

- `RACK_ENV`: Environment mode (development/production)
- `PORT`: Server port (default: 7000)
- `RUBY_YJIT_ENABLE`: Enable Ruby JIT compilation for better performance




## Monitoring

### Dashboard Features

The web interface provides comprehensive monitoring:

- **Service Statistics**: Total sources, cached tiles, cache size, uptime
- **Per-Source Metrics**: Cache hits/misses, coverage percentage, database size
- **Coverage Visualization**: D3.js charts showing tile coverage per zoom level
- **Interactive Maps**: MapLibre-based preview with performance metrics
- **Database Browser**: Direct SQLite data inspection and querying

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`bundle exec rspec`)
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
