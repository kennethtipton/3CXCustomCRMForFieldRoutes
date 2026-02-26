# ==============================================================================
# Install-PoshAcme.ps1
# ==============================================================================
# Installs Posh-ACME and Posh-ACME.Deploy, then configures the default
# certificate storage directory to:
#   C:\Scripts\Applications\FieldRoutesCrmFor3CX\LetsEncrypt\Certs
#
# USAGE:
#   Run once as Administrator from an elevated PowerShell session:
#   pwsh -ExecutionPolicy Bypass -File .\Install-PoshAcme.ps1
#
# WHAT IT DOES:
#   1. Ensures NuGet provider is available (required by Install-Module)
#   2. Installs Posh-ACME          (from PSGallery, scope AllUsers)
#   3. Installs Posh-ACME.Deploy   (from PSGallery, scope AllUsers)
#   4. Creates C:\Scripts\Applications\FieldRoutesCrmFor3CX\LetsEncrypt\Certs
#   5. Sets POSHACME_HOME environment variable (machine-level) so Posh-ACME
#      writes all account data, orders, and certificates to that folder
#   6. Verifies the installation
# ==============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$CertRoot    = 'C:\Scripts\Applications\FieldRoutesCrmFor3CX\LetsEncrypt\Certs',
    [string]$SettingsDir = 'C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX'
)

$ErrorActionPreference = 'Stop'

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-Step  { param([string]$m) Write-Host "`n  » $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "    ✓ $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "    ⚠ $m" -ForegroundColor Yellow }
function Write-Fail  { param([string]$m) Write-Host "    ✗ $m" -ForegroundColor Red; throw $m }

Write-Host ''
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host '   FieldRoutes CRM for 3CX — Posh-ACME Installer' -ForegroundColor White
Write-Host '   Certificate root: ' -NoNewline -ForegroundColor DarkGray
Write-Host $CertRoot -ForegroundColor Cyan
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray

# ── 1. NuGet provider ─────────────────────────────────────────────────────────
Write-Step 'Checking NuGet provider'
$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
    Write-Warn 'NuGet provider missing or outdated — installing'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    Write-Ok 'NuGet provider installed'
} else {
    Write-Ok "NuGet provider present (v$($nuget.Version))"
}

# ── 2. Trust PSGallery ────────────────────────────────────────────────────────
Write-Step 'Trusting PSGallery repository'
$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if ($gallery.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Write-Ok 'PSGallery set to Trusted'
} else {
    Write-Ok 'PSGallery already trusted'
}

# ── 3. Install Posh-ACME ──────────────────────────────────────────────────────
Write-Step 'Installing Posh-ACME'
$existing = Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending | Select-Object -First 1
if ($existing) {
    Write-Warn "Already installed (v$($existing.Version)) — checking for updates"
    try {
        Update-Module -Name Posh-ACME -Force
        $updated = Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending | Select-Object -First 1
        Write-Ok "Updated to v$($updated.Version)"
    } catch {
        Write-Warn "Update skipped: $_"
        Write-Ok "Keeping v$($existing.Version)"
    }
} else {
    Install-Module -Name Posh-ACME -Scope AllUsers -Force -AllowClobber
    $installed = Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending | Select-Object -First 1
    Write-Ok "Installed v$($installed.Version)"
}

# ── 4. Install Posh-ACME.Deploy ───────────────────────────────────────────────
Write-Step 'Installing Posh-ACME.Deploy'
$existingD = Get-Module -ListAvailable -Name Posh-ACME.Deploy | Sort-Object Version -Descending | Select-Object -First 1
if ($existingD) {
    Write-Warn "Already installed (v$($existingD.Version)) — checking for updates"
    try {
        Update-Module -Name Posh-ACME.Deploy -Force
        $updatedD = Get-Module -ListAvailable -Name Posh-ACME.Deploy | Sort-Object Version -Descending | Select-Object -First 1
        Write-Ok "Updated to v$($updatedD.Version)"
    } catch {
        Write-Warn "Update skipped: $_"
        Write-Ok "Keeping v$($existingD.Version)"
    }
} else {
    Install-Module -Name Posh-ACME.Deploy -Scope AllUsers -Force -AllowClobber
    $installedD = Get-Module -ListAvailable -Name Posh-ACME.Deploy | Sort-Object Version -Descending | Select-Object -First 1
    Write-Ok "Installed v$($installedD.Version)"
}

# ── 5. Create certificate directory ───────────────────────────────────────────
Write-Step "Creating certificate directory"
if (-not (Test-Path $CertRoot)) {
    New-Item -ItemType Directory -Path $CertRoot -Force | Out-Null
    Write-Ok "Created: $CertRoot"
} else {
    Write-Ok "Already exists: $CertRoot"
}

