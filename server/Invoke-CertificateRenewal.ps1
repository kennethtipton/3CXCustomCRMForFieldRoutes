# ==============================================================================
# Invoke-CertificateRenewal.ps1  —  FieldRoutes CRM for 3CX
# ==============================================================================
# Obtains and renews Let's Encrypt certificates using Posh-ACME with Hurricane
# Electric DNS validation, then deploys via Posh-ACME.Deploy.
#
# DNS PLUGINS:
#   HurricaneElectric     Web-scraping login to dns.he.net using your account
#                         credentials. Simplest — no pre-config in HE portal.
#                         Slightly fragile if HE changes their page HTML.
#
#   HurricaneElectricDyn  Uses HE's DynDNS API with per-record keys. More
#                         secure (main password never used). More reliable.
#                         Requires pre-creating _acme-challenge TXT records
#                         with DynDNS enabled in the HE portal before first use.
#
# DEPLOYMENT TYPES (configured in the /certificate web UI):
#   PodePfx        Export PFX to certs/, update config.json. Pode loads it
#                  directly on next restart. No admin rights needed. (Default)
#
#   WinCertStore   Also install into LocalMachine\My cert store via
#                  Posh-ACME.Deploy's Install-PACertificate. Good if other
#                  Windows apps need to trust the same cert.
#
#   IIS            Deploy to IIS binding via Posh-ACME.Deploy's
#                  Set-IISCertificate. Use when this server also runs IIS.
#
# USAGE:
#   pwsh .\Invoke-CertificateRenewal.ps1              # renew if due
#   pwsh .\Invoke-CertificateRenewal.ps1 -Force       # force renew
#   pwsh .\Invoke-CertificateRenewal.ps1 -UseStaging  # test with LE staging
#   pwsh .\Invoke-CertificateRenewal.ps1 -InstallTask # set up auto-renewal task
#
# ONE-TIME MODULE INSTALL:
#   Install-Module Posh-ACME        -Scope AllUsers -Force
#   Install-Module Posh-ACME.Deploy -Scope AllUsers -Force
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$Force,        # Renew even if not yet due
    [switch]$UseStaging,   # Use Let's Encrypt staging CA (safe for testing)
    [switch]$InstallTask   # Register Windows scheduled task for auto-renewal
)

# ==============================================================================
# PATHS
# ==============================================================================
# The script itself lives in C:\Scripts\Applications\FieldRoutesCrmFor3CX\
# All sensitive data (config, certs, logs) is kept separate under ProgramData so it:
#   - Survives script updates and folder moves
#   - Is accessible to SYSTEM for scheduled task execution
#   - Is never accidentally committed to source control or served over HTTP
# ==============================================================================
$ScriptRoot  = $PSScriptRoot
$DataRoot    = 'C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX'
$ConfigPath  = Join-Path $DataRoot  'config.json'
$CertsDir    = Join-Path $DataRoot  'certs'
$LogDir      = Join-Path $DataRoot  'logs'
$CertLogPath = Join-Path $LogDir    'cert-renewal.log'

