class Filters {
    constructor(options) {
        this.map = options.map;
        this.container = options.container;
        this.element_template = options.element_template || (title => `<div class="element">${title}</div>`);
        this.group_template = options.group_template || (title => `<div class="group">${title}</div>`);

        this.filterStates = {};
        this.subFilterStatesBeforeGroupToggle = {};
        this.currentStyle = null;
        this.currentMode = 'filters';
        this.isUpdating = false;
    }

    init() {
        if (!this.map) return;
        try {
            this.currentStyle = this.map.getStyle();
            if (this.currentStyle) {
                this.createFilterButtons();
                this.applyFilterMode();
            }
        } catch (e) {
            console.warn('Could not get style for filters:', e);
        }
    }

    setMode(mode) {
        this.currentMode = mode;
        if (mode === 'filters') {
            this.applyFilterMode();
        }
    }

    getLocalizedFilterName(locale, filterId) {
        if (!locale) return filterId;
        const languagePriority = ['en-US', 'en', 'ru'];

        for (const lang of languagePriority) {
            if (locale[lang]?.[filterId]) return locale[lang][filterId];
        }

        for (const lang in locale) {
            if (locale[lang]?.[filterId]) return locale[lang][filterId];
        }

        return filterId;
    }

    applyFilterMode() {
        if (this.isUpdating) return;
        this.isUpdating = true;

        try {
            this.currentStyle?.layers?.forEach(layer => {
                if (this.map.getLayer(layer.id)) {
                    this.map.setLayoutProperty(layer.id, 'visibility', 'visible');
                }
            });

            this.currentStyle?.metadata?.filters && Object.keys(this.currentStyle.metadata.filters).forEach(filterId => {
                this.applyFilter(filterId, this.filterStates[filterId] || false);
            });
        } finally {
            this.isUpdating = false;
        }
    }

    applyFilter(filterId, isActive) {
        if (this.currentMode !== 'filters' || !this.currentStyle?.metadata?.filters || this.isUpdating) return;

        const filterConfig = this.currentStyle.metadata.filters[filterId];
        if (!filterConfig) return;

        const hasMapboxFilters = filterConfig.some(filter => filter.filter);
        hasMapboxFilters ? this.applyLevel2Filter(filterId, isActive, filterConfig) : this.applyLevel1Filter(filterId, isActive, filterConfig);
    }

    applyLevel1Filter(filterId, isActive, filterConfig) {
        this.currentStyle.layers.forEach(layer => {
            if (!layer.metadata?.filter_id) return;

            const matchingFilter = filterConfig.find(filter => filter.id === layer.metadata.filter_id);
            if (matchingFilter) {
                if (filterConfig.length > 1) {
                    const subFilterKey = `${filterId}_${layer.metadata.filter_id}`;
                    const subFilterActive = this.filterStates[subFilterKey];
                    const visibility = (isActive && subFilterActive) ? 'visible' : 'none';
                    this.map.getLayer(layer.id) && this.map.setLayoutProperty(layer.id, 'visibility', visibility);
                } else {
                    this.map.getLayer(layer.id) && this.map.setLayoutProperty(layer.id, 'visibility', isActive ? 'visible' : 'none');
                }
            } else if (layer.metadata.filter_id === filterId) {
                this.map.getLayer(layer.id) && this.map.setLayoutProperty(layer.id, 'visibility', isActive ? 'visible' : 'none');
            }
        });
    }

