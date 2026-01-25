---
layout: page
title: Liste des avions
lang: fr
permalink: /fr/aircraft/
---

<style>
.aircraft-list-container {
    max-width: 1200px;
    margin: 0 auto;
}

.aircraft-filters {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    margin-bottom: 24px;
    padding: 16px;
    background: rgba(255, 255, 255, 0.05);
    border-radius: 12px;
    align-items: flex-end;
}

.filter-group {
    display: flex;
    flex-direction: column;
    gap: 6px;
    flex: 1;
    min-width: 250px;
}

.filter-group label {
    font-size: 12px;
    font-weight: 600;
    color: #888;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.filter-group select {
    padding: 12px 16px;
    border-radius: 8px;
    border: 2px solid rgba(212, 175, 55, 0.3);
    background: rgba(255, 255, 255, 0.08);
    color: #fff;
    font-size: 15px;
    cursor: pointer;
    transition: all 0.2s ease;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%23D4AF37' d='M6 8L1 3h10z'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 12px center;
    padding-right: 36px;
}

.filter-group select:hover {
    border-color: rgba(212, 175, 55, 0.6);
    background-color: rgba(255, 255, 255, 0.12);
}

.filter-group select:focus {
    outline: none;
    border-color: #D4AF37;
    box-shadow: 0 0 0 3px rgba(212, 175, 55, 0.2);
}

.aircraft-stats {
    display: flex;
    gap: 24px;
    margin-bottom: 24px;
    flex-wrap: wrap;
}

.stat-card {
    background: rgba(255, 255, 255, 0.05);
    padding: 16px 24px;
    border-radius: 12px;
    text-align: center;
    min-width: 120px;
    min-height: 80px;
    display: flex;
    flex-direction: column;
    justify-content: center;
}

.stat-card .value {
    font-size: 28px;
    font-weight: 700;
    color: #D4AF37;
    line-height: 1.2;
}

.stat-card .label {
    font-size: 12px;
    color: #888;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-top: 4px;
}

.aircraft-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 16px;
}

.aircraft-table th,
.aircraft-table td {
    padding: 12px 16px;
    text-align: left;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    vertical-align: middle;
}

.aircraft-table th {
    font-size: 12px;
    font-weight: 600;
    color: #888;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    background: rgba(255, 255, 255, 0.03);
}

.aircraft-table tbody tr:hover {
    background: rgba(255, 255, 255, 0.03);
}

.aircraft-type {
    font-family: monospace;
    font-weight: 600;
}

.aircraft-registration {
    font-family: monospace;
    font-weight: 700;
    color: #D4AF37;
}

.aircraft-model {
    color: #ccc;
}

.aircraft-aeroclub {
    font-size: 13px;
    color: #888;
}

.aircraft-version {
    font-family: monospace;
    font-size: 13px;
}

.aircraft-updated {
    font-size: 13px;
    color: #888;
}

.language-flags {
    display: flex;
    gap: 6px;
    align-items: center;
}

.language-flag {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 50%;
    font-size: 16px;
}

.premium-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    background: linear-gradient(135deg, #D4AF37, #B8860B);
    color: #000;
    font-size: 10px;
    font-weight: 700;
    border-radius: 4px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.free-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    background: rgba(76, 175, 80, 0.2);
    color: #4CAF50;
    font-size: 10px;
    font-weight: 700;
    border-radius: 4px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.loading-state {
    text-align: center;
    padding: 48px;
    color: #888;
}

.loading-spinner {
    width: 40px;
    height: 40px;
    border: 3px solid rgba(255, 255, 255, 0.1);
    border-top-color: #D4AF37;
    border-radius: 50%;
    animation: spin 1s linear infinite;
    margin: 0 auto 16px;
}

@keyframes spin {
    to { transform: rotate(360deg); }
}

.error-state {
    text-align: center;
    padding: 48px;
    color: #f44336;
}

.no-results {
    text-align: center;
    padding: 48px;
    color: #888;
}

@media (max-width: 768px) {
    .aircraft-filters {
        flex-direction: column;
    }

    .filter-group {
        min-width: 100%;
    }

    .aircraft-stats {
        justify-content: center;
    }

    .aircraft-table {
        display: block;
        overflow-x: auto;
    }
}

/* Aeroclub section styling */
.aeroclub-section {
    margin-bottom: 32px;
}

.aeroclub-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 16px;
    background: rgba(212, 175, 55, 0.1);
    border-left: 3px solid #D4AF37;
    margin-bottom: 8px;
    font-weight: 600;
    color: #D4AF37;
}

