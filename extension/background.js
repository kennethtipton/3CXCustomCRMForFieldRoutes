// ============================================================
// PestRoutes Helper — Background Service Worker (SSE Edition)
// ============================================================
// Uses the browser's native EventSource API to maintain a
// persistent SSE connection to the Pode/PowerShell middleware.
// SSE is simpler than WebSockets — it is a plain HTTP GET that
// the server keeps open and streams events down. The browser
// handles reconnection automatically.
// ============================================================

// ============================================================
// CONFIGURATION — must match Start-PestRoutesMiddleware.ps1
// ============================================================
const SECRET          = 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING';
const PESTROUTES_HOST = 'midstatetermite.pestroutes.com';
const PESTROUTES_URL  = `https://${PESTROUTES_HOST}`;

// Server address is loaded from storage (set via extension popup)
// Default shown here is a fallback only
const DEFAULT_SERVER  = 'localhost:3000';

// ============================================================
// STATE
// ============================================================
let eventSource      = null;
let myExtension      = '';
let serverAddress    = DEFAULT_SERVER;
let reconnectTimer   = null;

// ============================================================
// SSE CONNECTION
// EventSource automatically reconnects on drop — we just need
// to open it with the right URL and handle events.
// ============================================================
function connect() {
    chrome.storage.local.get(['extensionNumber', 'serverAddress'], (result) => {
        myExtension   = result.extensionNumber || '';
        serverAddress = result.serverAddress   || DEFAULT_SERVER;

        if (!myExtension) {
            console.warn('[PestRoutes] No extension number set. Open the extension popup.');
            setStatus('off', 'Not configured');
            return;
        }

        // Close any existing connection cleanly
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }

        const sseUrl = `http://${serverAddress}/sse?agent=${encodeURIComponent(myExtension)}&secret=${encodeURIComponent(SECRET)}`;
        console.log(`[PestRoutes] Connecting to SSE: ${sseUrl}`);

        // EventSource is a native browser API — no library needed.
        // It sends GET with Accept: text/event-stream automatically.
        // On disconnect it retries after the server's 'retry:' interval (default 3s).
        eventSource = new EventSource(sseUrl);

        // Connection opened
        eventSource.onopen = () => {
            console.log('[PestRoutes] SSE connection established');
            clearTimeout(reconnectTimer);
            setStatus('on', `Connected as ext. ${myExtension}`);
        };

        // Server confirmed our registration
        eventSource.addEventListener('connected', (e) => {
            try {
                const data = JSON.parse(e.data);
                console.log('[PestRoutes] Server confirmed connection:', data);
            } catch (err) {}
        });

        // Main event — open a customer popup
        eventSource.addEventListener('openCustomer', (e) => {
            try {
                const msg = JSON.parse(e.data);
                console.log('[PestRoutes] openCustomer event received:', msg);
                handleOpenCustomer(msg.customerID, msg.phone);
            } catch (err) {
                console.error('[PestRoutes] Failed to parse openCustomer event:', err);
            }
        });

        // Connection error / server unreachable
        // EventSource will retry automatically — we just update the badge
        eventSource.onerror = (e) => {
            console.warn('[PestRoutes] SSE connection error — browser will retry automatically');
            setStatus('off', 'Reconnecting...');

            // If the connection is permanently closed (readyState 2), reconnect manually
            if (eventSource.readyState === EventSource.CLOSED) {
                eventSource = null;
                clearTimeout(reconnectTimer);
                reconnectTimer = setTimeout(connect, 5000);
            }
        };
    });
}