# Secure the folder — only SYSTEM and Administrators should have access
# (private keys will live here)
Write-Step 'Securing directory permissions'
try {
    $acl   = Get-Acl $CertRoot
    $acl.SetAccessRuleProtection($true, $false)   # disable inheritance

    $adminRule  = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')

    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $CertRoot -AclObject $acl
    Write-Ok 'Permissions set: Administrators + SYSTEM (full control, inheritance disabled)'
} catch {
    Write-Warn "Could not set ACL (non-fatal): $_"
}

# ── 5b. Create and secure ProgramData settings directory ─────────────────────
Write-Step "Creating ProgramData settings directory"
if (-not (Test-Path $SettingsDir)) {
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
    Write-Ok "Created: $SettingsDir"
} else {
    Write-Ok "Already exists: $SettingsDir"
}

# Apply same tight ACL — config.json contains credentials
Write-Step 'Securing settings directory permissions'
try {
    $saclObj   = Get-Acl $SettingsDir
    $saclObj.SetAccessRuleProtection($true, $false)
    $sAdminR   = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $sSystemR  = [System.Security.AccessControl.FileSystemAccessRule]::new(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $saclObj.AddAccessRule($sAdminR)
    $saclObj.AddAccessRule($sSystemR)
    Set-Acl -Path $SettingsDir -AclObject $saclObj
    Write-Ok 'Permissions set: Administrators + SYSTEM (full control, inheritance disabled)'
} catch {
    Write-Warn "Could not set ACL on settings dir (non-fatal): $_"
}

# ── 6. Set POSHACME_HOME environment variable ─────────────────────────────────
# This tells Posh-ACME where to store its working directory (accounts, orders,
# certs). Setting it at Machine scope means it applies to all users and to
# scheduled tasks running as SYSTEM.
Write-Step 'Setting POSHACME_HOME environment variable'
$currentVal = [System.Environment]::GetEnvironmentVariable('POSHACME_HOME', 'Machine')
if ($currentVal -eq $CertRoot) {
    Write-Ok "POSHACME_HOME already set to: $CertRoot"
} else {
    if ($currentVal) {
        Write-Warn "Overwriting existing value: $currentVal"
    }
    [System.Environment]::SetEnvironmentVariable('POSHACME_HOME', $CertRoot, 'Machine')
    Write-Ok "POSHACME_HOME = $CertRoot  (Machine scope)"
}

# Also set for the current process so we can verify without a restart
$env:POSHACME_HOME = $CertRoot

# ── 7. Verify ─────────────────────────────────────────────────────────────────
Write-Step 'Verifying installation'
try {
    Import-Module Posh-ACME        -Force -ErrorAction Stop
    Import-Module Posh-ACME.Deploy -Force -ErrorAction Stop

    $paVer  = (Get-Module Posh-ACME).Version
    $padVer = (Get-Module Posh-ACME.Deploy).Version
    Write-Ok "Posh-ACME        v$paVer loaded"
    Write-Ok "Posh-ACME.Deploy v$padVer loaded"

    # Confirm Posh-ACME sees the correct home directory
    $home = Get-PAHome -ErrorAction SilentlyContinue
    if ($home -and (Resolve-Path $home -ErrorAction SilentlyContinue)) {
        Write-Ok "Posh-ACME home   : $home"
    } else {
        Write-Ok "Posh-ACME home   : $CertRoot  (will initialise on first use)"
    }
} catch {
    Write-Fail "Module import failed: $_"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host '   Installation complete' -ForegroundColor Green
Write-Host ''
Write-Host '   Settings directory    : $SettingsDir
   Certificate directory : ' -NoNewline -ForegroundColor DarkGray
Write-Host $CertRoot -ForegroundColor Cyan
Write-Host '   POSHACME_HOME         : Machine environment variable' -ForegroundColor DarkGray
Write-Host ''
Write-Host '   Next steps:' -ForegroundColor DarkGray
Write-Host '     1. Close and re-open PowerShell so POSHACME_HOME takes effect' -ForegroundColor DarkGray
Write-Host '     2. config.json and certs are stored in: $SettingsDir
     3. ProtectedConfig.psm1 encrypts credentials in config.json automatically
        on first save — no manual steps needed
     4. Run Invoke-CertificateRenewal.ps1 to request your first cert' -ForegroundColor DarkGray
Write-Host '     3. Use -UseStaging on first run to verify DNS without hitting' -ForegroundColor DarkGray
Write-Host '        rate limits (staging certs are untrusted but otherwise identical)' -ForegroundColor DarkGray
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host ''
