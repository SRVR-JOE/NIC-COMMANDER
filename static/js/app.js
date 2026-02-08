// NIC Commander - Frontend JavaScript

// Global state
let currentNics = [];

// Initialize the application
document.addEventListener('DOMContentLoaded', function() {
    loadNics();
    setupEventListeners();
});

// Set up event listeners
function setupEventListeners() {
    document.getElementById('refresh-btn').addEventListener('click', loadNics);
    document.getElementById('ping-btn').addEventListener('click', executePing);
    document.getElementById('discover-btn').addEventListener('click', executeDiscovery);
    
    // Allow Enter key to trigger actions
    document.getElementById('ping-host').addEventListener('keypress', function(e) {
        if (e.key === 'Enter') executePing();
    });
    
    document.getElementById('discovery-prefix').addEventListener('keypress', function(e) {
        if (e.key === 'Enter') executeDiscovery();
    });
}

// Load and display NICs
async function loadNics() {
    const loading = document.getElementById('loading');
    const error = document.getElementById('error');
    const container = document.getElementById('nics-container');
    
    loading.style.display = 'block';
    error.style.display = 'none';
    container.innerHTML = '';
    
    try {
        const response = await fetch('/api/nics');
        const data = await response.json();
        
        if (data.success) {
            currentNics = data.nics;
            displayNics(data.nics);
        } else {
            showError('Failed to load NICs: ' + data.error);
        }
    } catch (err) {
        showError('Error connecting to server: ' + err.message);
    } finally {
        loading.style.display = 'none';
    }
}

// Display NICs in the grid
function displayNics(nics) {
    const container = document.getElementById('nics-container');
    
    if (nics.length === 0) {
        container.innerHTML = '<p style="text-align: center; color: #666;">No network interfaces found.</p>';
        return;
    }
    
    nics.forEach(nic => {
        const nicCard = createNicCard(nic);
        container.appendChild(nicCard);
    });
}

// Create a NIC card element
function createNicCard(nic) {
    const card = document.createElement('div');
    card.className = `nic-card ${nic.is_up ? 'active' : 'inactive'}`;
    
    card.innerHTML = `
        <div class="nic-header">
            <div>
                <div class="nic-id">NIC #${nic.id}</div>
                <div class="nic-name">${nic.name}</div>
            </div>
            <span class="nic-status ${nic.is_up ? 'status-up' : 'status-down'}">
                ${nic.is_up ? '✓ UP' : '✗ DOWN'}
            </span>
        </div>
        <div class="nic-details">
            <div class="detail-row">
                <span class="detail-label">IPv4:</span>
                <span class="detail-value">${nic.ipv4}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Netmask:</span>
                <span class="detail-value">${nic.netmask}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">IPv6:</span>
                <span class="detail-value">${nic.ipv6}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">MAC:</span>
                <span class="detail-value">${nic.mac}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Speed:</span>
                <span class="detail-value">${nic.speed}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">MTU:</span>
                <span class="detail-value">${nic.mtu}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Sent:</span>
                <span class="detail-value">${nic.bytes_sent} (${nic.packets_sent} packets)</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Received:</span>
                <span class="detail-value">${nic.bytes_recv} (${nic.packets_recv} packets)</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Errors:</span>
                <span class="detail-value">In: ${nic.errors_in}, Out: ${nic.errors_out}</span>
            </div>
            <div class="detail-row">
                <span class="detail-label">Drops:</span>
                <span class="detail-value">In: ${nic.drops_in}, Out: ${nic.drops_out}</span>
            </div>
        </div>
    `;
    
    return card;
}

// Execute ping
async function executePing() {
    const hostInput = document.getElementById('ping-host');
    const countInput = document.getElementById('ping-count');
    const resultDiv = document.getElementById('ping-result');
    const pingBtn = document.getElementById('ping-btn');
    
    const host = hostInput.value.trim();
    const count = parseInt(countInput.value) || 4;
    
    if (!host) {
        alert('Please enter a host or IP address');
        return;
    }
    
    pingBtn.disabled = true;
    pingBtn.textContent = 'Pinging...';
    resultDiv.textContent = 'Executing ping...';
    resultDiv.style.display = 'block';
    
    try {
        const response = await fetch('/api/ping', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ host, count })
        });
        
        const data = await response.json();
        
        if (data.success) {
            resultDiv.textContent = data.output;
            resultDiv.style.borderColor = '#48bb78';
        } else {
            resultDiv.textContent = `Error: ${data.error}\n\n${data.output}`;
            resultDiv.style.borderColor = '#e53e3e';
        }
    } catch (err) {
        resultDiv.textContent = 'Error: ' + err.message;
        resultDiv.style.borderColor = '#e53e3e';
    } finally {
        pingBtn.disabled = false;
        pingBtn.textContent = 'Ping';
    }
}

// Execute device discovery
async function executeDiscovery() {
    const prefixInput = document.getElementById('discovery-prefix');
    const resultDiv = document.getElementById('discovery-result');
    const statusDiv = document.getElementById('discovery-status');
    const discoverBtn = document.getElementById('discover-btn');
    
    const prefix = prefixInput.value.trim();
    
    if (!prefix) {
        alert('Please enter a network prefix (e.g., 192.168.1)');
        return;
    }
    
    // Validate prefix format
    const prefixParts = prefix.split('.');
    if (prefixParts.length !== 3 || prefixParts.some(p => isNaN(p) || p < 0 || p > 255)) {
        alert('Invalid network prefix. Please use format: 192.168.1');
        return;
    }
    
    discoverBtn.disabled = true;
    discoverBtn.textContent = 'Scanning...';
    statusDiv.textContent = 'Scanning network... This may take a few moments.';
    resultDiv.innerHTML = '';
    resultDiv.style.display = 'none';
    
    try {
        const response = await fetch('/api/discover', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ network_prefix: prefix })
        });
        
        const data = await response.json();
        
        if (data.success) {
            statusDiv.textContent = `Found ${data.devices.length} device(s)`;
            displayDiscoveredDevices(data.devices);
        } else {
            statusDiv.textContent = 'Error: ' + data.error;
            statusDiv.style.color = '#e53e3e';
        }
    } catch (err) {
        statusDiv.textContent = 'Error: ' + err.message;
        statusDiv.style.color = '#e53e3e';
    } finally {
        discoverBtn.disabled = false;
        discoverBtn.textContent = 'Discover Devices';
    }
}

// Display discovered devices
function displayDiscoveredDevices(devices) {
    const resultDiv = document.getElementById('discovery-result');
    
    if (devices.length === 0) {
        resultDiv.innerHTML = '<p>No devices found on the network.</p>';
        resultDiv.style.display = 'block';
        return;
    }
    
    const deviceList = document.createElement('ul');
    deviceList.className = 'device-list';
    
    devices.forEach(device => {
        const item = document.createElement('li');
        item.className = 'device-item';
        item.innerHTML = `
            <div class="device-ip">${device.ip}</div>
            <div class="device-hostname">${device.hostname}</div>
        `;
        deviceList.appendChild(item);
    });
    
    resultDiv.innerHTML = '';
    resultDiv.appendChild(deviceList);
    resultDiv.style.display = 'block';
}

// Show error message
function showError(message) {
    const error = document.getElementById('error');
    error.textContent = message;
    error.style.display = 'block';
}
