#Requires -Version 5.1
<#
.SYNOPSIS
    Middleware HTTP listener that receives call data from the 3CX CRM template
    and automatically upserts customer records into the 3CX phonebook.

.DESCRIPTION
    This script runs as a persistent HTTP listener on the 3CX server.
    When a call ends, the FieldRoutesCRMfor3CX.xml template POSTs the
    customer's data here. This script then:

      1. Receives the FieldRoutes customer data from the 3CX CRM engine
      2. Authenticates with the 3CX REST API using a local service account
      3. Searches the 3CX phonebook for an existing record matching the number
      4. UPDATES the record if found (keeping data in sync with FieldRoutes)
      5. CREATES a new CRM phonebook entry if not found
      6. Optionally posts a call note back to FieldRoutes (call journaling)
      7. Logs all activity to a rolling log file for auditing

    The phonebook builds itself automatically over time — every new caller
    found in FieldRoutes gets added, and returning callers get their records
    refreshed with the latest FieldRoutes data.

    ┌─────────────────────────────────────────────────────────────────┐
    │                    SETUP INSTRUCTIONS                           │
    ├─────────────────────────────────────────────────────────────────┤
    │ 1. COPY this script to your 3CX server, e.g.:                  │
    │      C:\3CX\CRM\Update-3CXPhonebook.ps1                        │
    │                                                                 │
    │ 2. CREATE a dedicated 3CX user account for the middleware:      │
    │      - In 3CX Admin Console > Users, create a user             │
    │        e.g. "crm-sync@yourdomain.com"                          │
    │      - Assign the "Admin" or "CRM" role                        │
    │      - Note the username and password                          │
    │                                                                 │
    │ 3. CONFIGURE the parameters in the CONFIG SECTION below        │
    │                                                                 │
    │ 4. OPEN the firewall port (default 8880) for localhost only:   │
    │      netsh advfirewall firewall add rule name="3CX CRM Sync"  │
    │        dir=in action=allow protocol=tcp localport=8880          │
    │        remoteip=127.0.0.1                                       │
    │                                                                 │
    │ 5. REGISTER the URL prefix (run once as Administrator):        │
    │      netsh http add urlacl url=http://+:8880/phonebook/        │
    │        user="NT AUTHORITY\NETWORK SERVICE"                      │
    │                                                                 │
    │ 6. INSTALL as a Windows Service using NSSM (recommended):      │
    │      Download NSSM from https://nssm.cc                        │
    │      nssm install FieldRoutesCRMSync powershell.exe            │
    │        -NonInteractive -File "C:\3CX\CRM\Update-3CXPhonebook.ps1"│
    │      nssm set FieldRoutesCRMSync AppStdout                     │
    │        "C:\3CX\CRM\Logs\service.log"                           │
    │      nssm start FieldRoutesCRMSync                             │
    │                                                                 │
    │    OR run manually for testing:                                 │
    │      powershell.exe -File Update-3CXPhonebook.ps1              │
    │                                                                 │
    │ 7. TEST by running the Test-FieldRoutesCRM.ps1 script          │
    │    with -TestReportCall to trigger a sample phonebook upsert   │
    └─────────────────────────────────────────────────────────────────┘

.NOTES
    Author  : FieldRoutesCRMfor3CX Project
    Version : 2.0
    Requires: PowerShell 5.1+, network access to 3CX REST API
#>

# ═════════════════════════════════════════════════════════════════════════════
# CONFIG SECTION — Edit these values before deploying
# ═════════════════════════════════════════════════════════════════════════════

$Config = @{

    # ── Listener settings ─────────────────────────────────────────────────
    # Port this script listens on. Must match ThreeCXPort in the XML template.
    # Only bind to localhost — 3CX engine posts from the same machine.
    ListenerUrl    = "http://localhost:8880/phonebook/"

    # ── 3CX REST API settings ─────────────────────────────────────────────
    # Your 3CX server's FQDN or IP. Use "localhost" if running on the 3CX box.
    ThreeCXHost    = "localhost"

    # 3CX management API port. Default is 5001 (HTTPS) or 5000 (HTTP).
    ThreeCXPort    = 5001

    # Use HTTPS for the 3CX API (strongly recommended in production).
    ThreeCXHttps   = $true

    # 3CX service account credentials. This account must have permission
    # to read/write the Contact Directory via the 3CX REST API.
    ThreeCXUser    = "crm-sync@yourdomain.com"
    ThreeCXPass    = "YourServiceAccountPassword"

    # ── Phonebook settings ────────────────────────────────────────────────
    # Tag added to each phonebook entry's Notes field to identify records
    # managed by this sync. Used to find and clean up old entries when a
    # customer's phone number changes in FieldRoutes.
    SyncTag        = "[FR-CRM-SYNC]"

    # ── FieldRoutes call note settings ────────────────────────────────────
    # If true, also POST a call note back to FieldRoutes after each call.
    CreateFRNote   = $true

    # ── Logging ───────────────────────────────────────────────────────────
    LogFile        = "C:\3CX\CRM\Logs\phonebook-sync.log"
    # Maximum log file size in MB before rolling to a new file.
    LogMaxSizeMB   = 10
}