    applyLevel2Filter(filterId, isActive, filterConfig) {
        const subFiltersWithExpr = filterConfig.filter(f => !!f.filter);
        const subFiltersWithoutExpr = filterConfig.filter(f => !f.filter);

        const generalLayers = this.currentStyle.layers.filter(layer => layer.metadata?.filter_id === filterId);
        const childLayersBySubId = {};

        filterConfig.forEach(f => {
            childLayersBySubId[f.id] = this.currentStyle.layers
                .filter(layer => layer.metadata?.filter_id === f.id)
                .map(l => l.id);
        });

        const hasGeneralLayers = generalLayers.length > 0 && subFiltersWithExpr.length > 0;
        const hasChildLayers = Object.values(childLayersBySubId).some(arr => arr?.length > 0);

        if (!isActive) {
            if (hasGeneralLayers) {
                generalLayers.forEach(layer => {
                    if (this.map.getLayer(layer.id)) {
                        this.map.setLayoutProperty(layer.id, 'visibility', 'none');
                        this.map.setFilter(layer.id, null);
                    }
                });
            }
            if (hasChildLayers) {
                Object.values(childLayersBySubId).forEach(ids => {
                    ids.forEach(id => this.map.getLayer(id) && this.map.setLayoutProperty(id, 'visibility', 'none'));
                });
            }
            return;
        }

        if (hasGeneralLayers) {
            const activeWithExpr = subFiltersWithExpr.filter(f => this.filterStates[`${filterId}_${f.id}`] !== false);

            if (activeWithExpr.length === 0) {
                generalLayers.forEach(layer => {
                    if (this.map.getLayer(layer.id)) {
                        this.map.setLayoutProperty(layer.id, 'visibility', 'none');
                        this.map.setFilter(layer.id, null);
                    }
                });
            } else if (activeWithExpr.length === 1) {
                const expr = activeWithExpr[0].filter;
                generalLayers.forEach(layer => {
                    if (this.map.getLayer(layer.id)) {
                        this.map.setLayoutProperty(layer.id, 'visibility', 'visible');
                        this.map.setFilter(layer.id, expr);
                    }
                });
            } else {
                const exprs = activeWithExpr.map(f => f.filter);
                const combined = ['any', ...exprs];
                generalLayers.forEach(layer => {
                    if (this.map.getLayer(layer.id)) {
                        this.map.setLayoutProperty(layer.id, 'visibility', 'visible');
                        this.map.setFilter(layer.id, combined);
                    }
                });
            }
        }

        if (hasChildLayers) {
            filterConfig.forEach(sf => {
                const ids = childLayersBySubId[sf.id] || [];
                if (!ids.length) return;
                const subKey = `${filterId}_${sf.id}`;
                const on = (this.filterStates[subKey] !== false) && isActive;
                ids.forEach(id => this.map.getLayer(id) && this.map.setLayoutProperty(id, 'visibility', on ? 'visible' : 'none'));
            });
        }
    }

    toggleAllFilters() {
        if (this.currentMode !== 'filters' || !this.currentStyle?.metadata?.filters) return;

        const allActive = Object.values(this.filterStates).every(state => state);
        const newState = !allActive;

        Object.keys(this.subFilterStatesBeforeGroupToggle).forEach(k => delete this.subFilterStatesBeforeGroupToggle[k]);
        Object.keys(this.currentStyle.metadata.filters).forEach(filterId => {
            const filterConfig = this.currentStyle.metadata.filters[filterId];

            if (filterConfig?.length > 1) {
                filterConfig.forEach(item => {
                    this.filterStates[`${filterId}_${item.id}`] = newState;
                });
            }

            this.filterStates[filterId] = newState;
            this.applyFilter(filterId, newState);
        });

        this.updateFilterButtons();
    }

    toggleFilterGroup(filterId) {
        if (this.currentMode !== 'filters') return;

        const filterConfig = this.currentStyle.metadata.filters[filterId];
        const isCurrentlyActive = this.filterStates[filterId];

        if (isCurrentlyActive) {
            if (filterConfig?.length > 1) {
                this.subFilterStatesBeforeGroupToggle[filterId] = {};
                filterConfig.forEach(item => {
                    const subFilterKey = `${filterId}_${item.id}`;
                    this.subFilterStatesBeforeGroupToggle[filterId][item.id] = this.filterStates[subFilterKey];
                    this.filterStates[subFilterKey] = false;
                });
            }
            this.filterStates[filterId] = false;
            this.applyFilter(filterId, false);
        } else {
            if (filterConfig?.length > 1) {
                const saved = this.subFilterStatesBeforeGroupToggle[filterId];
                const anyUserSelectionWhileOff = filterConfig.some(item => this.filterStates[`${filterId}_${item.id}`]);
                if (!anyUserSelectionWhileOff) {
                    filterConfig.forEach(item => {
                        const subFilterKey = `${filterId}_${item.id}`;
                        this.filterStates[subFilterKey] = saved?.[item.id] ?? true;
                    });
                }
                delete this.subFilterStatesBeforeGroupToggle[filterId];
            }
            this.filterStates[filterId] = true;
            this.applyFilter(filterId, true);
        }

        this.updateFilterButtons();
    }