.aeroclub-header svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}
</style>

# Avions disponibles

Cette page liste toutes les checklists d'avions actuellement disponibles dans AeroCheck.

<div class="aircraft-list-container">
    <div class="aircraft-stats" id="aircraft-stats">
        <div class="stat-card">
            <div class="value" id="total-count">-</div>
            <div class="label">Total</div>
        </div>
        <div class="stat-card">
            <div class="value" id="free-count">-</div>
            <div class="label">Gratuits</div>
        </div>
        <div class="stat-card">
            <div class="value" id="premium-count">-</div>
            <div class="label">Premium</div>
        </div>
        <div class="stat-card">
            <div class="value" id="aeroclub-count">-</div>
            <div class="label">Aeroclubs</div>
        </div>
    </div>

    <div class="aircraft-filters">
        <div class="filter-group">
            <label for="aeroclub-filter">Filtrer par aeroclub</label>
            <select id="aeroclub-filter">
                <option value="">Tous les aeroclubs</option>
            </select>
        </div>
    </div>

    <div id="aircraft-content">
        <div class="loading-state">
            <div class="loading-spinner"></div>
            <p>Chargement des donnees...</p>
        </div>
    </div>
</div>

<script>
const API_BASE_URL = 'https://api.aerocheck.app';

let allAircraft = [];
let allAeroclubs = [];

// Language code to flag emoji mapping
function languageToFlag(code) {
    const flags = {
        'en': '🇬🇧',
        'fr': '🇫🇷',
        'de': '🇩🇪',
        'it': '🇮🇹'
    };
    return flags[code] || '🏳️';
}

// Fetch aircraft data from API (v3 includes aeroclub field)
async function fetchAircraft() {
    try {
        const response = await fetch(`${API_BASE_URL}/api/v3/aircraft/available`);
        if (!response.ok) throw new Error('Erreur lors du chargement');
        const data = await response.json();
        return data.data.aircraft;
    } catch (error) {
        console.error('Error fetching aircraft:', error);
        throw error;
    }
}

// Fetch aeroclubs list from API (v3 endpoint)
async function fetchAeroclubs() {
    try {
        const response = await fetch(`${API_BASE_URL}/api/v3/aircraft/aeroclubs`);
        if (!response.ok) throw new Error('Erreur lors du chargement');
        const data = await response.json();
        return data.data.aeroclubs;
    } catch (error) {
        console.error('Error fetching aeroclubs:', error);
        return [];
    }
}

// Update statistics
function updateStats(aircraft) {
    document.getElementById('total-count').textContent = aircraft.length;
    document.getElementById('free-count').textContent = aircraft.filter(a => a.isFree).length;
    document.getElementById('premium-count').textContent = aircraft.filter(a => !a.isFree).length;

    const uniqueAeroclubs = new Set(aircraft.map(a => a.aeroclub).filter(Boolean));
    document.getElementById('aeroclub-count').textContent = uniqueAeroclubs.size;
}

// Populate aeroclub filter
function populateAeroclubFilter(aeroclubs) {
    const select = document.getElementById('aeroclub-filter');
    aeroclubs.forEach(aeroclub => {
        const option = document.createElement('option');
        option.value = aeroclub;
        option.textContent = aeroclub;
        select.appendChild(option);
    });
}

