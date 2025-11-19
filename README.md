# Tiles Proxy Cache

A high-performance tile caching proxy service that provides intelligent tile caching, background preloading, and comprehensive monitoring for map tile services. The service acts as a middleware layer between map clients and tile providers, optimizing performance through local caching and automated tile management.

[![Ruby](https://img.shields.io/badge/ruby-3.4+-red.svg)](https://ruby-lang.org)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](docker/)
[![Sinatra](https://img.shields.io/badge/sinatra-web_framework-lightgrey.svg)](http://sinatrarb.com/)
[![Русский](https://img.shields.io/badge/русский-документация-orange.svg)](src/docs/ru/README_ru.md)

## Key Features

- **Tile Caching**: Local caching using SQLite with MBTiles schema for optimal performance
- **Background Tile Loading**: Automated preloading system with configurable scanning strategies and daily limits
- **Multi-Source Support**: Simultaneous caching from multiple tile providers (satellite, topographic, DEM data, LERC elevation data, etc.)
- **LERC Format Support**: Native support for ArcGIS LERC (Limited Error Raster Compression) format with automatic conversion to Mapbox Terrain-RGB PNG
- **DEM Data Processing**: Specialized handling of Digital Elevation Model data with support for Terrarium and Mapbox RGB encoding
- **Advanced Error Handling**: Intelligent miss tracking with customizable error tiles for different HTTP status codes
- **Interactive Web Interface**: Real-time statistics, coverage analysis, maplibre-preview integration for map preview
- **Performance Optimization**: WAL mode SQLite, connection pooling, memory-mapped I/O, and Ruby JIT compilation
- **GOST Cryptography**: Built-in support for GOST cryptographic algorithms for enhanced security
- **Docker Ready**: Containerized deployment with volume mounting for configuration and data persistence

## Architecture Overview

The service consists of several integrated components:

### Core Components

- **[Tile Proxy Engine](src/config.ru)** - Main Sinatra application handling tile requests with intelligent caching and LERC processing
- **[Background Tile Loader](src/background_tile_loader.rb)** - Automated tile preloading with configurable scanning strategies
- **[Database Manager](src/database_manager.rb)** - SQLite database optimization and MBTiles schema management
- **[Metadata Manager](src/metadata_manager.rb)** - Configurable or automatic format detection and metadata initialization
- **[LERC Extension](src/ext/lerc_extension.cpp)** - C++ extension for LERC format decoding and Mapbox Terrain-RGB conversion
- **[Monitoring Interface](src/views/)** - Web-based dashboard with maplibre-preview integration

### Data Flow

1. **Tile Request** → Cache check → Serve cached tile or fetch from upstream
2. **Cache Miss** → HTTP request to source → Process format (LERC conversion if needed) → Store in SQLite → Serve to client
3. **Background Scanning** → Systematic tile preloading based on zoom bounds
4. **Error Management** → Miss tracking with timeout and cleanup mechanisms
5. **LERC Processing** → Configurable conversion of LERC data to Mapbox Terrain-RGB PNG format

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

# DEM terrain service (Terrarium format)
DEM_Terrain:
  path: "/dem/:z/:x/:y"
  target: "https://example-dem.com/terrain/tiles/{z}/{y}/{x}.png"
  mbtiles_file: "dem_terrain.mbtiles"
  metadata:
    encoding: "terrarium"
    type: "overlay"
  autoscan: { enabled: false, daily_limit: 10000 }

# LERC elevation service
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
| `/api/stats` | GET | JSON statistics for all sources | JSON data |
| `/db?source=name` | GET | Database viewer for specific source | HTML table view |
| `/map?source=name` | GET | Map preview via maplibre-preview integration | HTML map interface |
| `/admin/vacuum` | GET | Database maintenance (VACUUM operation) | JSON status |
| `/{path}` | GET | MapLibre style for source | JSON style |

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
- **Manual VACUUM**: On-demand database maintenance for optimal performance

### Caching Strategy

- **Intelligent Miss Tracking**: Prevents repeated requests for missing tiles
- **Cleanup Mechanisms**: Automatic old data removal based on configured limits
- **Lock-based Concurrency**: Per-tile mutex to prevent duplicate requests
- **Error Tile Serving**: Pre-defined error tiles for different HTTP status codes
- **Format Detection**: Configurable or automatic detection of tile formats and metadata initialization

### Background Loading

- **Grid Strategy**: Systematic scanning from min to max zoom levels
- **Daily Limits**: Configurable request throttling to respect upstream policies
- **Progress Persistence**: Resumable scanning after service restarts
- **WAL Checkpointing**: Background SQLite maintenance for optimal performance

### LERC Processing

- **Native C++ Extension**: High-performance LERC decoding using Esri LERC library
- **Automatic Conversion**: Seamless conversion from LERC to Mapbox Terrain-RGB PNG
- **Memory Optimization**: Efficient memory management with RAII principles
- **Error Handling**: Comprehensive error handling for malformed LERC data

## File Structure

```
src/
├── config.ru                 # Main Sinatra application
├── background_tile_loader.rb  # Automated tile preloading system
├── database_manager.rb       # SQLite database management
├── metadata_manager.rb       # Tile format detection and metadata
├── view_helpers.rb           # Dashboard statistics and utilities
├── gost.conf                 # GOST cryptography configuration
├── Gemfile                   # Ruby dependencies
├── configs/
│   └── tile-services.yaml   # Service configuration
├── views/                    # Web interface templates
│   ├── index.slim           # Main dashboard
│   ├── database.slim        # Database browser
│   └── layout.slim          # Base layout
├── assets/
│   └── error_tiles/         # Error tile images
├── ext/                      # C++ extensions
│   ├── lerc_extension.cpp   # LERC format processing
│   ├── extconf.rb           # Extension configuration
│   └── stb_image_write.h    # Image writing library
├── docs/                     # Documentation
│   ├── en/                  # English documentation
│   └── ru/                  # Russian documentation
└── spec/                    # Test suite
```

## Development

### Prerequisites

- Ruby 3.4+
- SQLite 3
- Bundler
- C++ compiler with C++23 support
- LERC library (v4.0.0)
- Docker (optional)

### Setup

```bash
# Install dependencies
bundle install

# Build C++ extensions
cd ext && ruby extconf.rb && make

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
- **Interactive Maps**: MapLibre-based preview via maplibre-preview gem integration
- **Database Browser**: Direct SQLite data inspection and querying with VACUUM operations
- **Performance Monitoring**: Real-time FPS, memory usage, and tile loading metrics
- **Layer Management**: Dynamic layer visibility controls and filter systems
- **Terrain Analysis**: Elevation tooltips and interactive elevation profile generation

## LERC Format Support

The service includes native support for ArcGIS LERC (Limited Error Raster Compression) format, commonly used for elevation data:

### Features

- **Configurable Processing**: LERC format processing is enabled via `source_format: "lerc"` configuration
- **Native Conversion**: C++ extension converts LERC data to Mapbox Terrain-RGB PNG format
- **High Performance**: Optimized C++ implementation with aggressive compiler optimizations
- **Memory Efficient**: RAII-based memory management with automatic cleanup
- **Error Handling**: Comprehensive error handling for malformed or corrupted LERC data

### Configuration

```yaml
LERC_Elevation:
  path: "/lerc/:z/:x/:y"
  target: "https://example-lerc.com/elevation/tiles/{z}/{y}/{x}"
  source_format: "lerc"  # Enable LERC processing
  mbtiles_file: "lerc_elevation.mbtiles"
  metadata:
    encoding: "mapbox"   # Output format for MapLibre compatibility
    type: "overlay"
```

### Technical Details

- **LERC Library**: Uses Esri LERC v4.0.0 for decoding
- **Encoding**: Converts to Mapbox Terrain-RGB with 0.1m precision
- **Height Range**: Supports elevations from -10,000m to +16,777,215m
- **Performance**: Optimized with `-O3`, `-march=native`, and `-flto` compiler flags

For detailed technical documentation, see [LERC Extension Documentation](src/docs/en/lerc_extension.md).

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`bundle exec rspec`)
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