    toggleSubFilter(groupId, subFilterId) {
        if (this.currentMode !== 'filters') return;
        const subFilterKey = `${groupId}_${subFilterId}`;
        this.filterStates[subFilterKey] = !this.filterStates[subFilterKey];

        const filterConfig = this.currentStyle.metadata.filters[groupId];
        if (filterConfig?.length > 1) {
            const activeSubFilters = filterConfig.filter(item => this.filterStates[`${groupId}_${item.id}`]);
            this.filterStates[groupId] = activeSubFilters.length > 0;
        }

        this.applyFilter(groupId, !!this.filterStates[groupId]);
        this.updateFilterButtons();
    }

    updateFilterButtons() {
        if (!this.currentStyle?.metadata?.filters) return;

        Object.keys(this.currentStyle.metadata.filters).forEach(filterId => {
            const groupButton = document.getElementById(`filter-${filterId}`);
            groupButton && (groupButton.className = `control-button ${this.filterStates[filterId] ? 'active' : 'inactive'} filter-group-button`);

            const subButton = document.getElementById(`filter-sub-${filterId}`);
            subButton?.querySelectorAll('.filter-sub-button').forEach(btn => {
                const subFilterId = btn.id.replace(`filter-sub-${filterId}-`, '');
                const subFilterKey = `${filterId}_${subFilterId}`;
                btn.className = `control-button ${this.filterStates[subFilterKey] ? 'active' : 'inactive'} filter-sub-button`;
            });
        });
    }

    createFilterButtons() {
        if (!this.currentStyle?.metadata?.filters) return;

        const filterButtonsContainer = document.getElementById('filter-buttons');
        if (!filterButtonsContainer) return;

        const savedStates = {...this.filterStates};

        Object.keys(this.currentStyle.metadata.filters).forEach(filterId => {
            const filterConfig = this.currentStyle.metadata.filters[filterId];
            const locale = this.getLocalizedFilterName(this.currentStyle.metadata.locale, filterId);

            const groupContainer = document.createElement('div');
            groupContainer.className = 'filter-group';
            groupContainer.id = `filter-group-${filterId}`;

            const groupButton = document.createElement('button');
            groupButton.id = `filter-${filterId}`;
            groupButton.className = 'control-button active filter-group-button';
            groupButton.textContent = locale;
            groupButton.onclick = () => this.toggleFilterGroup(filterId);
            groupContainer.appendChild(groupButton);

            if (filterConfig.length > 1) {
                const subButtonsContainer = document.createElement('div');
                subButtonsContainer.className = 'filter-sub-buttons';
                subButtonsContainer.id = `filter-sub-${filterId}`;

                filterConfig.forEach(item => {
                    const subButton = document.createElement('button');
                    subButton.id = `filter-sub-${filterId}-${item.id}`;
                    subButton.className = 'control-button active filter-sub-button';
                    const subLocale = this.getLocalizedFilterName(this.currentStyle.metadata.locale, item.id);
                    subButton.textContent = subLocale || item.id;
                    subButton.onclick = () => this.toggleSubFilter(filterId, item.id);
                    subButtonsContainer.appendChild(subButton);

                    const subFilterKey = `${filterId}_${item.id}`;
                    this.filterStates[subFilterKey] = savedStates[subFilterKey] ?? true;
                });

                groupContainer.appendChild(subButtonsContainer);
            }

            filterButtonsContainer.appendChild(groupContainer);

            this.filterStates[filterId] = savedStates[filterId] ?? true;
        });

        this.updateFilterButtons();
    }

    applyAllFilters() {
        this.currentStyle?.metadata?.filters && Object.keys(this.currentStyle.metadata.filters).forEach(filterId => {
            this.applyFilter(filterId, this.filterStates[filterId] || false);
        });
    }
}