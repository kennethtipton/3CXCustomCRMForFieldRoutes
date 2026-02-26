# ==============================================================================
# FieldRoutes CRM for 3CX — Popup Middleware (Pode/PowerShell)
# ==============================================================================
# No Node.js required. Runs entirely in PowerShell using the Pode module.
#
# INSTALL:
#   1. Install-Module -Name Pode -Scope AllUsers   (one time)
#   2. Deploy to C:\Scripts\Applications\FieldRoutesCrmFor3CX\
#   3. Open  http://localhost:3000/settings  to configure
#
# All settings (port, HTTPS, certificate, FQDN, secret) are managed
# through the web UI at /settings and saved to config.json.
# The server restarts automatically after saving.
# ==============================================================================

# ==============================================================================
# PATHS
# ==============================================================================
# Scripts live wherever this .ps1 was deployed (e.g. C:\Scripts\Applications\...)
# Sensitive data (config, certs, logs) lives under C:\ProgramData\Scripts\Settings
# so it is:
#   - Accessible to SYSTEM and Administrators regardless of which user runs the script
#   - Outside the web-served / source-controlled script directory
#   - Consistent across script relocations or updates
# ==============================================================================
$ScriptRoot  = $PSScriptRoot
$DataRoot    = 'C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX'
$ConfigPath  = Join-Path $DataRoot  'config.json'
$CertsDir    = Join-Path $DataRoot  'certs'
$LogDir      = Join-Path $DataRoot  'logs'
$CallCsvPath = Join-Path $LogDir    'calls.csv'