foreach ($d in @($DataRoot, $CertsDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==============================================================================
# CRYPTO — DPAPI-backed config encryption
# ==============================================================================
Import-Module (Join-Path $ScriptRoot 'ProtectedConfig.psm1') -Force

# ==============================================================================
# LOGGING
# ==============================================================================
function Write-CertLog {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$($Level.PadRight(5))] $Message"
    $col  = switch ($Level) {
        'ERROR' { 'Red' }  'WARN' { 'Yellow' }  'OK' { 'Green' }  default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $col
    $line | Out-File -FilePath $CertLogPath -Append -Encoding utf8
}

# ==============================================================================
# CONFIG
# Thin wrappers — encryption/decryption handled by ProtectedConfig.psm1.
# ==============================================================================
function Read-Config {
    return Read-SecureConfig -ConfigPath $ConfigPath
}

function Save-Config ($cfg) {
    Save-SecureConfig -Config $cfg -ConfigPath $ConfigPath
}

# ==============================================================================
# MODULE CHECK
# ==============================================================================
function Assert-Modules {
    $need = @()
    if (-not (Get-Module -ListAvailable -Name Posh-ACME))        { $need += 'Posh-ACME' }
    if (-not (Get-Module -ListAvailable -Name Posh-ACME.Deploy)) { $need += 'Posh-ACME.Deploy' }
    if ($need) {
        Write-CertLog ERROR "Missing modules: $($need -join ', ')"
        Write-CertLog INFO  "Run: Install-Module $($need -join ', ') -Scope AllUsers -Force"
        exit 1
    }
    Import-Module Posh-ACME        -ErrorAction Stop
    Import-Module Posh-ACME.Deploy -ErrorAction Stop
    Write-CertLog INFO 'Modules loaded: Posh-ACME, Posh-ACME.Deploy'
}

# ==============================================================================
# BUILD DNS PLUGIN ARGS
# ==============================================================================
function Get-DnsPluginArgs {
    param($cfg)
    switch ($cfg.AcmePlugin) {
        'HurricaneElectric' {
            if (-not $cfg.AcmeHEUser -or -not $cfg.AcmeHEPass) {
                Write-CertLog ERROR 'HE username/password not configured'
                exit 1
            }
            $sec = ConvertTo-SecureString $cfg.AcmeHEPass -AsPlainText -Force
            return @{ HECredential = [pscredential]::new($cfg.AcmeHEUser, $sec) }
        }
        'HurricaneElectricDyn' {
            $recs = @($cfg.AcmeHEDynRecords)
            if ($recs.Count -eq 0) {
                Write-CertLog ERROR 'No HEDyn records configured'
                exit 1
            }
            $creds = $recs | ForEach-Object {
                $sec = ConvertTo-SecureString $_.Password -AsPlainText -Force
                [pscredential]::new($_.Record, $sec)
            }
            return @{ HEDynCredential = $creds }
        }
        default {
            Write-CertLog ERROR "Unknown plugin: $($cfg.AcmePlugin)"
            exit 1
        }
    }
}

# ==============================================================================
# DEPLOY CERTIFICATE
# Called after a cert is obtained or renewed.
#
# Always asks Posh-ACME where it stored the certificate via Get-PACertificate
# rather than constructing paths ourselves. Get-PACertificate returns the live
# cert object for the current order, with properties:
#
#   $cert.PfxFile        — full path to the PFX Posh-ACME generated
#   $cert.PfxFullChain   — PFX including full chain
#   $cert.CertFile       — PEM certificate
#   $cert.KeyFile        — PEM private key
#   $cert.ChainFile      — PEM chain
#
# All paths resolve correctly regardless of POSHACME_HOME because Posh-ACME
# computes them from its own active order state.
# ==============================================================================
function Deploy-Certificate {
    param($cfg)

    # ---- Ask Posh-ACME where it stored the certificate ----
    Write-CertLog INFO 'Querying Posh-ACME for certificate location'
    $cert = Get-PACertificate -ErrorAction Stop

    if (-not $cert) {
        Write-CertLog ERROR 'Get-PACertificate returned nothing — order may not be complete'
        throw 'No certificate found in Posh-ACME store'
    }

    $paHome = Get-PAHome
    Write-CertLog INFO "Posh-ACME home : $paHome"
    Write-CertLog INFO "PFX source     : $($cert.PfxFile)"
    Write-CertLog INFO "Expires        : $($cert.NotAfter)"
    Write-CertLog INFO "Thumbprint     : $($cert.Thumbprint)"

    # Verify the source PFX actually exists before we do anything else
    if (-not (Test-Path $cert.PfxFile)) {
        Write-CertLog ERROR "PFX not found at path reported by Posh-ACME: $($cert.PfxFile)"
        throw "PFX missing: $($cert.PfxFile)"
    }

    # ---- Copy PFX from Posh-ACME's store to our certs/ folder ----
    # We keep our own copy so Pode can read it from a fixed, predictable path
    # that does not change between renewals or if POSHACME_HOME is relocated.
    $pfxName = $cfg.AcmeDomain -replace '^\*\.', 'wildcard.'
    $destPfx = Join-Path $CertsDir "$pfxName.pfx"
    Copy-Item -Path $cert.PfxFile -Destination $destPfx -Force
    Write-CertLog OK "PFX copied to  : $destPfx"

    # ---- Update config.json so Pode loads the new cert on next restart ----
    $cfg.CertPath    = $destPfx
    $cfg.UseHttps    = $true
    $cfg.AcmePfxSrc  = $cert.PfxFile     # record where Posh-ACME put it
    $cfg.AcmePaHome  = $paHome            # record POSHACME_HOME at time of issue
    Save-Config $cfg
    Write-CertLog OK 'config.json updated (CertPath, UseHttps, AcmePfxSrc, AcmePaHome)'

    # ---- Deployment-type-specific steps ----
    switch ($cfg.DeployType) {

        'PodePfx' {
            # PFX copy above is all Pode needs — signal it to restart
            Write-CertLog OK '[PodePfx] PFX ready. Signalling Pode to restart.'
            Set-RestartPending
        }

        'WinCertStore' {
            Write-CertLog INFO '[WinCertStore] Installing into LocalMachine\My'
            try {
                Install-PACertificate -PACertificate $cert `
                    -StoreLocation LocalMachine -StoreName My -NotExportable:$false
                Write-CertLog OK '[WinCertStore] Installed into LocalMachine\My store'
                Set-RestartPending
            } catch {
                Write-CertLog WARN "[WinCertStore] Store install failed (PFX still works): $_"
                Set-RestartPending
            }
        }

        'IIS' {
            Write-CertLog INFO "[IIS] Binding cert to '$($cfg.IISSiteName)' on port $($cfg.IISPort)"
            try {
                Install-PACertificate -PACertificate $cert `
                    -StoreLocation LocalMachine -StoreName My -NotExportable:$false
                Write-CertLog OK '[IIS] Installed into LocalMachine\My'

                Set-IISCertificate -PACertificate $cert `
                    -SiteName  $cfg.IISSiteName `
                    -Port      $cfg.IISPort     `
                    -IPAddress $cfg.IISIPAddress
                Write-CertLog OK "[IIS] Binding updated: $($cfg.IISSiteName):$($cfg.IISPort)"
                Set-RestartPending
            } catch {
                Write-CertLog ERROR "[IIS] Deployment failed: $_"
            }
        }

        default {
            Write-CertLog WARN "Unknown DeployType '$($cfg.DeployType)' — PFX copy only"
            Set-RestartPending
        }
    }
}

# ==============================================================================
# RESTART SIGNAL
# Writes a sentinel file that the running Pode server watches on a timer.
# When Pode sees this file it calls Restart-PodeServer and deletes the file.
# This avoids the renewal script needing to know anything about the Pode
# process — it just drops a flag and Pode handles the rest.
# ==============================================================================
function Set-RestartPending {
    $flag = Join-Path $DataRoot '.restart-pending'
    [System.IO.File]::WriteAllText($flag, (Get-Date -Format 'o'))
    Write-CertLog OK "Restart flag written: $flag"
    Write-CertLog INFO 'Pode will restart within 30 seconds to load the new certificate'
}

# ==============================================================================
# AUTO-RENEWAL SCHEDULED TASK
# Runs daily at 03:00 as SYSTEM. Renews automatically within 30 days of expiry.
# ==============================================================================
function Install-RenewalTask {
    $taskName = 'FieldRoutesCrmFor3CX-CertRenewal'
    $script   = Join-Path $ScriptRoot 'Invoke-CertificateRenewal.ps1'

    Write-CertLog INFO "Registering scheduled task: $taskName"

    $action    = New-ScheduledTaskAction `
                     -Execute 'pwsh.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -File `"$script`"" `
                     -WorkingDirectory $DataRoot
    $trigger   = New-ScheduledTaskTrigger -Daily -At '03:00'
    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                     -StartWhenAvailable $true
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $taskName `
            -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-CertLog OK "Task '$taskName' registered — runs daily at 03:00 as SYSTEM"
    } catch {
        Write-CertLog ERROR "Failed to register task (requires admin): $_"
        exit 1
    }
}

# ==============================================================================
# MAIN RENEWAL
# ==============================================================================
function Invoke-Renewal {
    param($cfg, [bool]$ForceRenew, [bool]$Staging)

    if (-not $cfg.AcmeDomain)  { Write-CertLog ERROR 'AcmeDomain not configured';  exit 1 }
    if (-not $cfg.AcmeContact) { Write-CertLog ERROR 'AcmeContact not configured'; exit 1 }

    # Log where Posh-ACME will store its working files
    $paHome = Get-PAHome -ErrorAction SilentlyContinue
    Write-CertLog INFO ('=' * 60)
    Write-CertLog INFO "Domain        : $($cfg.AcmeDomain)"
    Write-CertLog INFO "DNS Plugin    : $($cfg.AcmePlugin)"
    Write-CertLog INFO "Deploy        : $($cfg.DeployType)"
    Write-CertLog INFO "Staging       : $Staging"
    Write-CertLog INFO "Force         : $ForceRenew"
    Write-CertLog INFO "POSHACME_HOME : $($env:POSHACME_HOME)"
    Write-CertLog INFO "PA home (live): $paHome"
    Write-CertLog INFO ('=' * 60)

    Set-PAServer ($Staging ? 'LE_STAGE' : 'LE_PROD')

    # Ensure ACME account exists
    $acct = Get-PAAccount -List | Where-Object { $_.status -eq 'valid' } | Select-Object -First 1
    if (-not $acct) {
        Write-CertLog INFO "Creating ACME account: $($cfg.AcmeContact)"
        New-PAAccount -AcceptTOS -Contact "mailto:$($cfg.AcmeContact)" | Out-Null
    } else {
        Set-PAAccount -ID $acct.id | Out-Null
        Write-CertLog INFO "ACME account: $($acct.id)"
    }

    $pluginArgs = Get-DnsPluginArgs $cfg

    try {
        $existingOrder = Get-PAOrder -List |
                         Where-Object { $_.MainDomain -eq $cfg.AcmeDomain } |
                         Select-Object -First 1

        if ($existingOrder) {
            Set-PAOrder -MainDomain $cfg.AcmeDomain | Out-Null
            Write-CertLog INFO 'Existing order found — checking renewal eligibility'

            $renewed = Submit-Renewal $(if ($ForceRenew) { @{Force=$true} }) -ErrorAction SilentlyContinue

            if (-not $renewed) {
                Write-CertLog OK 'Not due for renewal yet (cert valid > 30 days)'
                Write-CertLog INFO 'Use -Force to renew anyway'
                # Still call Deploy-Certificate so certs/ stays in sync if
                # someone moved or deleted our local copy
                Deploy-Certificate -cfg $cfg
                return $true
            }
        } else {
            Write-CertLog INFO 'No existing order — requesting new certificate'
            New-PACertificate -Domain $cfg.AcmeDomain `
                -Plugin $cfg.AcmePlugin -PluginArgs $pluginArgs `
                -PfxPass $cfg.CertPassword -ErrorAction Stop | Out-Null
        }

        # In both the new and renewed case, ask Posh-ACME for the cert
        # rather than using whatever the cmdlets returned directly
        Deploy-Certificate -cfg $cfg
        Write-CertLog OK '=== Renewal complete ==='
        return $true

    } catch {
        Write-CertLog ERROR "Renewal failed: $_"
        Write-CertLog ERROR $_.ScriptStackTrace
        return $false
    }
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
Assert-Modules

if ($InstallTask) { Install-RenewalTask; exit 0 }

$cfg = Read-Config
$staging = $UseStaging -or $cfg.AcmeUseStaging
exit (((Invoke-Renewal -cfg $cfg -ForceRenew:$Force -Staging:$staging)) ? 0 : 1)
