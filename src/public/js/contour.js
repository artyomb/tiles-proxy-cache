class ContourManager {
    constructor(options) {
        this.map = options.map;
        this.currentStyle = null;
        this.demSource = null;
    }

    init() {
        if (!this.map || !window.mlcontour) return;
        
        try {
            this.currentStyle = this.map.getStyle();
            if (this.currentStyle?.terrain) {
                this.initializeDemSource();
            }
        } catch (e) {
            console.warn('Contour initialization failed:', e);
        }
    }

    initializeDemSource() {
        if (!this.currentStyle?.terrain || !window.mlcontour) return;
        
        try {
            const terrainSourceName = this.currentStyle.terrain.source;
            const terrainSource = this.currentStyle.sources[terrainSourceName];
            
            if (!terrainSource || terrainSource.type !== 'raster-dem') return;
            
            this.demSource = new mlcontour.DemSource({
                url: terrainSource.tiles[0],
                encoding: terrainSource.encoding || 'terrarium', // "mapbox" or "terrarium"
                maxzoom: terrainSource.maxzoom || 15,
                worker: true, // offload isoline computation to a web worker
                cacheSize: 100, // number of most-recent tiles to cache
                timeoutMs: 10_000 // timeout on fetch requests
            });
            
            this.demSource.setupMaplibre(maplibregl);
            
            this.updateContourSource(terrainSourceName);
            
            console.log('DemSource initialized for contours');
        } catch (e) {
            console.warn('DemSource initialization failed:', e);
        }
    }

    updateContourSource(terrainSourceName) {
        const contourSourceName = `${terrainSourceName}_contours`;
        
        if (this.map.getSource(contourSourceName)) {
            const contourProtocolUrl = this.demSource.contourProtocolUrl({
                multiplier: 1,
                thresholds: {
                    // zoom: [minor, major]
                    11: [200, 1000],
                    12: [100, 500],
                    14: [50, 200],
                    15: [20, 100]
                },
                contourLayer: 'contours',
                elevationKey: 'ele',
                levelKey: 'level',
                extent: 4096,
                buffer: 1
            });
            
            this.map.getSource(contourSourceName).setTiles([contourProtocolUrl]);
        }
    }

    updateStyle(newStyle) {
        this.currentStyle = newStyle;
        if (newStyle?.terrain) {
            this.initializeDemSource();
        }
    }

    cleanup() {
        if (this.demSource) {
            this.demSource = null;
        }
    }
}