foreach ($dir in @($DataRoot, $CertsDir, $LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ==============================================================================
# CRYPTO — DPAPI-backed config encryption
# ==============================================================================
Import-Module (Join-Path $ScriptRoot 'ProtectedConfig.psm1') -Force

# ==============================================================================
# CONFIG HELPERS
# Thin wrappers so the rest of the script uses the same call sites as before.
# All encryption/decryption is handled inside ProtectedConfig.psm1.
# ==============================================================================
function Read-Config {
    return Read-SecureConfig -ConfigPath $ConfigPath
}

function Save-Config ($cfg) {
    Save-SecureConfig -Config $cfg -ConfigPath $ConfigPath
}

# ==============================================================================
# LOGGING HELPERS
# ==============================================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$($Level.PadRight(5))] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red    }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'CALL'  { Write-Host $line -ForegroundColor Cyan   }
        'WS'    { Write-Host $line -ForegroundColor Green  }
        default { Write-Host $line }
    }
    $logFile = Join-Path $LogDir "$(Get-Date -Format 'yyyy-MM-dd').log"
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
    # Purge old logs
    $cfg = Read-Config
    Get-ChildItem -Path $LogDir -Filter '*.log' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $cfg.LogRetainDays |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-CallCsv {
    param([string]$CustomerID, [string]$Phone, [string]$Agent,
          [bool]$ExtConnected, [string]$Result)
    if (-not (Test-Path $CallCsvPath)) {
        '"Timestamp","CustomerID","Phone","Agent","ExtensionConnected","Result"' |
            Out-File -FilePath $CallCsvPath -Encoding utf8
    }
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $row = '"' + @($ts, $CustomerID, $Phone, $Agent,
                   ($ExtConnected ? 'YES' : 'NO'), $Result) -join '","' + '"'
    $row | Out-File -FilePath $CallCsvPath -Append -Encoding utf8
}

# ==============================================================================
# HTML SHARED LAYOUT
# Wraps all admin pages in a consistent nav + style
# ==============================================================================
function Get-PageHtml {
    param([string]$Title, [string]$Body, [string]$ActiveNav = '')

    $cfg      = Read-Config
    $proto    = $cfg.UseHttps ? 'https' : 'http'
    $base     = "${proto}://$($cfg.Fqdn):$($cfg.Port)"
    $navItems = @(
        @{ path='/calls';       label='&#x1F4DE; Call Log'    }
        @{ path='/logs';        label='&#x1F4C4; Server Log'  }
        @{ path='/certificate'; label='&#x1F512; Certificate' }
        @{ path='/settings';    label='&#x2699;&#xFE0F; Settings' }
        @{ path='/health';      label='&#x2665; Health'       }
    )
    $navHtml = $navItems | ForEach-Object {
        $active = if ($_.path -eq $ActiveNav) { ' class="active"' } else { '' }
        "<a href=`"$($_.path)`"$active>$($_.label)</a>"
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>$Title — FieldRoutes CRM for 3CX</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f4f8;min-height:100vh}

    /* NAV */
    nav{background:#1a5c32;display:flex;align-items:center;padding:0 24px;
        height:52px;gap:4px;position:sticky;top:0;z-index:100;
        box-shadow:0 2px 8px rgba(0,0,0,.25)}
    nav .brand{color:white;font-weight:700;font-size:15px;margin-right:20px;
               white-space:nowrap}
    nav a{color:rgba(255,255,255,.75);text-decoration:none;padding:6px 12px;
          border-radius:5px;font-size:13px;transition:all .15s}
    nav a:hover{background:rgba(255,255,255,.12);color:white}
    nav a.active{background:#2d7d46;color:white;font-weight:600}

    /* PAGE */
    .page{max-width:900px;margin:32px auto;padding:0 20px}
    h1{color:#1a5c32;font-size:22px;margin-bottom:6px}
    .subtitle{color:#999;font-size:12px;margin-bottom:24px}

    /* CARDS */
    .card{background:white;border-radius:10px;padding:24px;
          box-shadow:0 2px 8px rgba(0,0,0,.07);margin-bottom:20px}
    .card h2{font-size:14px;font-weight:700;color:#333;margin-bottom:16px;
             text-transform:uppercase;letter-spacing:.5px;
             border-bottom:1px solid #f0f0f0;padding-bottom:10px}

    /* FORM */
    .field{margin-bottom:16px}
    .field label{display:block;font-size:12px;font-weight:600;color:#666;
                 text-transform:uppercase;letter-spacing:.4px;margin-bottom:5px}
    .field input[type=text],.field input[type=number],.field input[type=password]{
        width:100%;padding:9px 12px;border:1px solid #dce0e5;border-radius:6px;
        font-size:14px;outline:none;transition:border-color .15s;background:#fafafa}
    .field input:focus{border-color:#2d7d46;background:white}
    .field .hint{font-size:11px;color:#aaa;margin-top:4px}
    .toggle-row{display:flex;align-items:center;gap:10px}
    .toggle{position:relative;width:44px;height:24px;flex-shrink:0}
    .toggle input{opacity:0;width:0;height:0}
    .slider{position:absolute;inset:0;background:#ccc;border-radius:24px;
            cursor:pointer;transition:.2s}
    .slider:before{content:'';position:absolute;width:18px;height:18px;
                   left:3px;bottom:3px;background:white;border-radius:50%;transition:.2s}
    input:checked + .slider{background:#2d7d46}
    input:checked + .slider:before{transform:translateX(20px)}

    /* BUTTONS */
    .btn{padding:10px 20px;border:none;border-radius:6px;font-size:13px;
         font-weight:600;cursor:pointer;transition:all .15s}
    .btn-primary{background:#2d7d46;color:white}
    .btn-primary:hover{background:#256639}
    .btn-danger{background:#c0392b;color:white}
    .btn-danger:hover{background:#a93226}
    .btn-secondary{background:white;color:#2d7d46;border:1px solid #2d7d46}
    .btn-secondary:hover{background:#f0f7f2}
    .btn-row{display:flex;gap:10px;margin-top:20px;flex-wrap:wrap}

    /* TABLES */
    table{width:100%;border-collapse:collapse}
    th{background:#2d7d46;color:white;padding:10px 14px;text-align:left;
       font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.5px}
    td{padding:9px 14px;font-size:13px;border-bottom:1px solid #f2f4f6;color:#444}
    tr:hover td{background:#f8fdf9}
    tr:last-child td{border-bottom:none}
    td:first-child{color:#999;font-size:12px;white-space:nowrap}
    .yes{color:#2d7d46;font-weight:700}
    .no{color:#c0392b;font-weight:700}
    .warn{color:#e67e22;font-weight:700}

    /* ALERTS */
    .alert{padding:12px 16px;border-radius:6px;font-size:13px;margin-bottom:16px}
    .alert-success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
    .alert-error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
    .alert-info{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}

    /* URL BOX */
    .url-box{background:#f8fafb;border:1px solid #e0e4e8;border-radius:6px;
             padding:10px 14px;font-family:monospace;font-size:12px;color:#333;
             word-break:break-all;margin-top:6px;position:relative}
    .url-label{font-size:11px;font-weight:600;color:#888;text-transform:uppercase;
               letter-spacing:.4px;margin-top:12px;margin-bottom:2px}

    /* LOG VIEWER */
    .log-pre{background:#1e1e2e;color:#cdd6f4;font-family:'Cascadia Code',
             'Consolas',monospace;font-size:12px;padding:16px;border-radius:8px;
             overflow-x:auto;white-space:pre-wrap;word-break:break-all;
             max-height:600px;overflow-y:auto}
    .log-error{color:#f38ba8}
    .log-warn{color:#fab387}
    .log-call{color:#89dceb}
    .log-ws{color:#a6e3a1}
    .log-info{color:#cdd6f4}

    /* CERT UPLOAD */
    .upload-area{border:2px dashed #dce0e5;border-radius:8px;padding:20px;
                 text-align:center;cursor:pointer;transition:all .15s;
                 background:#fafafa}
    .upload-area:hover{border-color:#2d7d46;background:#f0f7f2}
    .upload-area input[type=file]{display:none}
    .upload-area .icon{font-size:28px;margin-bottom:6px}
    .upload-area p{font-size:13px;color:#666}
    .upload-area .fname{font-size:12px;color:#2d7d46;margin-top:4px;font-weight:600}

    .pill{display:inline-block;padding:2px 8px;border-radius:12px;
          font-size:11px;font-weight:600}
    .pill-green{background:#d4edda;color:#155724}
    .pill-red{background:#f8d7da;color:#721c24}
    .pill-gray{background:#e9ecef;color:#495057}
  </style>
</head>
<body>
<nav>
  <span class="brand">&#x1F41B; FieldRoutes CRM for 3CX</span>
  $($navHtml -join '')
</nav>
<div class="page">
  <h1>$Title</h1>
  $Body
</div>
</body>
</html>
"@
}

# ==============================================================================
# CALL LOG HTML TABLE
# ==============================================================================
function Get-CallTableHtml {
    if (-not (Test-Path $CallCsvPath)) {
        return '<p style="color:#999;text-align:center;padding:40px">No calls logged yet.</p>'
    }
    $lines = Get-Content $CallCsvPath -Encoding utf8
    if ($lines.Count -lt 2) {
        return '<p style="color:#999;text-align:center;padding:40px">No calls logged yet.</p>'
    }
    $headers = ($lines[0] -split '","') | ForEach-Object { $_ -replace '"','' }
    $rows    = $lines | Select-Object -Skip 1 | Sort-Object -Descending

    $tableRows = $rows | ForEach-Object {
        $cells = ($_ -split '","') | ForEach-Object { $_ -replace '"','' }
        $tds   = for ($i = 0; $i -lt $cells.Count; $i++) {
            $cls = ''
            if ($headers[$i] -eq 'ExtensionConnected') { $cls = ($cells[$i] -eq 'YES') ? 'yes' : 'no' }
            if ($headers[$i] -eq 'Result') {
                $cls = switch ($cells[$i]) { 'SENT' { 'yes' } 'NO_EXTENSION' { 'no' } default { 'warn' } }
            }
            "<td class=`"$cls`">$($cells[$i])</td>"
        }
        "<tr>$($tds -join '')</tr>"
    }
    $ths = $headers | ForEach-Object { "<th>$_</th>" }
    return "<table><thead><tr>$($ths -join '')</tr></thead><tbody>$($tableRows -join '')</tbody></table>"
}

# ==============================================================================
# SERVER LOG HTML
# ==============================================================================
function Get-ServerLogHtml {
    param([string]$Date = '')
    if (-not $Date) { $Date = Get-Date -Format 'yyyy-MM-dd' }
    $logFile = Join-Path $LogDir "$Date.log"
    if (-not (Test-Path $logFile)) { return "<p style='color:#999'>No log for $Date.</p>" }

    $lines = Get-Content $logFile -Tail 500 -Encoding utf8
    $colored = $lines | ForEach-Object {
        $cls = switch -Regex ($_) {
            '\[ERROR\]' { 'log-error' }
            '\[WARN \]' { 'log-warn'  }
            '\[CALL \]' { 'log-call'  }
            '\[WS   \]' { 'log-ws'    }
            default     { 'log-info'  }
        }
        "<span class=`"$cls`">$([System.Web.HttpUtility]::HtmlEncode($_))</span>"
    }
    return "<pre class='log-pre'>" + ($colored -join "`n") + "</pre>"
}

# ==============================================================================
# START SERVER
# ==============================================================================
$cfg = Read-Config

Write-Log INFO ('=' * 60)
Write-Log INFO 'FieldRoutes CRM for 3CX Middleware starting'
Write-Log INFO "Port     : $($cfg.Port)"
Write-Log INFO "HTTPS    : $($cfg.UseHttps)"
Write-Log INFO "FQDN     : $($cfg.Fqdn)"
Write-Log INFO "Bind     : $($cfg.BindAddress)"
Write-Log INFO ('=' * 60)

if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Error "Pode module not found. Run: Install-Module -Name Pode -Scope AllUsers"
    exit 1
}