# ═════════════════════════════════════════════════════════════════════════════
# LOGGING
# ═════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[$timestamp] [$Level] $Message"

    # Console output with colour
    $colour = switch ($Level) {
        "SUCCESS" { "Green"     }
        "WARN"    { "DarkYellow"}
        "ERROR"   { "Red"       }
        "DEBUG"   { "DarkGray"  }
        default   { "Gray"      }
    }
    Write-Host $line -ForegroundColor $colour

    # File output with rolling
    try {
        $logDir = Split-Path $Config.LogFile -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

        # Roll log if too large
        if ((Test-Path $Config.LogFile) -and
            ((Get-Item $Config.LogFile).Length / 1MB) -gt $Config.LogMaxSizeMB) {
            $rolled = $Config.LogFile -replace '\.log$', "-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
            Rename-Item $Config.LogFile $rolled
        }

        Add-Content -Path $Config.LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Host "[LOGGING ERROR] Could not write to log file: $_" -ForegroundColor Red
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 3CX REST API — AUTHENTICATION
# Gets a bearer token from the 3CX API. Token is cached and refreshed
# automatically when it expires (3CX tokens last ~1 hour).
# ═════════════════════════════════════════════════════════════════════════════

$Script:ThreeCXToken       = $null
$Script:ThreeCXTokenExpiry = [DateTime]::MinValue

function Get-3CXToken {
    # Return cached token if still valid (with 5-minute buffer)
    if ($Script:ThreeCXToken -and [DateTime]::UtcNow -lt $Script:ThreeCXTokenExpiry.AddMinutes(-5)) {
        return $Script:ThreeCXToken
    }

    $scheme = if ($Config.ThreeCXHttps) { "https" } else { "http" }
    $url    = "$scheme://$($Config.ThreeCXHost):$($Config.ThreeCXPort)/webclient/api/Login/GetAccessToken"

    $body = @{
        SecurityCode = ""
        Username     = $Config.ThreeCXUser
        Password     = $Config.ThreeCXPass
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $url -Method POST -Body $body `
                        -ContentType "application/json" `
                        -SkipCertificateCheck `
                        -ErrorAction Stop

        $Script:ThreeCXToken       = $response.Token
        $Script:ThreeCXTokenExpiry = [DateTime]::UtcNow.AddSeconds($response.ExpireIn)

        Write-Log "3CX API token obtained. Expires: $($Script:ThreeCXTokenExpiry.ToString('HH:mm:ss'))" "SUCCESS"
        return $Script:ThreeCXToken

    } catch {
        Write-Log "Failed to get 3CX API token: $_" "ERROR"
        return $null
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 3CX REST API — PHONEBOOK UPSERT
# Searches for an existing contact by phone number. Updates if found,
# creates new if not found.
# ═════════════════════════════════════════════════════════════════════════════

function Invoke-3CXApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body   = $null
    )

    $token  = Get-3CXToken
    if (-not $token) { return $null }

    $scheme = if ($Config.ThreeCXHttps) { "https" } else { "http" }
    $url    = "$scheme://$($Config.ThreeCXHost):$($Config.ThreeCXPort)/xapi/v1/$Endpoint"

    $headers = @{ Authorization = "Bearer $token" }

    try {
        $params = @{
            Uri                  = $url
            Method               = $Method
            Headers              = $headers
            ContentType          = "application/json"
            SkipCertificateCheck = $true
            ErrorAction          = "Stop"
        }

        if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }

        return Invoke-RestMethod @params

    } catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        Write-Log "3CX API call failed. Endpoint: $Endpoint | HTTP $code | $_" "ERROR"
        return $null
    } catch {
        Write-Log "3CX API call error. Endpoint: $Endpoint | $_" "ERROR"
        return $null
    }
}

function Remove-ExistingRecords {
    <#
    .SYNOPSIS
        Deletes all existing phonebook records matching a phone number or
        CustomerID tag, across both CRM and Company address books.
        Called before writing fresh records to guarantee a clean slate.
    #>
    param([string]$Phone1, [string]$CustomerID)

    $deleteCount = 0

    # Delete by phone number (catches both CRM and Company records)
    if ($Phone1) {
        $filter   = [Uri]::EscapeDataString("PhoneBusiness eq '$Phone1'")
        $existing = Invoke-3CXApi -Endpoint "ContactDirectory?`$filter=$filter"
        if ($existing -and $existing.value) {
            foreach ($record in $existing.value) {
                Invoke-3CXApi -Endpoint "ContactDirectory($($record.Id))" -Method "DELETE" | Out-Null
                $deleteCount++
                Write-Log "  Deleted record ID $($record.Id) (phone match: $Phone1)" "DEBUG"
            }
        }
    }

    # Delete by CustomerID stored in Notes field
    # Catches records where the customer's phone number changed in FieldRoutes
    if ($CustomerID) {
        $filter         = [Uri]::EscapeDataString("contains(Notes,'CustomerID:$CustomerID')")
        $existingByNote = Invoke-3CXApi -Endpoint "ContactDirectory?`$filter=$filter"
        if ($existingByNote -and $existingByNote.value) {
            foreach ($record in $existingByNote.value) {
                Invoke-3CXApi -Endpoint "ContactDirectory($($record.Id))" -Method "DELETE" | Out-Null
                $deleteCount++
                Write-Log "  Deleted record ID $($record.Id) (CustomerID tag match)" "DEBUG"
            }
        }
    }

    return $deleteCount
}

function Write-PhonebookContact {
    param(
        [string]$CustomerID,
        [string]$FirstName,
        [string]$LastName,
        [string]$CompanyName,
        [string]$Email,
        [string]$Phone1,
        [string]$Phone2,
        [string]$ContactUrl
    )

    # Build display name
    $displayName = "$FirstName $LastName".Trim()
    if (-not $displayName -and $CompanyName) { $displayName = $CompanyName }
    if (-not $displayName) { $displayName = "Unknown ($Phone1)" }

    # Notes field identifies the record as FR-managed and stores the CustomerID
    # so we can find and clean it up even if the phone number changes later
    $notes = "$($Config.SyncTag) CustomerID:$CustomerID | $ContactUrl"

    Write-Log "Writing CRM phonebook record for '$displayName' | Phone: $Phone1 | CustomerID: $CustomerID" "INFO"

    # ── STEP 1: Delete all existing CRM records for this customer ──────────
    # Always overwrite — guarantees no duplicates and no stale data.
    $deleteCount = Remove-ExistingRecords -Phone1 $Phone1 -CustomerID $CustomerID
    if ($deleteCount -gt 0) {
        Write-Log "  Cleared $deleteCount stale record(s) before fresh write." "INFO"
    }

    # ── STEP 2: Write a single CRM record ─────────────────────────────────
    # Type="CRM" writes a persistent CRM phonebook entry. This means:
    #   - On every future inbound call from this number, 3CX finds the record
    #     in the CRM phonebook and uses it — no live FieldRoutes API call needed
    #     for caller ID display (though the live lookup still fires for the URL)
    #   - ContactUrl is stored with the record and fires automatically when
    #     the operator answers, opening the FieldRoutes customer page
    #   - The record is visible in the CRM tab of all 3CX clients
    #   - Desk phones resolve the caller name from the CRM phonebook entry
    $contact = [ordered]@{
        FirstName     = $FirstName
        LastName      = $LastName
        CompanyName   = $CompanyName
        Email         = $Email
        PhoneBusiness = $Phone1
        PhoneHome     = $Phone2
        PhoneMobile   = ""
        ContactUrl    = $ContactUrl
        Notes         = $notes
        Type          = "CRM"
    }

    $result = Invoke-3CXApi -Endpoint "ContactDirectory" -Method "POST" -Body $contact

    if ($result -and $result.Id) {
        $action = if ($deleteCount -gt 0) { "Overwritten" } else { "Created" }
        Write-Log "CRM phonebook record $action : '$displayName' (ID: $($result.Id))" "SUCCESS"
        return @{ Action=$action; Id=$result.Id; Name=$displayName }
    } else {
        Write-Log "CRM phonebook record FAILED for '$displayName'" "ERROR"
        return @{ Action="Error"; Id=$null; Name=$displayName }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# FIELDROUTES — POST CALL NOTE
# Writes a call log note to the customer's FieldRoutes record.
# ═════════════════════════════════════════════════════════════════════════════

function New-FieldRoutesNote {
    param(
        [string]$FRCompanyName,
        [string]$OfficeID,
        [string]$AuthKey,
        [string]$AuthToken,
        [string]$CustomerID,
        [string]$CallType,
        [string]$Number,
        [string]$AgentFirstName,
        [string]$AgentLastName,
        [string]$Duration,
        [string]$DateTime
    )

    if (-not $Config.CreateFRNote) {
        Write-Log "FieldRoutes note creation disabled in config." "DEBUG"
        return
    }

    if (-not $CustomerID) {
        Write-Log "No CustomerID — skipping FieldRoutes note." "DEBUG"
        return
    }

    $noteText = "3CX Call Log | Type: $CallType | Number: $Number | " +
                "Agent: $AgentFirstName $AgentLastName | " +
                "Duration: $Duration | Date: $DateTime"

    $url  = "https://$FRCompanyName.fieldroutes.com/api/note/create"
    $body = @{
        officeID            = $OfficeID
        authenticationKey   = $AuthKey
        authenticationToken = $AuthToken
        customerID          = $CustomerID
        notes               = $noteText
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method POST -Body $body `
                        -ContentType "application/x-www-form-urlencoded" `
                        -ErrorAction Stop

        if ($response.success) {
            Write-Log "FieldRoutes note created for CustomerID $CustomerID" "SUCCESS"
        } else {
            Write-Log "FieldRoutes note API returned success:false for CustomerID $CustomerID" "WARN"
        }
    } catch {
        Write-Log "FieldRoutes note creation failed for CustomerID $CustomerID : $_" "WARN"
        # Non-fatal — phonebook upsert is the primary goal
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# REQUEST HANDLER
# Parses the incoming POST body from the 3CX CRM engine and dispatches work.
# ═════════════════════════════════════════════════════════════════════════════

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)

    $request  = $Context.Request
    $response = $Context.Response

    try {
        # ── Read POST body ──────────────────────────────────────────────────
        $reader  = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
        $rawBody = $reader.ReadToEnd()
        $reader.Close()

        Write-Log "Received request from $($request.RemoteEndPoint) | $($request.RawUrl)" "DEBUG"

        # ── Parse URL-encoded form data ─────────────────────────────────────
        $fields = @{}
        foreach ($pair in $rawBody -split '&') {
            $parts = $pair -split '=', 2
            if ($parts.Count -eq 2) {
                $fields[[Uri]::UnescapeDataString($parts[0])] = [Uri]::UnescapeDataString($parts[1].Replace('+',' '))
            }
        }

        # ── Extract all fields sent by the XML template ─────────────────────
        $customerID     = $fields['customerID']
        $firstName      = $fields['firstName']
        $lastName       = $fields['lastName']
        $companyName    = $fields['companyName']
        $email          = $fields['email']
        $phone1         = $fields['phone1']
        $phone2         = $fields['phone2']
        $contactUrl     = $fields['contactUrl']
        $callType       = $fields['callType']
        $callNumber     = $fields['callNumber']
        $agentFirstName = $fields['agentFirstName']
        $agentLastName  = $fields['agentLastName']
        $agentEmail     = $fields['agentEmail']
        $duration       = $fields['duration']
        $dateTime       = $fields['dateTime']
        $officeID       = $fields['officeID']
        $authKey        = $fields['authKey']
        $authToken      = $fields['authToken']
        $frCompany      = $fields['frCompanyName']

        Write-Log "Processing: CustomerID=$customerID | Name=$firstName $lastName | Phone=$phone1 | CallType=$callType" "INFO"

        $upsertResult = $null

        # ── Phonebook overwrite (skip if no phone number to write) ───────────
        if ($phone1) {
            $upsertResult = Write-PhonebookContact `
                -CustomerID  $customerID `
                -FirstName   $firstName `
                -LastName    $lastName `
                -CompanyName $companyName `
                -Email       $email `
                -Phone1      $phone1 `
                -Phone2      $phone2 `
                -ContactUrl  $contactUrl
        } else {
            Write-Log "No Phone1 in request — skipping phonebook write." "WARN"
        }

        # ── FieldRoutes call note ───────────────────────────────────────────
        if ($customerID) {
            New-FieldRoutesNote `
                -FRCompanyName  $frCompany `
                -OfficeID       $officeID `
                -AuthKey        $authKey `
                -AuthToken      $authToken `
                -CustomerID     $customerID `
                -CallType       $callType `
                -Number         $callNumber `
                -AgentFirstName $agentFirstName `
                -AgentLastName  $agentLastName `
                -Duration       $duration `
                -DateTime       $dateTime
        }

        # ── Send success response back to 3CX CRM engine ───────────────────
        $responseBody = (@{
            success = $true
            action  = if ($upsertResult) { $upsertResult.Action } else { "Skipped" }
            name    = if ($upsertResult) { $upsertResult.Name }   else { "" }
            id      = if ($upsertResult) { $upsertResult.Id }     else { $null }
        } | ConvertTo-Json)

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
        $response.StatusCode        = 200
        $response.ContentType       = "application/json"
        $response.ContentLength64   = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)

    } catch {
        Write-Log "Unhandled error in request handler: $_" "ERROR"

        $errorBody = (@{ success = $false; error = $_.Exception.Message } | ConvertTo-Json)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorBody)
        $response.StatusCode      = 500
        $response.ContentType     = "application/json"
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)

    } finally {
        $response.OutputStream.Close()
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# STARTUP & MAIN LISTENER LOOP
# ═════════════════════════════════════════════════════════════════════════════

Write-Log "════════════════════════════════════════════════════════" "INFO"
Write-Log "FieldRoutesCRMfor3CX — Phonebook Sync Middleware v2.0"  "INFO"
Write-Log "════════════════════════════════════════════════════════" "INFO"
Write-Log "Listener URL  : $($Config.ListenerUrl)"                  "INFO"
Write-Log "3CX Host      : $($Config.ThreeCXHost):$($Config.ThreeCXPort)" "INFO"
Write-Log "3CX User      : $($Config.ThreeCXUser)"                  "INFO"
Write-Log "Address Book  : CRM phonebook (single record per customer)"  "INFO"
Write-Log "Create FR Note: $($Config.CreateFRNote)"                 "INFO"
Write-Log "Log File      : $($Config.LogFile)"                      "INFO"
Write-Log "────────────────────────────────────────────────────────" "INFO"

# Validate 3CX connectivity on startup
Write-Log "Testing 3CX API connection..." "INFO"
$token = Get-3CXToken
if ($token) {
    Write-Log "3CX API connection successful." "SUCCESS"
} else {
    Write-Log "WARNING: Could not connect to 3CX API on startup." "WARN"
    Write-Log "Check ThreeCXHost, ThreeCXPort, ThreeCXUser, ThreeCXPass in config." "WARN"
    Write-Log "Listener will still start — retrying on first request." "WARN"
}

# Start the HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Config.ListenerUrl)

try {
    $listener.Start()
    Write-Log "HTTP listener started. Waiting for requests from 3CX CRM engine..." "SUCCESS"
    Write-Log "(Press Ctrl+C to stop)" "INFO"

    while ($listener.IsListening) {
        try {
            # GetContext blocks until a request arrives
            $context = $listener.GetContext()

            # Handle each request in a background job to keep the listener responsive
            $contextRef = $context
            $configRef  = $Config
            Start-Job -ScriptBlock {
                # Re-source the handler function in the job scope
                # (Jobs run in a new PowerShell session)
                param($ctx, $cfg)
                # For simplicity in the job, write directly to the log
                # In production, consider using a shared queue instead of jobs
            } -ArgumentList $contextRef, $configRef | Out-Null

            # Handle synchronously for reliability (simpler, adequate for call volumes)
            Handle-Request -Context $context

        } catch [System.Net.HttpListenerException] {
            if ($listener.IsListening) {
                Write-Log "Listener error: $_" "ERROR"
            }
        } catch {
            Write-Log "Unexpected error in main loop: $_" "ERROR"
        }
    }

} catch {
    Write-Log "Failed to start listener on $($Config.ListenerUrl) : $_" "ERROR"
    Write-Log "Run this as Administrator, or register the URL with:" "WARN"
    Write-Log "  netsh http add urlacl url=$($Config.ListenerUrl) user=`"NT AUTHORITY\NETWORK SERVICE`"" "WARN"
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Log "Middleware stopped." "INFO"
}
