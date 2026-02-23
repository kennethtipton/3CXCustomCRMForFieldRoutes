# ==============================================================================
# PestRoutes 3CX Popup Middleware — Pode/PowerShell Edition
# ==============================================================================
# No Node.js required. Runs entirely in PowerShell using the Pode module.
#
# INSTALL:
#   1. Install-Module -Name Pode -Scope CurrentUser   (one time)
#   2. Edit the CONFIGURATION section below
#   3. Run:  pwsh .\Start-PestRoutesMiddleware.ps1
#      OR install as a Windows service — see README.md
#
# HOW IT WORKS:
#   Each operator's Chrome extension opens a persistent SSE connection to:
#     GET http://SERVER:3000/sse?agent=101
#   Pode registers this as an SSE connection named 'Operators', grouped by
#   the agent's 3CX extension number.
#
#   When 3CX fires the ContactUrl on answer:
#     GET http://SERVER:3000/notify?customerID=12345&phone=5551234567&agent=101
#   The /notify route calls Send-PodeSseEvent targeting Group '101', which
#   pushes the event directly to that operator's Chrome extension.
#   The extension then automates PestRoutes to open the customer popup.
# ==============================================================================

# ==============================================================================
# CONFIGURATION
# ==============================================================================
$HTTP_PORT  = 3000
$SECRET     = 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING'   # Must match extension config
$LOG_DIR    = Join-Path $PSScriptRoot 'logs'
$LOG_RETAIN_DAYS = 30

# ==============================================================================
# PRE-FLIGHT
# ==============================================================================
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Error "Pode module not found. Run: Install-Module -Name Pode -Scope CurrentUser"
    exit 1
}

if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

# ==============================================================================
# LOGGING HELPERS
# ==============================================================================
$CallCsvPath = Join-Path $LOG_DIR 'calls.csv'

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$($Level.PadRight(5))] $Message"

    # Console
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red    }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'CALL'  { Write-Host $line -ForegroundColor Cyan   }
        'WS'    { Write-Host $line -ForegroundColor Green  }
        default { Write-Host $line }
    }

    # Daily log file
    $dateStr  = Get-Date -Format 'yyyy-MM-dd'
    $logFile  = Join-Path $LOG_DIR "$dateStr.log"
    $line | Out-File -FilePath $logFile -Append -Encoding utf8

    # Purge old logs (runs cheap — only removes when file count exceeds limit)
    $logFiles = Get-ChildItem -Path $LOG_DIR -Filter '*.log' |
                Sort-Object LastWriteTime -Descending
    if ($logFiles.Count -gt $LOG_RETAIN_DAYS) {
        $logFiles | Select-Object -Skip $LOG_RETAIN_DAYS | Remove-Item -Force
    }
}