Start-PodeServer -Threads 4 {

    $cfg = Read-Config

    # ------------------------------------------------------------------
    # ENDPOINT — HTTP or HTTPS depending on config
    # ------------------------------------------------------------------
    if ($cfg.UseHttps -and $cfg.CertPath -and (Test-Path $cfg.CertPath)) {
        Add-PodeEndpoint -Address $cfg.BindAddress -Port $cfg.Port `
                         -Protocol Https `
                         -Certificate $cfg.CertPath `
                         -CertificatePassword $cfg.CertPassword
        Write-Log INFO "HTTPS endpoint active on port $($cfg.Port)"
    } else {
        Add-PodeEndpoint -Address $cfg.BindAddress -Port $cfg.Port -Protocol Http
        Write-Log INFO "HTTP endpoint active on port $($cfg.Port)"
    }

    # ------------------------------------------------------------------
    # SSE — operator connections
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/sse' -ScriptBlock {
        $agent  = $WebEvent.Query['agent']
        $secret = $WebEvent.Query['secret']
        $cfg    = Read-Config

        if ([string]::IsNullOrWhiteSpace($agent)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeTextResponse -Value 'Missing agent'
            return
        }
        if ($secret -ne $cfg.Secret) {
            Set-PodeResponseStatus -Code 403
            Write-PodeTextResponse -Value 'Forbidden'
            Write-Log WARN "SSE rejected for agent '$agent' — wrong secret"
            return
        }
        ConvertTo-PodeSseConnection -Name 'Operators' -Group $agent
        Write-Log WS "Extension $agent connected (ClientId: $($WebEvent.Sse.ClientId))"
        Send-PodeSseEvent -FromEvent -EventType 'connected' -Data (@{
            status = 'connected'; agent = $agent
            clientId = $WebEvent.Sse.ClientId
            timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Compress)
    }

    # ------------------------------------------------------------------
    # /notify — called by 3CX on answer
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/notify' -ScriptBlock {
        $customerID = $WebEvent.Query['customerID']
        $phone      = $WebEvent.Query['phone']
        $agent      = $WebEvent.Query['agent']
        $clientIP   = $WebEvent.Request.RemoteEndPoint.Address.ToString()

        Write-Log CALL "INBOUND — customerID=`"$customerID`" phone=`"$phone`" agent=`"$agent`" src=$clientIP"

        if ([string]::IsNullOrWhiteSpace($customerID) -and [string]::IsNullOrWhiteSpace($phone)) {
            Set-PodeResponseStatus -Code 400; Write-PodeTextResponse -Value 'Missing customerID or phone'; return
        }

        $payload = @{ type='openCustomer'; customerID=$customerID; phone=$phone
                      agent=$agent; timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    } | ConvertTo-Json -Compress

        $sent = $false
        try {
            Send-PodeSseEvent -Name 'Operators' -Group $agent -EventType 'openCustomer' -Data $payload
            $sent = $true
            Write-Log CALL "DISPATCHED — agent=`"$agent`" customerID=`"$customerID`""
        } catch {
            Write-Log WARN "Dispatch failed for agent '$agent': $_"
        }

        Write-CallCsv -CustomerID $customerID -Phone $phone -Agent $agent `
                      -ExtConnected $sent -Result ($sent ? 'SENT' : 'NO_EXTENSION')

        if ($sent) {
            Write-PodeHtmlResponse -Value @"
<!DOCTYPE html><html><head><title>Opening FieldRoutes...</title>
<style>body{font-family:Arial,sans-serif;text-align:center;padding:40px;background:#f0f4f8}
.box{background:white;border-radius:8px;padding:30px;display:inline-block;box-shadow:0 2px 8px rgba(0,0,0,.1)}
h2{color:#2d7d46;margin:0 0 10px}p{color:#666;margin:0}</style>
<script>setTimeout(()=>window.close(),2000)</script></head>
<body><div class="box"><h2>&#10003; Opening Customer Record</h2>
<p>Opening <strong>$($customerID ? $customerID : $phone)</strong> for operator <strong>$agent</strong>.</p>
<p style="margin-top:10px;font-size:12px;color:#999">This tab will close automatically...</p>
</div></body></html>
"@
        } else {
            Write-Log WARN "NO_EXTENSION — agent '$agent' not connected"
            Write-PodeHtmlResponse -Value @"
<!DOCTYPE html><html><head><title>Not Connected</title>
<style>body{font-family:Arial,sans-serif;text-align:center;padding:40px;background:#f0f4f8}
.box{background:white;border-radius:8px;padding:30px;display:inline-block;box-shadow:0 2px 8px rgba(0,0,0,.1)}
h2{color:#c0392b;margin:0 0 10px}p{color:#666;margin:0}</style></head>
<body><div class="box"><h2>&#9888; Extension Not Connected</h2>
<p>No extension connected for operator <strong>$agent</strong>.</p>
<p style="margin-top:10px">Customer: <strong>$($customerID ? $customerID : $phone)</strong></p>
</div></body></html>
"@
        }
    }

    # ------------------------------------------------------------------
    # /health
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        $cfg = Read-Config
        Write-PodeJsonResponse -Value @{
            status    = 'ok'
            timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            uptime    = (Get-PodeServerUptime).ToString()
            port      = $cfg.Port
            https     = $cfg.UseHttps
            fqdn      = $cfg.Fqdn
        }
    }

    # ------------------------------------------------------------------
    # /calls — call log viewer
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/calls' -ScriptBlock {
        $totalCalls = 0
        if (Test-Path $CallCsvPath) { $totalCalls = [Math]::Max(0, (Get-Content $CallCsvPath).Count - 1) }
        $tableHtml = Get-CallTableHtml

        $body = @"
<div class="subtitle">
  $totalCalls call$(if($totalCalls -ne 1){'s'}) logged &nbsp;&middot;&nbsp;
  Newest first &nbsp;&middot;&nbsp;
  <a href="/calls.csv" download style="color:#2d7d46">Download CSV</a>
</div>
<div class="card" style="padding:0;overflow:hidden">$tableHtml</div>
<meta http-equiv="refresh" content="30">
"@
        Write-PodeHtmlResponse -Value (Get-PageHtml -Title 'Call Log' -Body $body -ActiveNav '/calls')
    }

    # ------------------------------------------------------------------
    # /calls.csv
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/calls.csv' -ScriptBlock {
        if (Test-Path $CallCsvPath) {
            Set-PodeResponseAttachment -Path $CallCsvPath
            Write-PodeFileResponse -Path $CallCsvPath -ContentType 'text/csv'
        } else {
            Set-PodeResponseStatus -Code 404; Write-PodeTextResponse -Value 'No call log yet'
        }
    }

    # ------------------------------------------------------------------
    # /logs — server log viewer
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/logs' -ScriptBlock {
        $selectedDate = $WebEvent.Query['date']
        if (-not $selectedDate) { $selectedDate = Get-Date -Format 'yyyy-MM-dd' }

        # Build date picker options from available log files
        $logFiles = Get-ChildItem -Path $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending
        $dateOptions = $logFiles | ForEach-Object {
            $d = $_.BaseName
            $sel = if ($d -eq $selectedDate) { ' selected' } else { '' }
            "<option value=`"$d`"$sel>$d</option>"
        }

        $logHtml = Get-ServerLogHtml -Date $selectedDate

        $body = @"
