# PestRoutes 3CX Popup — Pode/PowerShell + SSE Edition
## Complete Setup Guide

---

## Why SSE instead of WebSockets?

| | WebSocket (old Node.js version) | SSE (this version) |
|---|---|---|
| Runtime | Node.js (75MB install) | PowerShell — already on Windows |
| Protocol | Full duplex, stateful | One-way server push over plain HTTP |
| Browser reconnect | Manual (you write the retry logic) | **Automatic** — built into EventSource API |
| Complexity | Higher (custom handshake, ping/pong) | Lower (plain HTTP GET, kept open) |
| Our use case fit | Overkill — we only push server→client | **Perfect** — we only ever push server→client |
| Firewall friendliness | Requires WS upgrade | Plain HTTP — always works |

SSE is a better fit because data only ever flows **one direction**: server → extension.
The browser's native `EventSource` API handles reconnection automatically with
no extra code needed in the extension.

---

## How It Works

```
Chrome extension opens a persistent SSE connection on startup:
  GET http://SERVER:3000/sse?agent=101&secret=XXXX
  (Pode keeps this HTTP connection open and streams events down it)
        ↓
Operator answers a call in 3CX
3CX fires ContactUrl (set to "Answer"):
  GET http://SERVER:3000/notify?customerID=12345&phone=5551234567&agent=101
        ↓
Pode /notify route receives request
Calls: Send-PodeSseEvent -Name 'Operators' -Group '101' -Data '{...}'
Pode pushes the event down the open SSE connection for group '101'
        ↓
Chrome extension EventSource fires the 'openCustomer' event handler
Extension finds the open PestRoutes tab
Triggers jQuery autocomplete search
Customer popup opens automatically
```

---

## Component 1 — Pode Middleware Server

### Requirements
- Windows machine with PowerShell 5.1 or higher (already on all Windows servers)
- Pode PowerShell module (installed with one command, no admin required)
- No Node.js, no npm, no additional runtime

### Installation

**1. Install Pode (one time, no admin required):**
```powershell
Install-Module -Name Pode -Scope CurrentUser
```

**2. Copy the `server/` folder** to `C:\PestRoutesHelper\server\`

**3. Edit `Start-PestRoutesMiddleware.ps1`:**
- Change `$SECRET` to any long random string
- Optionally change `$HTTP_PORT` (default 3000)

**4. Test it:**
```powershell
cd C:\PestRoutesHelper\server
pwsh .\Start-PestRoutesMiddleware.ps1
```
You should see:
```
[INFO ] HTTP server listening on port 3000
[INFO ] SSE endpoint   : http://YOUR_SERVER_IP:3000/sse?agent=[EXT]&secret=[SECRET]
[INFO ] 3CX ContactUrl : http://YOUR_SERVER_IP:3000/notify?...
```

**5. Check health endpoint:**
```
http://localhost:3000/health
```

### Run as a Windows Scheduled Task (auto-start on boot)

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
             -Argument '-NonInteractive -File C:\PestRoutesHelper\server\Start-PestRoutesMiddleware.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 3
Register-ScheduledTask -TaskName 'PestRoutesHelper' -Action $action `
                       -Trigger $trigger -Settings $settings `
                       -RunLevel Highest -Force
```

### Firewall Rule
Open port 3000 in Windows Firewall for inbound connections from operator workstations:
```powershell
New-NetFirewallRule -DisplayName 'PestRoutes Helper' -Direction Inbound `
                   -Protocol TCP -LocalPort 3000 -Action Allow
```

---

## Component 2 — Chrome Extension

### Installation (each operator workstation — one time)

1. Copy the `extension/` folder to the workstation, e.g. `C:\PestRoutesHelper\extension\`
2. Open Chrome → `chrome://extensions/`
3. Enable **Developer Mode** (top right toggle)
4. Click **Load unpacked** → select the `extension/` folder
5. Click the **PestRoutes Helper** icon in the Chrome toolbar
6. Enter:
   - **My 3CX Extension Number** — e.g. `101` (each operator enters their own number)
   - **Server** — e.g. `192.168.1.50:3000`
7. Click **Save & Connect**
8. Badge should turn green showing **ON**

The extension connects via SSE automatically on Chrome startup and
reconnects automatically if the connection drops. No manual intervention needed.

---

## Component 3 — Update 3CX CRM Template

In `FieldRoutesCRMfor3CX_v6.xml`, change the ContactUrl Output to:

```xml
<Output Type="ContactUrl" Value="http://YOUR_SERVER_IP:3000/notify?customerID=[EntityId]&amp;phone=[Number]&amp;agent=[Agent]" />
```

In 3CX Management Console → Settings → CRM → Server Side:
- **Open Contact URL on:** `Answer`

---

## Customization Required Before Deploying

**`server/Start-PestRoutesMiddleware.ps1`** — line ~20:
```powershell
$SECRET = 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING'
```

**`extension/background.js`** — line ~15:
```javascript
const SECRET = 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING';
```

Both values must be identical.

---

## Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /sse?agent=101&secret=XXX` | SSE connection — Chrome extension connects here |
| `GET /notify?customerID=X&phone=Y&agent=101` | 3CX ContactUrl fires here on answer |
| `GET /health` | JSON status |
| `GET /calls` | HTML call log viewer (auto-refreshes 30s) |
| `GET /calls.csv` | Download call log as CSV |

---

## Log Files

All logs written to `server/logs/`:

| File | Contents |
|---|---|
| `YYYY-MM-DD.log` | Timestamped server log — connections, calls, errors |
| `calls.csv` | One row per call — viewable in Excel or at `/calls` |

Logs rotate daily. Files older than 30 days are automatically deleted.

---

## Troubleshooting

**Badge shows OFF:**
- Check server is running and reachable at `http://SERVER:3000/health`
- Check Windows Firewall allows port 3000
- Verify server address in extension popup matches actual server IP

**Popup doesn't open (badge is ON):**
- Check `[Agent]` in the 3CX ContactUrl is passing the correct extension number
- Verify the extension number in the popup matches the operator's actual 3CX extension
- Check `/calls` viewer to see if calls are being received with the right agent value

**Wrong customer opens:**
- The search uses phone number — verify phone format in FieldRoutes matches what 3CX sends
- Try the phone number manually in PestRoutes search to confirm it finds the right customer