function Write-CallCsv {
    param(
        [string]$CustomerID,
        [string]$Phone,
        [string]$Agent,
        [bool]  $ExtConnected,
        [string]$Result
    )
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
# CALL LOG HTML VIEWER  (embedded, generated on request)
# ==============================================================================
function Get-CallLogHtml {
    if (-not (Test-Path $CallCsvPath)) {
        return '<p style="color:#999;text-align:center;padding:40px">No calls logged yet.</p>'
    }
    $lines   = Get-Content $CallCsvPath -Encoding utf8
    $headers = ($lines[0] -split '","') | ForEach-Object { $_ -replace '"','' }
    $rows    = $lines | Select-Object -Skip 1 | Sort-Object -Descending   # newest first

    $tableRows = $rows | ForEach-Object {
        $cells = ($_ -split '","') | ForEach-Object { $_ -replace '"','' }
        $tds   = for ($i = 0; $i -lt $cells.Count; $i++) {
            $cls = ''
            if ($headers[$i] -eq 'ExtensionConnected') {
                $cls = ($cells[$i] -eq 'YES') ? 'yes' : 'no'
            }
            if ($headers[$i] -eq 'Result') {
                $cls = switch ($cells[$i]) {
                    'SENT'         { 'yes'  }
                    'NO_EXTENSION' { 'no'   }
                    default        { 'warn' }
                }
            }
            "<td class=`"$cls`">$($cells[$i])</td>"
        }
        "<tr>$($tds -join '')</tr>"
    }

    $ths = $headers | ForEach-Object { "<th>$_</th>" }

    return @"
<table>
  <thead><tr>$($ths -join '')</tr></thead>
  <tbody>$($tableRows -join '')</tbody>
</table>
"@
}

# ==============================================================================
# PODE SERVER
# ==============================================================================
Write-Log INFO ('=' * 60)
Write-Log INFO 'PestRoutes Popup Middleware (Pode/PowerShell) starting'
Write-Log INFO "Log directory : $LOG_DIR"
Write-Log INFO "Log retention : $LOG_RETAIN_DAYS days"
Write-Log INFO ('=' * 60)

Start-PodeServer -Threads 4 {

    # ------------------------------------------------------------------
    # Endpoint
    # ------------------------------------------------------------------
    Add-PodeEndpoint -Address * -Port $using:HTTP_PORT -Protocol Http
    Write-Log INFO "HTTP server listening on port $($using:HTTP_PORT)"

    # ------------------------------------------------------------------
    # SSE — per-operator connections
    #
    # Each Chrome extension calls:
    #   GET /sse?agent=101&secret=XXXX
    #
    # Pode registers it as:
    #   Name  = 'Operators'
    #   Group = '101'          ← the 3CX extension number
    #
    # To push to a specific operator later:
    #   Send-PodeSseEvent -Name 'Operators' -Group '101' -Data '...'
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/sse' -ScriptBlock {
        $agent  = $WebEvent.Query['agent']
        $secret = $WebEvent.Query['secret']

        if ([string]::IsNullOrWhiteSpace($agent)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeTextResponse -Value 'Missing agent parameter'
            return
        }

        if ($secret -ne $using:SECRET) {
            Set-PodeResponseStatus -Code 403
            Write-PodeTextResponse -Value 'Forbidden'
            Write-Log WARN "SSE connection rejected for agent '$agent' — wrong secret"
            return
        }

        # Convert this HTTP request into a persistent SSE connection.
        # Name='Operators', Group=agent extension number.
        # Pode handles the connection lifetime automatically.
        ConvertTo-PodeSseConnection -Name 'Operators' -Group $agent

        Write-Log WS "Extension $agent connected via SSE (ClientId: $($WebEvent.Sse.ClientId))"

        # Send an immediate confirmation event so the extension knows it's live
        Send-PodeSseEvent -FromEvent -EventType 'connected' -Data (@{
            status    = 'connected'
            agent     = $agent
            clientId  = $WebEvent.Sse.ClientId
            timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Compress)
    }

    # ------------------------------------------------------------------
    # /notify — called by 3CX ContactUrl when operator answers a call
    #
    # URL format:
    #   http://SERVER:3000/notify?customerID=[EntityId]&phone=[Number]&agent=[Agent]
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/notify' -ScriptBlock {
        $customerID = $WebEvent.Query['customerID']
        $phone      = $WebEvent.Query['phone']
        $agent      = $WebEvent.Query['agent']
        $clientIP   = $WebEvent.Request.RemoteEndPoint.Address.ToString()

        Write-Log CALL "INBOUND — customerID=`"$customerID`" phone=`"$phone`" agent=`"$agent`" src=$clientIP"

        if ([string]::IsNullOrWhiteSpace($customerID) -and [string]::IsNullOrWhiteSpace($phone)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeTextResponse -Value 'Missing customerID or phone'
            return
        }

        # Check if this agent has an active SSE connection
        # Test-PodeSseName checks whether the Name exists and has connections
        $agentConnected = Test-PodeSseName -Name 'Operators' # Name exists check
        # Refine: check if the specific group (agent) has any connections
        # We attempt to send and catch — or use Get-PodeServerActiveSignalMetric
        # The cleanest approach: send the event and let Pode handle silently if no connection

        # Build the event payload
        $payload = @{
            type       = 'openCustomer'
            customerID = $customerID
            phone      = $phone
            agent      = $agent
            timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Compress

        # Send SSE event to the specific operator's Group
        # If no connection exists for this group, Pode silently skips it
        $sent = $false
        try {
            Send-PodeSseEvent -Name 'Operators' -Group $agent `
                              -EventType 'openCustomer' -Data $payload
            $sent = $true
            Write-Log CALL "DISPATCHED — agent=`"$agent`" customerID=`"$customerID`" phone=`"$phone`""
        }
        catch {
            Write-Log WARN "Send-PodeSseEvent failed for agent '$agent': $_"
        }

        Write-CallCsv -CustomerID $customerID -Phone $phone -Agent $agent `
                      -ExtConnected $sent -Result ($sent ? 'SENT' : 'NO_EXTENSION')

        if ($sent) {
            Write-PodeHtmlResponse -Value @"
<!DOCTYPE html><html><head>
<title>Opening PestRoutes...</title>
<style>
  body{font-family:Arial,sans-serif;text-align:center;padding:40px;background:#f0f4f8}
  .box{background:white;border-radius:8px;padding:30px;display:inline-block;
       box-shadow:0 2px 8px rgba(0,0,0,.1)}
  h2{color:#2d7d46;margin:0 0 10px}p{color:#666;margin:0}
</style>
<script>setTimeout(()=>window.close(),2000)</script>
</head><body><div class="box">
  <h2>&#10003; Opening Customer Record</h2>
  <p>PestRoutes is opening customer <strong>$($customerID ? $customerID : $phone)</strong>
     for operator <strong>$agent</strong>.</p>
  <p style="margin-top:10px;font-size:12px;color:#999">This tab will close automatically...</p>
</div></body></html>
"@
        } else {
            Write-Log WARN "NO_EXTENSION — agent=`"$agent`" has no SSE connection"
            Write-PodeHtmlResponse -Value @"
<!DOCTYPE html><html><head>
<title>Operator Not Connected</title>
<style>
  body{font-family:Arial,sans-serif;text-align:center;padding:40px;background:#f0f4f8}
  .box{background:white;border-radius:8px;padding:30px;display:inline-block;
       box-shadow:0 2px 8px rgba(0,0,0,.1)}
  h2{color:#c0392b;margin:0 0 10px}p{color:#666;margin:0}
</style>
</head><body><div class="box">
  <h2>&#9888; Extension Not Connected</h2>
  <p>Chrome extension for operator <strong>$agent</strong> is not connected.</p>
  <p style="margin-top:10px">Customer: <strong>$($customerID ? $customerID : $phone)</strong></p>
  <p style="margin-top:10px;font-size:12px;color:#999">
    Make sure the PestRoutes Helper extension is installed and active in Chrome.</p>
</div></body></html>
"@
        }
    }

    # ------------------------------------------------------------------
    # /health — JSON status
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        Write-PodeJsonResponse -Value @{
            status    = 'ok'
            timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            uptime    = (Get-PodeServerUptime).ToString()
            logDir    = $using:LOG_DIR
            callLog   = $using:CallCsvPath
        }
    }

    # ------------------------------------------------------------------
    # /calls — HTML call log viewer, auto-refreshes every 30s
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/calls' -ScriptBlock {
        $tableHtml  = Get-CallLogHtml
        $totalCalls = 0
        if (Test-Path $using:CallCsvPath) {
            $totalCalls = (Get-Content $using:CallCsvPath).Count - 1
        }

        Write-PodeHtmlResponse -Value @"
<!DOCTYPE html><html><head>
<meta charset="utf-8">
<title>PestRoutes Call Log</title>
<meta http-equiv="refresh" content="30">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f4f8;padding:24px}
  h1{color:#2d7d46;font-size:22px;margin-bottom:4px}
  .sub{color:#999;font-size:12px;margin-bottom:20px}
  .sub a{color:#2d7d46}
  table{width:100%;border-collapse:collapse;background:white;border-radius:8px;
        overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08)}
  th{background:#2d7d46;color:white;padding:11px 14px;text-align:left;
     font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.6px}
  td{padding:9px 14px;font-size:13px;border-bottom:1px solid #f2f4f6;color:#444}
  tr:hover td{background:#f8fdf9}
  tr:last-child td{border-bottom:none}
  td:first-child{color:#999;font-size:12px;white-space:nowrap}
  .yes{color:#2d7d46;font-weight:700}
  .no{color:#c0392b;font-weight:700}
  .warn{color:#e67e22;font-weight:700}
</style>
</head><body>
<h1>&#x1F41B; PestRoutes Call Log</h1>
<div class="sub">
  $totalCalls call$(if($totalCalls -ne 1){'s'}) logged &nbsp;&middot;&nbsp;
  Newest first &nbsp;&middot;&nbsp;
  Auto-refreshes every 30 seconds &nbsp;&middot;&nbsp;
  <a href="/health">Health</a> &nbsp;&middot;&nbsp;
  <a href="/calls.csv" download>Download CSV</a>
</div>
$tableHtml
</body></html>
"@
    }

    # ------------------------------------------------------------------
    # /calls.csv — raw CSV download
    # ------------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/calls.csv' -ScriptBlock {
        if (Test-Path $using:CallCsvPath) {
            Set-PodeResponseAttachment -Path $using:CallCsvPath
            Write-PodeFileResponse -Path $using:CallCsvPath -ContentType 'text/csv'
        } else {
            Set-PodeResponseStatus -Code 404
            Write-PodeTextResponse -Value 'No call log found yet'
        }
    }

    # ------------------------------------------------------------------
    # Startup log
    # ------------------------------------------------------------------
    Write-Log INFO "SSE endpoint    : http://YOUR_SERVER_IP:$($using:HTTP_PORT)/sse?agent=[EXTENSION]&secret=[SECRET]"
    Write-Log INFO "3CX ContactUrl  : http://YOUR_SERVER_IP:$($using:HTTP_PORT)/notify?customerID=[EntityId]&phone=[Number]&agent=[Agent]"
    Write-Log INFO "Health check    : http://YOUR_SERVER_IP:$($using:HTTP_PORT)/health"
    Write-Log INFO "Call log viewer : http://YOUR_SERVER_IP:$($using:HTTP_PORT)/calls"
}
