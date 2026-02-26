# ==============================================================================
# Setup-Middleware.ps1  -  FieldRoutes CRM for 3CX
# ==============================================================================
# Interactive console wizard. Collects every setting, validates input, writes
# an encrypted config.json, then hands off to Install-Middleware.ps1.
#
# Run this INSTEAD of Install-Middleware.ps1 for a guided first install.
# Safe to re-run on an existing install - press Enter to keep current values.
#
# USAGE (run as Administrator):
#   pwsh -ExecutionPolicy Bypass -File .\Setup-Middleware.ps1
#   pwsh -ExecutionPolicy Bypass -File .\Setup-Middleware.ps1 -SkipInstall
#
# SECTIONS:
#   1 - Network         port, bind address, public FQDN / IP
#   2 - Security        shared secret (SSE auth token)
#   3 - HTTPS / TLS     enable HTTPS, certificate source
#   4 - Let's Encrypt   contact, domain, HE DNS plugin, deployment type
#   5 - Logging         log retention days
#   6 - Review          confirm all settings before anything is written
# ==============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipInstall    # Write config only, skip Install-Middleware.ps1
)

$ErrorActionPreference = 'Stop'

# ==============================================================================
# PATHS
# ==============================================================================
$ScriptRoot = $PSScriptRoot
$ServerDir  = Join-Path (Split-Path $ScriptRoot -Parent) 'server'
$DataRoot   = 'C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX'
$ConfigPath = Join-Path $DataRoot 'config.json'
$CertsDir   = Join-Path $DataRoot 'certs'