// ============================================================
// OPEN CUSTOMER HANDLER
// ============================================================
async function handleOpenCustomer(customerID, phone) {
    console.log(`[PestRoutes] Opening customer — ID: ${customerID}, Phone: ${phone}`);

    try {
        const tabs = await chrome.tabs.query({ url: `https://${PESTROUTES_HOST}/*` });
        let targetTab = null;

        if (tabs.length > 0) {
            targetTab = tabs[0];
            await chrome.windows.update(targetTab.windowId, { focused: true });
            await chrome.tabs.update(targetTab.id, { active: true });
        } else {
            console.log('[PestRoutes] No PestRoutes tab found — opening one');
            targetTab = await chrome.tabs.create({ url: PESTROUTES_URL, active: true });
            await waitForTabLoad(targetTab.id);
        }

        await sleep(800);

        await chrome.scripting.executeScript({
            target: { tabId: targetTab.id },
            func:   injectCustomerSearch,
            args:   [customerID, phone]
        });

    } catch (err) {
        console.error('[PestRoutes] Failed to open customer:', err);
    }
}

// ============================================================
// INJECTED INTO PESTROUTES TAB
// Triggers the jQuery UI autocomplete search popup
// ============================================================
function injectCustomerSearch(customerID, phone) {
    const searchInput = document.getElementById('customerSearch');
    if (!searchInput) {
        console.warn('[PestRoutes] #customerSearch not found on page');
        return;
    }

    const searchTerm = phone || customerID;
    console.log(`[PestRoutes] Triggering search for: ${searchTerm}`);

    searchInput.focus();

    // Set value via native setter (required for React/jQuery UI to detect change)
    const nativeSetter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype, 'value'
    ).set;
    nativeSetter.call(searchInput, searchTerm);

    searchInput.dispatchEvent(new Event('input',  { bubbles: true }));
    searchInput.dispatchEvent(new Event('keyup',  { bubbles: true }));

    // Trigger jQuery UI autocomplete directly if jQuery is present
    if (typeof jQuery !== 'undefined') {
        try {
            jQuery('#customerSearch').val(searchTerm).autocomplete('search', searchTerm);
            console.log('[PestRoutes] jQuery autocomplete search triggered');
        } catch (e) {}
    }

    // Poll for autocomplete result and click the first one
    let attempts = 0;
    const poll = setInterval(() => {
        const item = document.querySelector('.ui-autocomplete li.ui-menu-item');
        if (item) {
            clearInterval(poll);
            item.click();
            const link = item.querySelector('a, .ui-menu-item-wrapper, div');
            if (link) link.click();
        }
        if (++attempts > 20) {
            clearInterval(poll);
            console.warn('[PestRoutes] Autocomplete result did not appear in time');
        }
    }, 150);
}

// ============================================================
// BADGE HELPERS
// ============================================================
function setStatus(state, label) {
    chrome.action.setBadgeText({ text: state === 'on' ? 'ON' : 'OFF' });
    chrome.action.setBadgeBackgroundColor({
        color: state === 'on' ? '#2d7d46' : '#c0392b'
    });
}

// ============================================================
// UTILITIES
// ============================================================
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function waitForTabLoad(tabId) {
    return new Promise(resolve => {
        const listener = (id, changeInfo) => {
            if (id === tabId && changeInfo.status === 'complete') {
                chrome.tabs.onUpdated.removeListener(listener);
                resolve();
            }
        };
        chrome.tabs.onUpdated.addListener(listener);
    });
}

// ============================================================
// STARTUP & LIFECYCLE
// ============================================================
connect();

// Reconnect if settings change (operator updates extension number or server)
chrome.storage.onChanged.addListener((changes) => {
    if (changes.extensionNumber || changes.serverAddress) {
        console.log('[PestRoutes] Settings changed — reconnecting');
        setTimeout(connect, 300);
    }
});

// Keep service worker alive (MV3 requirement)
chrome.alarms.create('keepAlive', { periodInMinutes: 0.4 });
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== 'keepAlive') return;

    // If EventSource has gone away, reconnect
    if (!eventSource || eventSource.readyState === EventSource.CLOSED) {
        console.log('[PestRoutes] keepAlive: reconnecting');
        connect();
    }
});