// Group aircraft by aeroclub
function groupByAeroclub(aircraft) {
    const groups = {};
    aircraft.forEach(a => {
        const key = a.aeroclub || '';
        if (!groups[key]) groups[key] = [];
        groups[key].push(a);
    });
    return Object.entries(groups).sort((a, b) => {
        if (a[0] === '' && b[0] === '') return 0;
        if (a[0] === '') return -1;
        if (b[0] === '') return 1;
        return a[0].localeCompare(b[0]);
    });
}

// Render aircraft table
function renderAircraft(aircraft) {
    const container = document.getElementById('aircraft-content');

    if (aircraft.length === 0) {
        container.innerHTML = '<div class="no-results"><p>Aucun avion ne correspond a vos filtres.</p></div>';
        return;
    }

    const grouped = groupByAeroclub(aircraft);
    let html = '';

    grouped.forEach(([aeroclub, aircraftList]) => {
        html += '<div class="aeroclub-section">';

        if (aeroclub) {
            html += `
                <div class="aeroclub-header">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 7V3H2v18h20V7H12zM6 19H4v-2h2v2zm0-4H4v-2h2v2zm0-4H4V9h2v2zm0-4H4V5h2v2zm4 12H8v-2h2v2zm0-4H8v-2h2v2zm0-4H8V9h2v2zm0-4H8V5h2v2zm10 12h-8v-2h2v-2h-2v-2h2v-2h-2V9h8v10zm-2-8h-2v2h2v-2zm0 4h-2v2h2v-2z"/></svg>
                    ${aeroclub}
                </div>
            `;
        }

        html += `
            <table class="aircraft-table">
                <thead>
                    <tr>
                        <th>Type</th>
                        <th>Immatriculation</th>
                        <th>Modele</th>
                        <th>Version</th>
                        <th>Mise a jour</th>
                        <th>Langues</th>
                        <th>Acces</th>
                    </tr>
                </thead>
                <tbody>
        `;

        aircraftList.forEach(a => {
            const languages = (a.availableLanguages || ['en']).map(lang =>
                `<span class="language-flag" title="${lang.toUpperCase()}">${languageToFlag(lang)}</span>`
            ).join('');

            const badge = a.isFree
                ? '<span class="free-badge">Gratuit</span>'
                : '<span class="premium-badge">Premium</span>';

            html += `
                <tr>
                    <td class="aircraft-type">${a.aircraftType}</td>
                    <td class="aircraft-registration">${a.registration}</td>
                    <td class="aircraft-model">${a.modelName}</td>
                    <td class="aircraft-version">${a.version}</td>
                    <td class="aircraft-updated">${a.lastUpdated}</td>
                    <td><div class="language-flags">${languages}</div></td>
                    <td>${badge}</td>
                </tr>
            `;
        });

        html += '</tbody></table></div>';
    });

    container.innerHTML = html;
}

// Apply filters
function applyFilters() {
    const aeroclubFilter = document.getElementById('aeroclub-filter').value;

    let filtered = allAircraft;

    if (aeroclubFilter) {
        filtered = filtered.filter(a => a.aeroclub === aeroclubFilter);
    }

    renderAircraft(filtered);
}

// Initialize
async function init() {
    try {
        // Fetch data in parallel
        const [aircraft, aeroclubs] = await Promise.all([
            fetchAircraft(),
            fetchAeroclubs()
        ]);

        allAircraft = aircraft;
        allAeroclubs = aeroclubs;

        updateStats(aircraft);
        populateAeroclubFilter(aeroclubs);
        renderAircraft(aircraft);

        // Set up filter listener
        document.getElementById('aeroclub-filter').addEventListener('change', applyFilters);

    } catch (error) {
        document.getElementById('aircraft-content').innerHTML = `
            <div class="error-state">
                <p>Impossible de charger les donnees. Veuillez reessayer plus tard.</p>
                <p style="font-size: 12px; margin-top: 8px;">${error.message}</p>
            </div>
        `;
    }
}

// Start when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
</script>
