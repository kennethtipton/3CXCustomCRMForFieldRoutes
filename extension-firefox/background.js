// ============================================================
// FieldRoutes CRM for 3CX — Background Script (Firefox MV2)
// ============================================================
// Firefox uses Manifest V2 with event pages (persistent: false).
// The chrome.* namespace is available via Firefox's compatibility
// shim — no browser.* API calls needed.
// Key differences from the Chrome/Edge MV3 version:
//   - No service worker keepAlive alarm needed
//   - chrome.tabs.executeScript used instead of chrome.scripting
// ============================================================

// ============================================================
// CONFIGURATION
// All values are stored in chrome.storage.local and entered by
// the operator via the popup. Nothing sensitive is hardcoded.
// ============================================================
const PESTROUTES_HOST = 'midstatetermite.pestroutes.com';
const PESTROUTES_URL  = `https://${PESTROUTES_HOST}`;
const DEFAULT_SERVER  = 'localhost:3000';

// ============================================================
// STATE
// ============================================================
let eventSource      = null;
let myExtension      = '';
let serverAddress    = DEFAULT_SERVER;
let sharedSecret     = '';
let reconnectTimer   = null;

// ============================================================
// SSE CONNECTION
// EventSource automatically reconnects on drop — we just need
// to open it with the right URL and handle events.
// ============================================================
function connect() {
    chrome.storage.local.get(['extensionNumber', 'serverAddress', 'sharedSecret'], (result) => {
        myExtension   = result.extensionNumber || '';
        serverAddress = result.serverAddress   || DEFAULT_SERVER;
        sharedSecret  = result.sharedSecret    || '';

        if (!myExtension) {
            console.warn('[FieldRoutes] No extension number set — open the extension popup.');
            setStatus('off', 'Not configured');
            return;
        }

        if (!sharedSecret) {
            console.warn('[FieldRoutes] No shared secret set — open the extension popup.');
            setStatus('off', 'Secret not set');
            return;
        }

        // Close any existing connection cleanly
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }

        // Detect protocol from stored server address — support both http and https
        const proto  = serverAddress.startsWith('https://') ? '' : 'http://';
        const host   = serverAddress.replace(/^https?:\/\//, '');
        const sseUrl = `${proto}${host}/sse?agent=${encodeURIComponent(myExtension)}&secret=${encodeURIComponent(sharedSecret)}`;
        console.log(`[FieldRoutes] Connecting to SSE: ${sseUrl}`);

        // EventSource is a native browser API — no library needed.
        // It sends GET with Accept: text/event-stream automatically.
        // On disconnect it retries after the server's 'retry:' interval (default 3s).
        eventSource = new EventSource(sseUrl);

        // Connection opened
        eventSource.onopen = () => {
            console.log('[FieldRoutes] SSE connection established');
            clearTimeout(reconnectTimer);
            setStatus('on', `Connected as ext. ${myExtension}`);
        };

        // Server confirmed our registration
        eventSource.addEventListener('connected', (e) => {
            try {
                const data = JSON.parse(e.data);
                console.log('[FieldRoutes] Server confirmed connection:', data);
            } catch (err) {}
        });

        // Main event — open a customer popup
        eventSource.addEventListener('openCustomer', (e) => {
            try {
                const msg = JSON.parse(e.data);
                console.log('[FieldRoutes] openCustomer event received:', msg);
                handleOpenCustomer(msg.customerID, msg.phone);
            } catch (err) {
                console.error('[FieldRoutes] Failed to parse openCustomer event:', err);
            }
        });

        // Connection error / server unreachable
        // EventSource will retry automatically — we just update the badge
        eventSource.onerror = (e) => {
            console.warn('[FieldRoutes] SSE connection error — browser will retry automatically');
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
    console.log(`[FieldRoutes] Opening customer — ID: ${customerID}, Phone: ${phone}`);

    try {
        const tabs = await chrome.tabs.query({ url: `https://${PESTROUTES_HOST}/*` });
        let targetTab = null;

        if (tabs.length > 0) {
            targetTab = tabs[0];
            await chrome.windows.update(targetTab.windowId, { focused: true });
            await chrome.tabs.update(targetTab.id, { active: true });
        } else {
            console.log('[FieldRoutes] No PestRoutes tab found — opening one');
            targetTab = await chrome.tabs.create({ url: PESTROUTES_URL, active: true });
            await waitForTabLoad(targetTab.id);
        }

        await sleep(800);

        // Firefox MV2 uses chrome.tabs.executeScript instead of chrome.scripting
        await chrome.tabs.executeScript(targetTab.id, {
            code: `(${injectCustomerSearch.toString()})(${JSON.stringify(customerID)}, ${JSON.stringify(phone)})`
        });

    } catch (err) {
        console.error('[FieldRoutes] Failed to open customer:', err);
    }
}

// ============================================================
// INJECTED INTO PESTROUTES TAB
// Triggers the jQuery UI autocomplete search popup
// ============================================================
function injectCustomerSearch(customerID, phone) {
    const searchInput = document.getElementById('customerSearch');
    if (!searchInput) {
        console.warn('[FieldRoutes] #customerSearch not found on page');
        return;
    }

    const searchTerm = phone || customerID;
    console.log(`[FieldRoutes] Triggering search for: ${searchTerm}`);

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
            console.log('[FieldRoutes] jQuery autocomplete search triggered');
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
            console.warn('[FieldRoutes] Autocomplete result did not appear in time');
        }
    }, 150);
}

// ============================================================
// BADGE HELPERS
// ============================================================
function setStatus(state, label) {
    // Firefox MV2 uses browserAction; Chrome/Edge MV3 uses action
    const actionApi = chrome.action || chrome.browserAction;
    actionApi.setBadgeText({ text: state === 'on' ? 'ON' : 'OFF' });
    actionApi.setBadgeBackgroundColor({
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
    if (changes.extensionNumber || changes.serverAddress || changes.sharedSecret) {
        console.log('[FieldRoutes] Settings changed — reconnecting');
        setTimeout(connect, 300);
    }
});

// Firefox MV2 event pages: no keepAlive alarm needed.
// The event page wakes on SSE events and chrome.storage.onChanged automatically.