foreach ($d in @($DataRoot, $CertsDir, (Join-Path $DataRoot 'logs'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==============================================================================
# LOAD PROTECTEDCONFIG MODULE
# ==============================================================================
$pcModule = Join-Path $ServerDir 'ProtectedConfig.psm1'
if (-not (Test-Path $pcModule)) {
    Write-Host ''
    Write-Host '  ERROR: ProtectedConfig.psm1 not found.' -ForegroundColor Red
    Write-Host "  Expected at: $pcModule"                 -ForegroundColor Red
    Write-Host '  Ensure Setup-Middleware.ps1 is in Installs\ and server\ is alongside it.' -ForegroundColor Red
    exit 1
}
Import-Module $pcModule -Force

# ==============================================================================
# CONSOLE HELPERS
# ==============================================================================
function Write-Banner {
    Write-Host ''
    Write-Host ('  ' + ([char]9552) * 58)                    -ForegroundColor DarkCyan
    Write-Host '   FieldRoutes CRM for 3CX  -  Setup Wizard' -ForegroundColor Cyan
    Write-Host ('  ' + ([char]9552) * 58)                    -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Section {
    param([string]$Title, [int]$Num, [int]$Of)
    Write-Host ''
    Write-Host ('  ' + ([char]9472) * 58) -ForegroundColor DarkGray
    Write-Host "  Step $Num of $Of  -  $Title" -ForegroundColor White
    Write-Host ('  ' + ([char]9472) * 58) -ForegroundColor DarkGray
}

function Write-Hint { param([string]$m) Write-Host "    $m" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$m) Write-Host "  v $m" -ForegroundColor Green   }
function Write-Warn { param([string]$m) Write-Host "  ! $m" -ForegroundColor Yellow  }
function Write-Err  { param([string]$m) Write-Host "  X $m" -ForegroundColor Red     }

# Read-Input
# Plain text : shows [default] in prompt, returns default on empty Enter.
# Secret     : shows "(Enter = keep existing)" when a default exists, reads masked.
#              Empty Enter keeps the existing value - no sentinel string needed.
function Read-Input {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Secret
    )
    if ($Secret) {
        $hint = if ($Default) { ' [Enter = keep existing]' } else { '' }
        Write-Host "  > $Prompt$hint : " -ForegroundColor White -NoNewline
        $ss    = Read-Host -AsSecureString
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        if ([string]::IsNullOrEmpty($plain)) { return $Default }
        return $plain
    } else {
        $dispDefault = if ("$Default" -ne '') { " [$Default]" } else { '' }
        Write-Host "  > $Prompt$dispDefault : " -ForegroundColor White -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        return $val.Trim()
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $yn = if ($Default) { 'Y/n' } else { 'y/N' }
    Write-Host "  > $Prompt [$yn] : " -ForegroundColor White -NoNewline
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val -match '^[Yy]'
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [int]$Default = 0)
    Write-Host "  $Prompt" -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $sel = ($i -eq $Default)
        $dot = if ($sel) { 'o' } else { ' ' }
        $col = if ($sel) { 'Green' } else { 'DarkGray' }
        Write-Host "    [$dot] $($i+1). $($Options[$i])" -ForegroundColor $col
    }
    Write-Host "  > Choice [default: $($Default+1)] : " -ForegroundColor White -NoNewline
    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $n = ([int]$raw) - 1
    if ($n -ge 0 -and $n -lt $Options.Count) { return $n }
    Write-Warn "Invalid - using default"
    return $Default
}

function Read-Port {
    param([string]$Prompt, [int]$Default = 3000)
    while ($true) {
        $raw = Read-Input -Prompt $Prompt -Default "$Default"
        if ($raw -match '^\d+$') {
            $p = [int]$raw
            if ($p -ge 1 -and $p -le 65535) { return $p }
        }
        Write-Err 'Port must be between 1 and 65535'
    }
}

function New-RandomSecret {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Show-ReviewLine - $Display overrides $Value for sensitive or formatted values.
function Show-ReviewLine {
    param([string]$Label, $Value, [string]$Display = '')
    $text = if ($Display) { $Display } elseif ($null -ne $Value) { "$Value" } else { '(not set)' }
    $col  = if ("$Value" -ne '' -and $null -ne $Value) { 'White' } else { 'DarkGray' }
    Write-Host ("    {0,-30} {1}" -f "${Label}:", $text) -ForegroundColor $col
}

# ==============================================================================
# LOAD EXISTING CONFIG
# Uses ContainsKey so $false and 0 are correctly preserved (not treated as unset).
# ==============================================================================
$existing = @{}
$isUpdate = Test-Path $ConfigPath

if ($isUpdate) {
    Write-Warn 'Existing config.json found - press Enter at any prompt to keep current values.'
    try   { $existing = Read-SecureConfig -ConfigPath $ConfigPath }
    catch { Write-Warn "Could not read existing config (using defaults): $_" }
}

function Get-Cfg {
    param([string]$Key, $Default)
    if ($existing.ContainsKey($Key)) { return $existing[$Key] }
    return $Default
}

# ==============================================================================
# WIZARD
# ==============================================================================
Write-Banner

if ($isUpdate) {
    Write-Host '  Re-running setup on an existing installation.' -ForegroundColor Yellow
    Write-Host ''
}

# ------------------------------------------------------------------------------
# SECTION 1 - NETWORK
# ------------------------------------------------------------------------------
Write-Section -Title 'Network' -Num 1 -Of 6

Write-Host ''
Write-Hint 'Port: TCP port the middleware listens on. Default 3000.'
Write-Hint '3CX sends call notifications to this port.'
$Port = Read-Port -Prompt 'Port' -Default (Get-Cfg 'Port' 3000)

Write-Host ''
Write-Hint 'Bind address: * = listen on all network interfaces.'
Write-Hint 'Enter a specific IP only if you need to restrict to one NIC.'
$BindAddress = Read-Input -Prompt 'Bind address' -Default (Get-Cfg 'BindAddress' '*')

Write-Host ''
Write-Hint 'Public FQDN or IP: how 3CX and Chrome extensions reach this server.'
Write-Hint 'Examples:  middleware.yourcompany.com   or   192.168.1.50'
Write-Hint 'Used to display the correct URLs at the end of setup.'
do {
    $Fqdn = Read-Input -Prompt 'FQDN or IP' -Default (Get-Cfg 'Fqdn' '')
    if (-not $Fqdn) { Write-Err 'FQDN / IP is required' }
} while (-not $Fqdn)

# ------------------------------------------------------------------------------
# SECTION 2 - SECURITY
# ------------------------------------------------------------------------------
Write-Section -Title 'Security' -Num 2 -Of 6

Write-Host ''
Write-Hint 'Shared secret: auth token that Chrome extensions send when connecting.'
Write-Hint 'All operators must update their extension if you change this.'

$existingSecret  = Get-Cfg 'Secret' ''
$isDefaultSecret = ([string]::IsNullOrEmpty($existingSecret) -or
                    $existingSecret -eq 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING')
$autoSecret      = New-RandomSecret

if (-not $isDefaultSecret) {
    Write-Hint 'A secret is already configured. Press Enter to keep it, or type a new one.'
    $Secret = Read-Input -Prompt 'Secret' -Default $existingSecret -Secret
} else {
    Write-Hint 'Auto-generated secret (press Enter to accept):'
    Write-Host "    $autoSecret" -ForegroundColor Green
    $Secret = Read-Input -Prompt 'Secret' -Default $autoSecret -Secret
}
if ([string]::IsNullOrWhiteSpace($Secret)) { $Secret = $autoSecret }

# ------------------------------------------------------------------------------
# SECTION 3 - HTTPS / TLS
# ------------------------------------------------------------------------------
Write-Section -Title 'HTTPS / TLS' -Num 3 -Of 6

Write-Host ''
Write-Hint 'HTTP is fine for internal-only networks (3CX and extensions on LAN).'
Write-Hint 'HTTPS is required for internet-facing deployments or cloud-hosted 3CX.'

$UseHttps       = Read-YesNo -Prompt 'Enable HTTPS?' -Default (Get-Cfg 'UseHttps' $false)
$CertPassword   = Get-Cfg 'CertPassword' 'poshacme'
$CertPath       = Get-Cfg 'CertPath' ''
$UseLetsEncrypt = $false

if ($UseHttps) {
    Write-Host ''
    $certChoice = Read-Choice `
        -Prompt  'Certificate source:' `
        -Options @(
            "Let's Encrypt  - automatic, free, renews itself  (requires public FQDN)"
            "Manual PFX     - you supply a .pfx certificate file"
        ) `
        -Default $(if (Get-Cfg 'AcmeDomain' '') { 0 } else { 0 })

    if ($certChoice -eq 0) {
        $UseLetsEncrypt = $true
        Write-Ok "Let's Encrypt selected - configure in Section 4"
    } else {
        Write-Host ''
        Write-Hint 'Enter the full path to your .pfx certificate file.'
        if ($CertPath) { Write-Hint "Current: $CertPath" }
        do {
            $pfxInput = Read-Input -Prompt 'PFX path' -Default $CertPath
            if (-not $pfxInput) {
                Write-Err 'Certificate path is required when HTTPS is enabled'
            } elseif (-not (Test-Path $pfxInput)) {
                Write-Err "File not found: $pfxInput"
                $pfxInput = ''
            }
        } while (-not $pfxInput)

        Write-Host ''
        Write-Hint 'PFX password. Press Enter to keep the existing password.'
        $CertPassword = Read-Input -Prompt 'PFX password' -Default $CertPassword -Secret

        $destPfx  = Join-Path $CertsDir (Split-Path $pfxInput -Leaf)
        Copy-Item -Path $pfxInput -Destination $destPfx -Force
        $CertPath = $destPfx
        Write-Ok "Certificate copied to: $CertPath"
    }
}

# ------------------------------------------------------------------------------
# SECTION 4 - LET'S ENCRYPT
# Pre-load existing values even when skipped so they are preserved in config write
# ------------------------------------------------------------------------------
$AcmeContact      = Get-Cfg 'AcmeContact'      ''
$AcmeDomain       = Get-Cfg 'AcmeDomain'       ''
$AcmePlugin       = Get-Cfg 'AcmePlugin'       'HurricaneElectricDyn'
$AcmeHEUser       = Get-Cfg 'AcmeHEUser'       ''
$AcmeHEPass       = Get-Cfg 'AcmeHEPass'       ''
$AcmeHEDynRecords = @(Get-Cfg 'AcmeHEDynRecords' @())
$AcmeUseStaging   = Get-Cfg 'AcmeUseStaging'   $false
$DeployType       = Get-Cfg 'DeployType'       'PodePfx'
$IISSiteName      = Get-Cfg 'IISSiteName'      'Default Web Site'
$IISPort          = Get-Cfg 'IISPort'           443
$IISIPAddress     = Get-Cfg 'IISIPAddress'      '*'

if ($UseLetsEncrypt) {
    Write-Section -Title "Let's Encrypt" -Num 4 -Of 6

    # Contact email
    Write-Host ''
    Write-Hint "Let's Encrypt sends certificate expiry warnings to this address."
    do {
        $AcmeContact = Read-Input -Prompt 'Contact email' -Default $AcmeContact
        if ($AcmeContact -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Err 'Enter a valid email address'
            $AcmeContact = ''
        }
    } while (-not $AcmeContact)

    # Domain
    Write-Host ''
    Write-Hint 'The domain for the certificate. Must resolve publicly to this server.'
    Write-Hint 'Example: middleware.yourcompany.com'
    $domainDefault = if ($AcmeDomain) { $AcmeDomain } else { $Fqdn }
    do {
        $AcmeDomain = Read-Input -Prompt 'Domain' -Default $domainDefault
        if ($AcmeDomain -notmatch '\.[a-zA-Z]{2,}$') {
            Write-Err 'Enter a fully qualified domain name'
            $AcmeDomain = ''
        }
    } while (-not $AcmeDomain)

    # PFX export password
    Write-Host ''
    Write-Hint 'Password for the .pfx file Posh-ACME generates.'
    Write-Hint 'Pode uses this to load the certificate at startup.'
    $CertPassword = Read-Input -Prompt 'PFX export password' -Default $CertPassword -Secret
    if ([string]::IsNullOrWhiteSpace($CertPassword)) { $CertPassword = 'poshacme' }

    # HE DNS plugin
    Write-Host ''
    Write-Hint 'Hurricane Electric DNS validation - choose your method:'
    $defaultPlugin = if ($AcmePlugin -eq 'HurricaneElectricDyn') { 0 } else { 1 }
    $pluginIdx = Read-Choice `
        -Prompt  'DNS plugin:' `
        -Options @(
            'HurricaneElectricDyn (recommended) - per-record DynDNS key, never stores main HE password'
            'HurricaneElectric    - main HE account username + password (simpler, less secure)'
        ) `
        -Default $defaultPlugin

    if ($pluginIdx -eq 0) {
        $AcmePlugin = 'HurricaneElectricDyn'

        Write-Host ''
        Write-Hint 'Pre-requisite steps in dns.he.net:'
        Write-Host "    1.  Edit Zone for $AcmeDomain"                            -ForegroundColor Yellow
        Write-Host "    2.  Add TXT record:  _acme-challenge.$AcmeDomain"         -ForegroundColor Yellow
        Write-Host "    3.  Enable Dynamic DNS on that record"                    -ForegroundColor Yellow
        Write-Host "    4.  Click 'Generate a key' and copy the key for use below" -ForegroundColor Yellow

        $keepExisting = $false
        if ($AcmeHEDynRecords.Count -gt 0) {
            Write-Host ''
            Write-Hint "$($AcmeHEDynRecords.Count) DynDNS record(s) already configured."
            $keepExisting = Read-YesNo 'Keep existing DynDNS records?' $true
        }

        if (-not $keepExisting) {
            $dynRecords = @()
            $recNum     = 1
            $addAnother = $true
            while ($addAnother -and $recNum -le 2) {
                Write-Host ''
                Write-Hint "Record $recNum"
                $rec = Read-Input -Prompt 'Record name (e.g. _acme-challenge.yourdomain.com)'
                $key = Read-Input -Prompt 'DynDNS key' -Secret
                if ($rec -and $key) {
                    $dynRecords += @{ Record = $rec; Password = $key }
                    Write-Ok "Record $recNum saved"
                } else {
                    Write-Warn 'Skipped - both record name and key are required'
                }
                $recNum++
                if ($recNum -eq 2) {
                    $addAnother = Read-YesNo 'Add a second record? (only for wildcard certs)' $false
                }
            }
            $AcmeHEDynRecords = $dynRecords
        }

        if ($AcmeHEDynRecords.Count -eq 0) {
            Write-Warn 'No DynDNS records configured - add them before requesting a certificate'
        }

    } else {
        $AcmePlugin = 'HurricaneElectric'
        Write-Host ''
        Write-Warn 'Your main HE account password will be encrypted and stored in config.json.'
        Write-Hint 'Consider using HurricaneElectricDyn for better security.'
        Write-Host ''
        $AcmeHEUser = Read-Input -Prompt 'HE account username' -Default $AcmeHEUser
        $AcmeHEPass = Read-Input -Prompt 'HE account password' -Default $AcmeHEPass -Secret
    }

    # Deployment type
    Write-Host ''
    Write-Hint 'What happens after the certificate is issued or auto-renewed:'
    $defaultDeploy = switch ($DeployType) { 'WinCertStore' { 1 } 'IIS' { 2 } default { 0 } }
    $deployIdx = Read-Choice `
        -Prompt  'Deployment type:' `
        -Options @(
            'Pode PFX           (default) - write .pfx to certs folder, restart Pode. No admin rights needed.'
            'Windows Cert Store - also install into LocalMachine\My  (for RDP, WinRM, other Windows services)'
            'IIS Binding        - install to store AND update an IIS site HTTPS binding'
        ) `
        -Default $defaultDeploy

    $DeployType = switch ($deployIdx) { 1 { 'WinCertStore' } 2 { 'IIS' } default { 'PodePfx' } }

    if ($DeployType -eq 'IIS') {
        Write-Host ''
        Write-Hint 'IIS binding details:'
        $IISSiteName  = Read-Input -Prompt 'IIS site name'  -Default $IISSiteName
        $IISIPAddress = Read-Input -Prompt 'Binding IP'     -Default $IISIPAddress
        $IISPort      = Read-Port  -Prompt 'HTTPS port'     -Default $IISPort
    }

    # Staging
    Write-Host ''
    Write-Hint "Staging CA issues untrusted certs but has no rate limits."
    Write-Hint "Use for your first run to confirm DNS works, then disable."
    $AcmeUseStaging = Read-YesNo "Use Let's Encrypt staging CA?" $AcmeUseStaging
    if ($AcmeUseStaging) { Write-Warn 'Staging mode on - disable before going live' }

} else {
    Write-Section -Title "Let's Encrypt" -Num 4 -Of 6
    Write-Host ''
    Write-Hint 'Skipped.'
}

# ------------------------------------------------------------------------------
# SECTION 5 - LOGGING
# ------------------------------------------------------------------------------
Write-Section -Title 'Logging' -Num 5 -Of 6

Write-Host ''
Write-Hint 'Daily log files older than the retention period are deleted automatically.'
$retentionRaw  = Read-Input -Prompt 'Log retention (days)' -Default "$(Get-Cfg 'LogRetainDays' 30)"
$LogRetainDays = if ($retentionRaw -match '^\d+$') { [int]$retentionRaw } else { 30 }

# ------------------------------------------------------------------------------
# SECTION 6 - REVIEW
# ------------------------------------------------------------------------------
Write-Section -Title 'Review - confirm before writing' -Num 6 -Of 6
Write-Host ''
Write-Host '  +-- Network -----------------------------------------------+' -ForegroundColor DarkGray
Show-ReviewLine 'Port'           $Port
Show-ReviewLine 'Bind address'   $BindAddress
Show-ReviewLine 'FQDN / IP'      $Fqdn
Write-Host '  +-- Security ----------------------------------------------+' -ForegroundColor DarkGray
Show-ReviewLine 'Shared secret'  $Secret "$($Secret.Substring(0,[Math]::Min(6,$Secret.Length)))... [encrypted]"
Write-Host '  +-- HTTPS -------------------------------------------------+' -ForegroundColor DarkGray
Show-ReviewLine 'HTTPS enabled'  $UseHttps $(if ($UseHttps) { 'Yes' } else { 'No' })
if ($UseHttps) {
    if ($UseLetsEncrypt) {
        Show-ReviewLine 'Certificate'       "Let's Encrypt"
        Show-ReviewLine 'Contact email'     $AcmeContact
        Show-ReviewLine 'Domain'            $AcmeDomain
        Show-ReviewLine 'DNS plugin'        $AcmePlugin
        if ($AcmePlugin -eq 'HurricaneElectricDyn') {
            Show-ReviewLine 'DynDNS records' '' "$($AcmeHEDynRecords.Count) configured"
        } else {
            Show-ReviewLine 'HE username'    $AcmeHEUser
            Show-ReviewLine 'HE password'    '(set)' '[encrypted]'
        }
        Show-ReviewLine 'Deploy type'  $DeployType
        if ($DeployType -eq 'IIS') {
            Show-ReviewLine 'IIS site'    $IISSiteName
            Show-ReviewLine 'IIS IP'      $IISIPAddress
            Show-ReviewLine 'IIS port'    $IISPort
        }
        Show-ReviewLine 'Staging CA'   $AcmeUseStaging $(if ($AcmeUseStaging) { 'Yes (test mode)' } else { 'No (production)' })
    } else {
        Show-ReviewLine 'Certificate'  $CertPath
    }
    Show-ReviewLine 'PFX password'     '(set)' '[encrypted]'
}
Write-Host '  +-- Logging -----------------------------------------------+' -ForegroundColor DarkGray
Show-ReviewLine 'Log retention'  $LogRetainDays "$LogRetainDays days"
Write-Host '  +-- Paths -------------------------------------------------+' -ForegroundColor DarkGray
Show-ReviewLine 'Config'         $ConfigPath
Show-ReviewLine 'Data / certs'   $DataRoot
Write-Host '  +----------------------------------------------------------+' -ForegroundColor DarkGray
Write-Host ''

$confirmed = Read-YesNo 'Write settings and continue with installation?' $true
if (-not $confirmed) {
    Write-Host ''
    Write-Warn 'Setup cancelled - nothing written.'
    exit 0
}

# ==============================================================================
# WRITE ENCRYPTED CONFIG.JSON
# ==============================================================================
Write-Host ''
Write-Host '  Writing encrypted config.json ...' -ForegroundColor Cyan

$cfg = @{
    Port             = $Port
    BindAddress      = $BindAddress
    Fqdn             = $Fqdn
    UseHttps         = $UseHttps
    CertPath         = $CertPath
    CertPassword     = $CertPassword
    Secret           = $Secret
    LogRetainDays    = $LogRetainDays
    AcmeContact      = $AcmeContact
    AcmeDomain       = $AcmeDomain
    AcmePlugin       = $AcmePlugin
    AcmeHEUser       = $AcmeHEUser
    AcmeHEPass       = $AcmeHEPass
    AcmeHEDynRecords = $AcmeHEDynRecords
    AcmeUseStaging   = $AcmeUseStaging
    DeployType       = $DeployType
    IISSiteName      = $IISSiteName
    IISPort          = $IISPort
    IISIPAddress     = $IISIPAddress
    AcmePfxSrc       = Get-Cfg 'AcmePfxSrc' ''
    AcmePaHome       = Get-Cfg 'AcmePaHome' ''
}

Save-SecureConfig -Config $cfg -ConfigPath $ConfigPath
Write-Ok "config.json written to: $ConfigPath"
Write-Ok 'Secret, CertPassword, AcmeHEPass and DynDNS keys encrypted (DPAPI / LocalMachine)'

# ==============================================================================
# HAND OFF TO Install-Middleware.ps1
# ==============================================================================
if (-not $SkipInstall) {
    $installer = Join-Path $ScriptRoot 'Install-Middleware.ps1'
    if (Test-Path $installer) {
        Write-Host ''
        Write-Host ('  ' + ([char]9472) * 58) -ForegroundColor DarkGray
        Write-Host '  Running Install-Middleware.ps1 ...' -ForegroundColor Cyan
        Write-Host ''
        & $installer -Start
    } else {
        Write-Host ''
        Write-Warn "Install-Middleware.ps1 not found at: $installer"
        Write-Warn 'Run it manually to deploy files and register the scheduled task.'
    }
} else {
    Write-Host ''
    Write-Ok 'Settings saved. Run Install-Middleware.ps1 to complete deployment.'
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
$proto = if ($UseHttps) { 'https' } else { 'http' }
$base  = "${proto}://${Fqdn}:${Port}"

Write-Host ''
Write-Host ('  ' + ([char]9552) * 58) -ForegroundColor DarkCyan
Write-Host '   Setup complete'         -ForegroundColor Cyan
Write-Host ''
Write-Host '   URLs once the server is running:' -ForegroundColor DarkGray
Write-Host ''
Write-Host "     Settings     :  $base/settings"    -ForegroundColor White
Write-Host "     Certificate  :  $base/certificate" -ForegroundColor White
Write-Host "     Call log     :  $base/calls"       -ForegroundColor White
Write-Host "     Health       :  $base/health"      -ForegroundColor White
Write-Host ''
Write-Host '   3CX CRM ContactUrl:' -ForegroundColor DarkGray
Write-Host "     $base/notify?customerID=[EntityId]&phone=[Number]&agent=[Agent]" -ForegroundColor Yellow
Write-Host ''
if ($UseLetsEncrypt) {
    Write-Host "   Next - request your first certificate:" -ForegroundColor DarkGray
    $rScript = 'C:\Scripts\Applications\FieldRoutesCrmFor3CX\Invoke-CertificateRenewal.ps1'
    Write-Host "     pwsh -File `"$rScript`" -UseStaging"  -ForegroundColor DarkGray
    Write-Host '     Verify it works, then re-run without -UseStaging for a live cert.' -ForegroundColor DarkGray
    Write-Host ''
}
Write-Host ('  ' + ([char]9552) * 58) -ForegroundColor DarkCyan
Write-Host ''