<div class="subtitle">Showing last 500 lines &nbsp;&middot;&nbsp; Auto-refreshes every 60 seconds</div>
<div class="card">
  <h2>Select Date</h2>
  <select onchange="location.href='/logs?date='+this.value"
          style="padding:8px 12px;border:1px solid #dce0e5;border-radius:6px;font-size:13px">
    $($dateOptions -join '')
  </select>
</div>
<div class="card" style="padding:0;overflow:hidden">$logHtml</div>
<meta http-equiv="refresh" content="60">
"@
        Write-PodeHtmlResponse -Value (Get-PageHtml -Title 'Server Log' -Body $body -ActiveNav '/logs')
    }

    # ------------------------------------------------------------------
    # /settings — GET (show form)
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/settings' -ScriptBlock {
        $cfg   = Read-Config
        $proto = $cfg.UseHttps ? 'https' : 'http'
        $base  = "${proto}://$($cfg.Fqdn):$($cfg.Port)"

        $httpsChecked  = $cfg.UseHttps ? 'checked' : ''
        $certExists    = ($cfg.CertPath -and (Test-Path $cfg.CertPath)) ? $true : $false
        $certPill      = $certExists `
            ? "<span class='pill pill-green'>&#10003; Certificate loaded</span>" `
            : "<span class='pill pill-red'>No certificate</span>"
        $certFileName  = $certExists ? (Split-Path $cfg.CertPath -Leaf) : 'None'

        $flash = $WebEvent.Query['saved']
        $alertHtml = switch ($flash) {
            'ok'    { "<div class='alert alert-success'>&#10003; Settings saved. Server is restarting — please wait 5 seconds then refresh.</div>" }
            'error' { "<div class='alert alert-error'>&#9888; Error saving settings. Check the server log.</div>" }
            default { '' }
        }

        $body = @"
$alertHtml
<div class="card">
  <h2>Network</h2>
  <form method="POST" action="/settings" enctype="multipart/form-data">

    <div class="field">
      <label>Port</label>
      <input type="number" name="Port" value="$($cfg.Port)" min="1" max="65535">
      <div class="hint">Port the server listens on. Default: 3000. Requires restart.</div>
    </div>

    <div class="field">
      <label>Bind Address</label>
      <input type="text" name="BindAddress" value="$($cfg.BindAddress)" placeholder="* or 192.168.1.50">
      <div class="hint">Use * to listen on all interfaces, or enter a specific IP address.</div>
    </div>

    <div class="field">
      <label>Fully Qualified Domain Name / IP</label>
      <input type="text" name="Fqdn" value="$($cfg.Fqdn)" placeholder="e.g. middleware.yourdomain.com or 192.168.1.50">
      <div class="hint">Used to build the URLs shown below. Does not affect binding.</div>
    </div>
  </div>

  <div class="card">
    <h2>HTTPS / TLS</h2>

    <div class="field">
      <label>Enable HTTPS</label>
      <div class="toggle-row">
        <label class="toggle">
          <input type="checkbox" name="UseHttps" value="true" $httpsChecked id="httpsToggle">
          <span class="slider"></span>
        </label>
        <span style="font-size:13px;color:#555">Use HTTPS instead of HTTP</span>
      </div>
      <div class="hint">Requires a valid PFX certificate. HTTP is fine for internal networks.</div>
    </div>

    <div class="field" id="certSection">
      <label>PFX Certificate File</label>
      <div class="upload-area" onclick="document.getElementById('certFile').click()">
        <input type="file" name="CertFile" id="certFile" accept=".pfx"
               onchange="document.getElementById('certName').textContent=this.files[0]?.name||''">
        <div class="icon">&#x1F4DC;</div>
        <p>Click to upload a PFX certificate</p>
        <p class="fname" id="certName">Currently: $certFileName &nbsp; $certPill</p>
      </div>
      <div class="hint">Leave empty to keep the existing certificate. Upload a new .pfx to replace it.</div>
    </div>

    <div class="field" id="certPassSection">
      <label>Certificate Password</label>
      <input type="password" name="CertPassword" value="" placeholder="Leave blank to keep existing password">
      <div class="hint">Enter the PFX password. Leave blank if unchanged.</div>
    </div>
  </div>

  <div class="card">
    <h2>Security</h2>
    <div class="field">
      <label>Shared Secret</label>
      <input type="text" name="Secret" value="$($cfg.Secret)">
      <div class="hint">Must match the SECRET value in each operator's Chrome extension. Change this after updating all extensions.</div>
    </div>
  </div>

  <div class="card">
    <h2>Logging</h2>
    <div class="field">
      <label>Log Retention (days)</label>
      <input type="number" name="LogRetainDays" value="$($cfg.LogRetainDays)" min="1" max="365">
      <div class="hint">Daily log files older than this are automatically deleted.</div>
    </div>
  </div>

  <div class="card">
    <h2>Current URLs</h2>
    <div class="hint" style="margin-bottom:8px">
      These are the URLs to use based on your current settings. Update your 3CX CRM template and Chrome extensions if these change.
    </div>
    <div class="url-label">SSE Endpoint (Chrome Extension)</div>
    <div class="url-box">$base/sse?agent=[EXTENSION_NUMBER]&amp;secret=$($cfg.Secret)</div>
    <div class="url-label">3CX CRM ContactUrl</div>
    <div class="url-box">$base/notify?customerID=[EntityId]&amp;phone=[Number]&amp;agent=[Agent]</div>
    <div class="url-label">Call Log Viewer</div>
    <div class="url-box">$base/calls</div>
    <div class="url-label">Health Check</div>
    <div class="url-box">$base/health</div>
  </div>

    <div class="btn-row">
      <button type="submit" class="btn btn-primary">&#x1F4BE; Save &amp; Restart Server</button>
      <a href="/calls" class="btn btn-secondary">Cancel</a>
    </div>
  </form>

