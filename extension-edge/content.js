// ============================================================
// FieldRoutes CRM for 3CX — Content Script
// ============================================================
// Runs on every PestRoutes page. Listens for messages from
// the background service worker and can interact with the
// live page DOM directly.
// ============================================================

console.log('[FieldRoutes CRM for 3CX] Content script active on', window.location.hostname);

// Listen for messages from the background worker
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.type === 'openCustomer') {
        triggerCustomerSearch(msg.customerID, msg.phone);
        sendResponse({ ok: true });
    }
});

function triggerCustomerSearch(customerID, phone) {
    const searchInput = document.getElementById('customerSearch');
    if (!searchInput) {
        console.warn('[FieldRoutes CRM for 3CX] customerSearch not found');
        return;
    }

    const searchTerm = phone || customerID;
    console.log(`[FieldRoutes CRM for 3CX] Content script triggering search for: ${searchTerm}`);

    searchInput.focus();
    searchInput.value = searchTerm;

    // Fire all the events jQuery UI autocomplete expects
    ['input', 'keyup', 'keydown'].forEach(eventType => {
        searchInput.dispatchEvent(new Event(eventType, { bubbles: true }));
    });

    // If jQuery is available, trigger directly
    if (typeof jQuery !== 'undefined') {
        jQuery('#customerSearch').val(searchTerm).autocomplete('search', searchTerm);
    }

    // Poll for the first autocomplete result and click it
    let attempts = 0;
    const timer = setInterval(() => {
        const item = document.querySelector('.ui-autocomplete li.ui-menu-item');
        if (item) {
            clearInterval(timer);
            item.click();
        }
        if (++attempts > 20) clearInterval(timer);
    }, 150);
}
