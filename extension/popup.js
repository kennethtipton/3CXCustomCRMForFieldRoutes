// ============================================================
// PestRoutes Helper — Popup Script
// ============================================================

const extensionInput = document.getElementById('extensionInput');
const serverInput    = document.getElementById('serverInput');
const saveBtn        = document.getElementById('saveBtn');
const saveServerBtn  = document.getElementById('saveServerBtn');
const statusDot      = document.getElementById('statusDot');
const statusText     = document.getElementById('statusText');
const toast          = document.getElementById('toast');

// Load saved values
chrome.storage.local.get(['extensionNumber', 'serverAddress'], (result) => {
    if (result.extensionNumber) extensionInput.value = result.extensionNumber;
    if (result.serverAddress)   serverInput.value    = result.serverAddress;
});

// Check connection status by pinging the background worker
function refreshStatus() {
    chrome.storage.local.get(['extensionNumber'], (result) => {
        if (!result.extensionNumber) {
            statusDot.className  = 'status-dot disconnected';
            statusText.textContent = 'Not configured — enter extension number below';
            return;
        }

        // Try to reach the health endpoint on the server
        chrome.storage.local.get(['serverAddress'], (res) => {
            const server = res.serverAddress || 'localhost:3000';
            fetch(`http://${server}/health`)
                .then(r => r.json())
                .then(data => {
                    const ext = result.extensionNumber;
                    if (data.connectedOperators && data.connectedOperators.includes(ext)) {
                        statusDot.className    = 'status-dot connected';
                        statusText.textContent = `Connected as extension ${ext}`;
                    } else {
                        statusDot.className    = 'status-dot disconnected';
                        statusText.textContent = `Extension ${ext} not registered with server`;
                    }
                })
                .catch(() => {
                    statusDot.className    = 'status-dot disconnected';
                    statusText.textContent = 'Cannot reach middleware server';
                });
        });
    });
}

// Save extension number
saveBtn.addEventListener('click', () => {
    const val = extensionInput.value.trim();
    if (!val) return;

    chrome.storage.local.set({ extensionNumber: val }, () => {
        toast.style.display = 'block';
        setTimeout(() => { toast.style.display = 'none'; }, 2500);
        setTimeout(refreshStatus, 1500);
    });
});

// Save server address
saveServerBtn.addEventListener('click', () => {
    const val = serverInput.value.trim();
    if (!val) return;
    chrome.storage.local.set({ serverAddress: val }, () => {
        alert('Server address saved. Restart the extension to reconnect.');
    });
});

// Refresh status on open
refreshStatus();