<script>
  // Show/hide cert fields based on HTTPS toggle
  const toggle = document.getElementById('httpsToggle')
  const certSection = document.getElementById('certSection')
  const certPassSection = document.getElementById('certPassSection')
  function updateCertVisibility() {
    const show = toggle.checked ? 'block' : 'none'
    certSection.style.display = show
    certPassSection.style.display = show
  }
  toggle.addEventListener('change', updateCertVisibility)
  updateCertVisibility()
</script>
"@
        Write-PodeHtmlResponse -Value (Get-PageHtml -Title 'Settings' -Body $body -ActiveNav '/settings')
    }

    # ------------------------------------------------------------------
    # /settings — POST (save and restart)
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Post -Path '/settings' -ScriptBlock {
        try {
            $cfg = Read-Config

            # Update scalar fields
            $cfg.Port          = [int]($WebEvent.Data['Port']          ?? $cfg.Port)
            $cfg.BindAddress   = ($WebEvent.Data['BindAddress']         ?? $cfg.BindAddress).Trim()
            $cfg.Fqdn          = ($WebEvent.Data['Fqdn']               ?? $cfg.Fqdn).Trim()
            $cfg.UseHttps      = ($WebEvent.Data['UseHttps']            -eq 'true')
            $cfg.Secret        = ($WebEvent.Data['Secret']             ?? $cfg.Secret).Trim()
            $cfg.LogRetainDays = [int]($WebEvent.Data['LogRetainDays'] ?? $cfg.LogRetainDays)

            # Handle certificate upload
            $certFile = $WebEvent.Files['CertFile']
            if ($certFile -and $certFile.FileName -match '\.pfx$') {
                $destPath = Join-Path $CertsDir $certFile.FileName
                [System.IO.File]::WriteAllBytes($destPath, $certFile.Bytes)
                $cfg.CertPath = $destPath
                Write-Log INFO "Certificate uploaded: $destPath"
            }

            # Update password only if a new one was provided
            $newPass = ($WebEvent.Data['CertPassword'] ?? '').Trim()
            if ($newPass) { $cfg.CertPassword = $newPass }

            Save-Config $cfg
            Write-Log INFO "Settings saved — scheduling restart"

            # Respond first, then restart so the browser gets the redirect
            Move-PodeResponseUrl -Url '/settings?saved=ok'

            # Restart after a short delay so the redirect response reaches the browser
            Start-Job -ScriptBlock {
                Start-Sleep -Seconds 2
                Restart-PodeServer
            } | Out-Null

        } catch {
            Write-Log ERROR "Settings save failed: $_"
            Move-PodeResponseUrl -Url '/settings?saved=error'
        }
    }

    # ------------------------------------------------------------------
    # /certificate — Let's Encrypt certificate management (GET)
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/certificate' -ScriptBlock {
        $cfg         = Read-Config
        $certLogPath = Join-Path $using:LogDir 'cert-renewal.log'

        # ---------- Current cert status card ----------
        $certCard = ''
        if ($cfg.CertPath -and (Test-Path $cfg.CertPath)) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($cfg.CertPath)
                $pfx   = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                             $bytes, $cfg.CertPassword,
                             [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
                $days  = [int]($pfx.NotAfter - (Get-Date)).TotalDays
                $cls   = if ($days -lt 14) { 'no' } elseif ($days -lt 30) { 'warn' } else { 'yes' }
                $certCard = @"
<div class='card'>
  <div class='card-header'><h2>Current Certificate</h2></div>
  <div class='card-body'>
    <table style='border-collapse:collapse'>
      <tr><td class='kl'>Subject</td>      <td>$($pfx.Subject)</td></tr>
      <tr><td class='kl'>Issued By</td>    <td>$($pfx.Issuer)</td></tr>
      <tr><td class='kl'>Valid From</td>   <td>$($pfx.NotBefore.ToString('yyyy-MM-dd'))</td></tr>
      <tr><td class='kl'>Expires</td>      <td>$($pfx.NotAfter.ToString('yyyy-MM-dd'))</td></tr>
      <tr><td class='kl'>Days Left</td>    <td class='$cls' style='font-weight:700'>$days days</td></tr>
      <tr><td class='kl'>Thumbprint</td>   <td style='font-family:monospace;font-size:12px'>$($pfx.Thumbprint)</td></tr>
      <tr><td class='kl'>PFX Path</td>     <td style='font-family:monospace;font-size:12px'>$($cfg.CertPath)</td></tr>
    </table>
  </div>
</div>
"@
            } catch {
                $certCard = "<div class='alert alert-error'>Cannot read certificate: $_</div>"
            }
        } else {
            $certCard = "<div class='alert alert-info' style='margin-bottom:16px'>
              &#8505;&nbsp; No certificate loaded yet. Configure below and click <strong>Request Certificate</strong>.</div>"
        }

        # ---------- Renewal log ----------
        $logContent = '<p style="color:#aaa;padding:20px 16px;font-size:13px">No renewal log yet.</p>'
        if (Test-Path $certLogPath) {
            $lines   = Get-Content $certLogPath -Tail 120 -Encoding utf8
            $colored = $lines | ForEach-Object {
                $cls = switch -Regex ($_) {
                    '\[ERROR\]' { 'log-error' }
                    '\[WARN \]' { 'log-warn'  }
                    '\[OK   \]' { 'log-ws'    }
                    default     { 'log-info'  }
                }
                "<span class='$cls'>$([System.Web.HttpUtility]::HtmlEncode($_))</span>"
            }
            $logContent = "<pre class='log-pre' style='max-height:320px;border-radius:0'>" +
                          ($colored -join "`n") + "</pre>"
        }

        # ---------- Form state ----------
        $heChecked  = if ($cfg.AcmePlugin -ne 'HurricaneElectricDyn') { 'checked' } else { '' }
        $dynChecked = if ($cfg.AcmePlugin -eq 'HurricaneElectricDyn')  { 'checked' } else { '' }

        $dynExisting = ''
        if ($cfg.AcmeHEDynRecords -and @($cfg.AcmeHEDynRecords).Count -gt 0) {
            $dynExisting = (@($cfg.AcmeHEDynRecords) | ForEach-Object { "$($_.Record)=" }) -join "`n"
        }

        # Deployment type selection
        $deployTypes = @(
            @{ value='PodePfx';       label='Pode PFX (Default)';
               desc='Exports a PFX to the certs/ folder and updates config.json. Pode loads it on next restart. No admin rights needed. Best choice for most setups.' }
            @{ value='WinCertStore';  label='Windows Certificate Store';
               desc='Also installs the certificate into LocalMachine\My using Posh-ACME.Deploy Install-PACertificate. Good when other Windows services (e.g. RDP, WinRM) need the same cert.' }
            @{ value='IIS';           label='IIS Binding';
               desc='Deploys to an IIS site binding via Posh-ACME.Deploy Set-IISCertificate. Use when this server also hosts an IIS website on the same domain.' }
        )
        $deployOptions = $deployTypes | ForEach-Object {
            $sel = if ($cfg.DeployType -eq $_.value) { 'checked' } else { '' }
            @"
<label class='deploy-opt $(if($sel){"deploy-sel"})'>
  <input type='radio' name='DeployType' value='$($_.value)' $sel onchange='updateDeploy()'>
  <div><strong>$($_.label)</strong><div class='opt-desc'>$($_.desc)</div></div>
</label>
"@
        }

        $iisVis   = if ($cfg.DeployType -eq 'IIS') { '' } else { "style='display:none'" }
        $stageSel = if ($cfg.AcmeUseStaging) { 'checked' } else { '' }

        $flash = $WebEvent.Query['saved']
        $alertHtml = switch ($flash) {
            'ok'      { "<div class='alert alert-success'>&#10003; Configuration saved.</div>" }
            'renewed' { "<div class='alert alert-success'>&#10003; Renewal job launched. Watch the log below — refresh in ~60 seconds.</div>" }
            'task'    { "<div class='alert alert-success'>&#10003; Auto-renewal scheduled task installed (runs daily at 03:00).</div>" }
            'error'   { "<div class='alert alert-error'>&#9888; Something went wrong. Check the renewal log below.</div>" }
            default   { '' }
        }

        $domainHint = $cfg.AcmeDomain ? $cfg.AcmeDomain : 'yourdomain.com'

        $body = @"
