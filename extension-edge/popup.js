// ============================================================
// FieldRoutes CRM for 3CX — Popup Script
// ============================================================

const extensionInput = document.getElementById('extensionInput');
const serverInput    = document.getElementById('serverInput');
const secretInput    = document.getElementById('secretInput');
const saveBtn        = document.getElementById('saveBtn');
const saveServerBtn  = document.getElementById('saveServerBtn');
const saveSecretBtn  = document.getElementById('saveSecretBtn');
const statusDot      = document.getElementById('statusDot');
const statusText     = document.getElementById('statusText');
const secretSet      = document.getElementById('secretSet');
const toast          = document.getElementById('toast');

// Load saved values on popup open.
// The secret is never shown back to the user — only a "configured" indicator.
chrome.storage.local.get(['extensionNumber', 'serverAddress', 'sharedSecret'], (result) => {
    if (result.extensionNumber) extensionInput.value = result.extensionNumber;
    if (result.serverAddress)   serverInput.value    = result.serverAddress;

    // Show indicator if secret is stored — never populate the password field
    if (result.sharedSecret) {
        secretSet.style.display = 'block';
    }
});

// Check connection status against the middleware health endpoint
function refreshStatus() {
    chrome.storage.local.get(['extensionNumber', 'serverAddress', 'sharedSecret'], (result) => {
        if (!result.extensionNumber) {
            statusDot.className    = 'status-dot disconnected';
            statusText.textContent = 'Not configured — enter your extension number below';
            return;
        }

        if (!result.sharedSecret) {
            statusDot.className    = 'status-dot disconnected';
            statusText.textContent = 'Shared secret not set — enter it below';
            return;
        }

        const server = result.serverAddress || 'localhost:3000';
        const proto  = server.startsWith('https://') ? '' : 'http://';
        const host   = server.replace(/^https?:\/\//, '');

        fetch(`${proto}${host}/health`)
            .then(r => r.json())
            .then(data => {
                const ext = result.extensionNumber;
                if (data.connectedOperators && data.connectedOperators.includes(ext)) {
                    statusDot.className    = 'status-dot connected';
                    statusText.textContent = `Connected as extension ${ext}`;
                } else {
                    statusDot.className    = 'status-dot disconnected';
                    statusText.textContent = `Extension ${ext} not yet registered with server`;
                }
            })
            .catch(() => {
                statusDot.className    = 'status-dot disconnected';
                statusText.textContent = 'Cannot reach middleware server';
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
        showToast('Server address saved');
        setTimeout(refreshStatus, 500);
    });
});

// Save shared secret — stored in chrome.storage.local, never shown back
saveSecretBtn.addEventListener('click', () => {
    const val = secretInput.value;
    if (!val) return;
    chrome.storage.local.set({ sharedSecret: val }, () => {
        secretInput.value      = '';              // clear field immediately after save
        secretSet.style.display = 'block';        // show "configured" indicator
        showToast('Secret saved');
        setTimeout(refreshStatus, 500);
    });
});

function showToast(msg) {
    toast.textContent    = '✓ ' + msg;
    toast.style.display  = 'block';
    setTimeout(() => { toast.style.display = 'none'; }, 2500);
}

// Refresh on popup open
refreshStatus();