<style>
  .kl{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;
      color:#8fa090;padding-right:28px;padding-bottom:10px;white-space:nowrap;vertical-align:top}
  .card-header{padding:12px 20px;border-bottom:1px solid #dde5de;
               display:flex;align-items:center;justify-content:space-between}
  .card-header h2{font-size:10px;font-weight:700;text-transform:uppercase;
                  letter-spacing:.8px;color:#8fa090;margin:0}
  .card-body{padding:20px}
  .card{background:white;border:1px solid #dde5de;border-radius:8px;
        box-shadow:0 1px 3px rgba(0,0,0,.05);margin-bottom:16px;overflow:hidden}
  .field{margin-bottom:16px}
  .field label.flabel{display:block;font-size:11px;font-weight:700;text-transform:uppercase;
                      letter-spacing:.5px;color:#8fa090;margin-bottom:5px}
  .field input[type=text],.field input[type=number],.field input[type=password],
  .field textarea{width:100%;padding:9px 12px;border:1px solid #dde5de;border-radius:6px;
                  font-size:13px;font-family:inherit;background:#f8faf8;color:#1c2b1e;
                  outline:none;transition:border-color .15s}
  .field input:focus,.field textarea:focus{border-color:#2d7d46;background:white}
  .field .hint{font-size:11px;color:#8fa090;margin-top:4px;line-height:1.5}
  .section-head{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:1px;
                color:#8fa090;margin:22px 0 10px;display:flex;align-items:center;gap:10px}
  .section-head::after{content:'';flex:1;height:1px;background:#dde5de}

  /* Plugin radio options */
  .plugin-opt{display:flex;gap:10px;align-items:flex-start;cursor:pointer;
              background:#f8faf8;border:1px solid #dde5de;border-radius:7px;
              padding:12px 14px;margin-bottom:8px;transition:border-color .15s}
  .plugin-opt:hover{border-color:#2d7d46}
  .plugin-opt.plugin-sel{border-color:#2d7d46;background:#f0f7f2}
  .plugin-opt input{margin-top:3px;flex-shrink:0;accent-color:#2d7d46}
  .plugin-opt strong{font-size:13px;color:#1c2b1e}
  .plugin-opt .badge{font-size:10px;font-weight:700;padding:1px 6px;border-radius:10px;
                     background:#d4edda;color:#155724;margin-left:6px}
  .opt-desc{font-size:12px;color:#4a5e4d;margin-top:3px;line-height:1.5}

  /* Deploy type options */
  .deploy-opt{display:flex;gap:10px;align-items:flex-start;cursor:pointer;
              background:#f8faf8;border:1px solid #dde5de;border-radius:7px;
              padding:12px 14px;margin-bottom:8px;transition:border-color .15s}
  .deploy-opt:hover{border-color:#2d7d46}
  .deploy-opt.deploy-sel{border-color:#2d7d46;background:#f0f7f2}
  .deploy-opt input{margin-top:3px;flex-shrink:0;accent-color:#2d7d46}
  .deploy-opt strong{font-size:13px;color:#1c2b1e}

  /* Info/warning boxes */
  .info-box{border-radius:6px;padding:11px 14px;font-size:12px;line-height:1.5;margin-bottom:12px}
  .info-blue{background:#e3f2fd;border:1px solid #90caf9;color:#0d47a1}
  .info-amber{background:#fff8e1;border:1px solid #ffe082;color:#5d4037}

  /* Buttons */
  .btn{padding:9px 18px;border:none;border-radius:6px;font-size:13px;font-weight:600;
       font-family:inherit;cursor:pointer;transition:all .15s}
  .btn-primary{background:#2d7d46;color:white}
  .btn-primary:hover{background:#1a5c32}
  .btn-secondary{background:white;color:#2d7d46;border:1px solid #2d7d46}
  .btn-secondary:hover{background:#f0f7f2}
  .btn-danger{background:#c0392b;color:white}
  .btn-danger:hover{background:#a93226}
  .btn-row{display:flex;gap:10px;margin-top:20px;flex-wrap:wrap}
  .alert{padding:11px 15px;border-radius:6px;font-size:13px;margin-bottom:16px}
  .alert-success{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
  .alert-error{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
  .alert-info{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}
  .yes{color:#2d7d46} .no{color:#c0392b} .warn{color:#d68910}
  .log-pre{background:#0d1117;color:#e6edf3;font-family:Consolas,monospace;
           font-size:12px;padding:16px;white-space:pre-wrap;word-break:break-all;
           line-height:1.6;overflow-y:auto}
  .log-error{color:#ff7b72} .log-warn{color:#ffa657} .log-ws{color:#56d364} .log-info{color:#e6edf3}
</style>

$alertHtml
$certCard

<div class='card'>
  <div class='card-header'><h2>Let's Encrypt Configuration</h2></div>
  <div class='card-body'>
  <form method='POST' action='/certificate'>

    <div class='section-head'>Contact &amp; Domain</div>
    <div class='field'>
      <label class='flabel'>Contact Email</label>
      <input type='text' name='AcmeContact' value='$($cfg.AcmeContact)' placeholder='admin@yourdomain.com'>
      <div class='hint'>Let's Encrypt sends expiry warnings to this address. Required for account creation.</div>
    </div>
    <div class='field'>
      <label class='flabel'>Domain (FQDN)</label>
      <input type='text' name='AcmeDomain' value='$($cfg.AcmeDomain)' placeholder='middleware.yourdomain.com'>
      <div class='hint'>The exact domain for the certificate. Must be publicly resolvable to this server's IP address.</div>
    </div>
    <div class='field'>
      <label class='flabel'>PFX Password</label>
      <input type='password' name='CertPassword' placeholder='Leave blank to keep existing ($($cfg.CertPassword ? "set" : "not set"))'>
      <div class='hint'>Password for the exported PFX file. Pode uses this to load the certificate on startup.</div>
    </div>

    <div style='display:flex;align-items:center;gap:10px;margin-bottom:0'>
      <label style='display:flex;align-items:center;gap:8px;cursor:pointer;font-size:13px;color:#4a5e4d'>
        <input type='checkbox' name='AcmeUseStaging' value='true' $stageSel style='accent-color:#d68910'>
        Use Let's Encrypt <strong>staging</strong> CA (for testing — issues untrusted certs, won't hit rate limits)
      </label>
    </div>

    <div class='section-head' style='margin-top:22px'>Hurricane Electric DNS Plugin</div>

    <label class='plugin-opt $(if($heChecked){"plugin-sel"})' onclick='setPl(this,"HurricaneElectric")'>
      <input type='radio' name='AcmePlugin' value='HurricaneElectric' $heChecked
             onchange='updatePluginVis()'>
      <div>
        <strong>HurricaneElectric</strong>
        <span style='font-size:11px;color:#8fa090;margin-left:6px'>Web scraping</span>
        <div class='opt-desc'>Logs in to dns.he.net with your HE account username and password to add
        the DNS challenge record. Simplest to set up — nothing to pre-configure in the HE portal.
        Slightly fragile if HE ever changes their page markup.</div>
      </div>
    </label>

    <label class='plugin-opt $(if($dynChecked){"plugin-sel"})' onclick='setPl(this,"HurricaneElectricDyn")'>
      <input type='radio' name='AcmePlugin' value='HurricaneElectricDyn' $dynChecked
             onchange='updatePluginVis()'>
      <div>
        <strong>HurricaneElectricDyn</strong>
        <span class='badge'>Recommended</span>
        <div class='opt-desc'>Uses HE's DynDNS API with a per-record key instead of your main
        account password. More secure and more reliable long-term. Requires creating an
        <code style='background:#f0f4f1;padding:1px 4px;border-radius:3px'>_acme-challenge</code>
        TXT record in the HE portal with Dynamic DNS enabled before first use.</div>
      </div>
    </label>

    <!-- HurricaneElectric fields -->
    <div id='heFields'>
      <div class='info-box info-amber'>
        &#9888; Your main HE account password will be stored encrypted in config.json.
        Consider switching to HurricaneElectricDyn for better security.
      </div>
      <div class='field'>
        <label class='flabel'>HE Account Username</label>
        <input type='text' name='AcmeHEUser' value='$($cfg.AcmeHEUser)' placeholder='you@example.com or username'>
      </div>
      <div class='field'>
        <label class='flabel'>HE Account Password</label>
        <input type='password' name='AcmeHEPass' placeholder='$(if($cfg.AcmeHEPass){"Already set — leave blank to keep"}else{"Enter HE password"})'>
      </div>
    </div>

    <!-- HurricaneElectricDyn fields -->
    <div id='dynFields' style='display:none'>
      <div class='info-box info-blue'>
        <strong>Pre-requisite:</strong> In <a href='https://dns.he.net' target='_blank' style='color:#0d47a1'>dns.he.net</a>
        go to <em>Edit Zone</em> for your domain, add a TXT record named
        <code style='background:rgba(0,0,0,.08);padding:1px 5px;border-radius:3px'>_acme-challenge.$domainHint</code>,
        enable <em>Dynamic DNS</em> on it, then click <em>Generate a key</em>. Paste the record name and key below.
      </div>
      <div class='field'>
        <label class='flabel'>DynDNS Records — one per line: <code style='text-transform:none;font-weight:400'>recordname=ddnskey</code></label>
        <textarea name='AcmeHEDynRecords' rows='3'
                  placeholder='_acme-challenge.$domainHint=your-ddns-key'>$dynExisting</textarea>
        <div class='hint'>
          Enter one record per line in the format <code>recordname=password</code>.<br>
          Add a second line if you need a wildcard cert (requires two <code>_acme-challenge</code> records).<br>
          Existing passwords shown blank — re-enter only if changing.
        </div>
      </div>
    </div>

    <div class='section-head'>Deployment Type</div>
    <div class='hint' style='margin-bottom:10px'>
      What happens after Let's Encrypt issues the certificate.
    </div>

    $($deployOptions -join '')

    <!-- IIS extra fields, shown only when IIS selected -->
    <div id='iisFields' $iisVis>
      <div class='info-box info-blue' style='margin-top:8px'>
        Requires the <code>WebAdministration</code> module and admin rights.
        Posh-ACME.Deploy's <code>Set-IISCertificate</code> will update the HTTPS binding automatically.
      </div>
      <div style='display:grid;grid-template-columns:1fr 1fr 120px;gap:12px'>
        <div class='field'>
          <label class='flabel'>IIS Site Name</label>
          <input type='text' name='IISSiteName' value='$($cfg.IISSiteName)'>
        </div>
        <div class='field'>
          <label class='flabel'>IP Address</label>
          <input type='text' name='IISIPAddress' value='$($cfg.IISIPAddress)' placeholder='*'>
        </div>
        <div class='field'>
          <label class='flabel'>Port</label>
          <input type='number' name='IISPort' value='$($cfg.IISPort)' min='1' max='65535'>
        </div>
      </div>
    </div>

    <div class='btn-row'>
      <button type='submit' name='action' value='save' class='btn btn-primary'>
        &#x1F4BE; Save Configuration
      </button>
      <button type='submit' name='action' value='renew' class='btn btn-secondary'
              onclick="return confirm('Request or renew the certificate now?\n\nThis will take 1-2 minutes while DNS propagates.')">
        &#x1F512; Request / Renew Now
      </button>
      <button type='submit' name='action' value='force' class='btn btn-secondary'
              style='border-color:#c0392b;color:#c0392b'
              onclick="return confirm('Force renewal even if the cert is not yet due?')">
        &#x21BA; Force Renew
      </button>
      <button type='submit' name='action' value='task' class='btn btn-secondary'
              onclick="return confirm('Install Windows scheduled task?\n\nRuns daily at 03:00 as SYSTEM. Requires admin rights.')">
        &#x23F0; Install Auto-Renewal Task
      </button>
    </div>

  </form>
  </div>
</div>

<div class='card'>
  <div class='card-header'>
    <h2>Renewal Log</h2>
    <span style='font-size:11px;color:#8fa090'>cert-renewal.log — last 120 lines</span>
  </div>
  $logContent
</div>

<script>
function updatePluginVis() {
  const dyn = document.querySelector('input[value=HurricaneElectricDyn]').checked
  document.getElementById('heFields').style.display  = dyn ? 'none'  : 'block'
  document.getElementById('dynFields').style.display = dyn ? 'block' : 'none'
}
function setPl(el, val) {
  document.querySelectorAll('.plugin-opt').forEach(o => o.classList.remove('plugin-sel'))
  el.classList.add('plugin-sel')
}
function updateDeploy() {
  const iis = document.querySelector('input[name=DeployType]:checked')?.value === 'IIS'
  document.getElementById('iisFields').style.display = iis ? 'block' : 'none'
  document.querySelectorAll('.deploy-opt').forEach(o => {
    o.classList.toggle('deploy-sel', o.querySelector('input').checked)
  })
}
document.querySelectorAll('.deploy-opt input').forEach(r => r.addEventListener('change', updateDeploy))
updatePluginVis()
</script>
"@
        Write-PodeHtmlResponse -Value (Get-PageHtml -Title 'Certificate' -Body $body -ActiveNav '/certificate')
    }

    # ------------------------------------------------------------------
    # /certificate POST — save config and/or trigger renewal
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Post -Path '/certificate' -ScriptBlock {
        try {
            $cfg    = Read-Config
            $action = ($WebEvent.Data['action'] ?? 'save').Trim()

            # --- Update scalar fields ---
            if ($WebEvent.Data['AcmeContact']) { $cfg.AcmeContact = $WebEvent.Data['AcmeContact'].Trim() }
            if ($WebEvent.Data['AcmeDomain'])  {
                $cfg.AcmeDomain = $WebEvent.Data['AcmeDomain'].Trim()
                $cfg.Fqdn       = $cfg.AcmeDomain
            }
            if ($WebEvent.Data['AcmePlugin'])  { $cfg.AcmePlugin   = $WebEvent.Data['AcmePlugin'] }
            if ($WebEvent.Data['DeployType'])   { $cfg.DeployType   = $WebEvent.Data['DeployType'] }
            if ($WebEvent.Data['IISSiteName'])  { $cfg.IISSiteName  = $WebEvent.Data['IISSiteName'].Trim() }
            if ($WebEvent.Data['IISIPAddress']) { $cfg.IISIPAddress = $WebEvent.Data['IISIPAddress'].Trim() }
            if ($WebEvent.Data['IISPort'])      { $cfg.IISPort      = [int]$WebEvent.Data['IISPort'] }
            $cfg.AcmeUseStaging = ($WebEvent.Data['AcmeUseStaging'] -eq 'true')

            $newPass = ($WebEvent.Data['CertPassword'] ?? '').Trim()
            if ($newPass) { $cfg.CertPassword = $newPass }

            # --- DNS plugin credentials ---
            if ($cfg.AcmePlugin -eq 'HurricaneElectric') {
                if ($WebEvent.Data['AcmeHEUser']) { $cfg.AcmeHEUser = $WebEvent.Data['AcmeHEUser'].Trim() }
                if ($WebEvent.Data['AcmeHEPass']) { $cfg.AcmeHEPass = $WebEvent.Data['AcmeHEPass'] }
            } else {
                $raw  = ($WebEvent.Data['AcmeHEDynRecords'] ?? '').Trim() -split "`n"
                $recs = $raw | Where-Object { $_ -match '=.+' } | ForEach-Object {
                    $p = $_.Trim() -split '=', 2
                    if ($p.Count -eq 2 -and $p[1]) { @{ Record = $p[0].Trim(); Password = $p[1].Trim() } }
                }
                if ($recs -and @($recs).Count -gt 0) { $cfg.AcmeHEDynRecords = @($recs) }
            }

            Save-Config $cfg
            Write-Log INFO "Certificate config saved (action=$action plugin=$($cfg.AcmePlugin) deploy=$($cfg.DeployType))"

            if ($action -eq 'save') {
                Move-PodeResponseUrl -Url '/certificate?saved=ok'
                return
            }

            if ($action -eq 'task') {
                # Install scheduled task
                $script = Join-Path $using:ScriptRoot 'Invoke-CertificateRenewal.ps1'
                Start-Job -ScriptBlock {
                    param($s)
                    & pwsh -NonInteractive -File $s -InstallTask
                } -ArgumentList $script | Out-Null
                Move-PodeResponseUrl -Url '/certificate?saved=task'
                return
            }

            # Launch renewal as background job
            $forceFlag = ($action -eq 'force')
            $script    = Join-Path $using:ScriptRoot 'Invoke-CertificateRenewal.ps1'
            Start-Job -ScriptBlock {
                param($s, $f)
                $a = @('-NonInteractive', '-File', $s)
                if ($f) { $a += '-Force' }
                & pwsh @a
            } -ArgumentList $script, $forceFlag | Out-Null

            Write-Log INFO "Certificate renewal job launched (Force=$forceFlag)"
            Move-PodeResponseUrl -Url '/certificate?saved=renewed'

        } catch {
            Write-Log ERROR "Certificate POST error: $_"
            Move-PodeResponseUrl -Url '/certificate?saved=error'
        }
    }

    # ------------------------------------------------------------------
    # Root redirect to /calls
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Move-PodeResponseUrl -Url '/calls'
    }

    # ------------------------------------------------------------------
    # Restart-pending watcher
    # Invoke-CertificateRenewal.ps1 writes .restart-pending after
    # deploying a new certificate. This timer checks every 30 seconds
    # and restarts Pode so it loads the new PFX from disk.
    # ------------------------------------------------------------------
    $restartFlagPath = Join-Path $DataRoot '.restart-pending'
    Add-PodeTimer -Name 'CertRestartWatcher' -Interval 30 -ScriptBlock {
        $flag = $using:restartFlagPath
        if (Test-Path $flag) {
            $written = Get-Content $flag -Raw
            Write-Log INFO "Restart flag detected (written $written) — restarting to load new certificate"
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Restart-PodeServer
        }
    }

    # ------------------------------------------------------------------
    # Startup log
    # ------------------------------------------------------------------
    $proto = $cfg.UseHttps ? 'https' : 'http'
    $base  = "${proto}://$($cfg.Fqdn):$($cfg.Port)"
    Write-Log INFO "Admin UI        : $base/settings"
    Write-Log INFO "Certificate     : $base/certificate"
    Write-Log INFO "Call log        : $base/calls"
    Write-Log INFO "Server log      : $base/logs"
    Write-Log INFO "Health check    : $base/health"
    Write-Log INFO "3CX ContactUrl  : $base/notify?customerID=[EntityId]&phone=[Number]&agent=[Agent]"
}
