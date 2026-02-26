# ==============================================================================
# Install-Middleware.ps1  —  FieldRoutes CRM for 3CX
# ==============================================================================
# Deploys the FieldRoutes CRM for 3CX middleware to its canonical location and
# registers it as a Windows scheduled task that starts at boot and runs as SYSTEM.
#
# WHAT IT DOES:
#   1. Creates C:\Scripts\Applications\FieldRoutesCrmFor3CX\
#   2. Copies all server files from .\server\ into that folder
#   3. Creates C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX\ (data root)
#      and locks down ACLs on both directories
#   4. Installs the Pode module (AllUsers scope)
#   5. Registers a scheduled task:
#        Name     : FieldRoutesCrmFor3CX-Middleware
#        Execute  : pwsh.exe
#        Script   : C:\Scripts\Applications\FieldRoutesCrmFor3CX\Start-FieldRoutesCrmFor3CX.ps1
#        Trigger  : At system startup
#        Account  : SYSTEM (RunLevel Highest)
#        Recovery : Restart on failure (up to 3 times, 1 minute interval)
#   6. Optionally starts the task immediately
#
# USAGE (run once as Administrator):
#   pwsh -ExecutionPolicy Bypass -File .\Install-Middleware.ps1
#   pwsh -ExecutionPolicy Bypass -File .\Install-Middleware.ps1 -Start
#   pwsh -ExecutionPolicy Bypass -File .\Install-Middleware.ps1 -InstallPath D:\MyPath
#
# UNINSTALL:
#   Unregister-ScheduledTask -TaskName 'FieldRoutesCrmFor3CX-Middleware' -Confirm:$false
#   Remove-Item 'C:\Scripts\Applications\FieldRoutesCrmFor3CX' -Recurse -Force
#   (Data in C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX is preserved)
# ==============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\Scripts\Applications\FieldRoutesCrmFor3CX',
    [string]$DataRoot    = 'C:\ProgramData\Scripts\Settings\FieldRoutesCrmFor3CX',
    [string]$TaskName    = 'FieldRoutesCrmFor3CX-Middleware',
    [switch]$Start          # Start the task immediately after registering
)

$ErrorActionPreference = 'Stop'

# Source files are expected to be alongside this installer in a server\ subfolder
$SourceDir = Join-Path $PSScriptRoot '..\server'
if (-not (Test-Path $SourceDir)) {
    # Fallback: look for server\ next to this script's parent
    $SourceDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'server'
}

$MainScript = 'Start-FieldRoutesCrmFor3CX.ps1'

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-Step  { param([string]$m) Write-Host "`n  » $m"   -ForegroundColor Cyan    }
function Write-Ok    { param([string]$m) Write-Host "    ✓ $m"   -ForegroundColor Green   }
function Write-Warn  { param([string]$m) Write-Host "    ⚠ $m"   -ForegroundColor Yellow  }
function Write-Fail  { param([string]$m) Write-Host "    ✗ $m"   -ForegroundColor Red; throw $m }

function Set-TightAcl {
    param([string]$Path)
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)   # disable inheritance
        foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -Path $Path -AclObject $acl
        Write-Ok "ACL set on: $Path"
    } catch {
        Write-Warn "Could not set ACL on $Path (non-fatal): $_"
    }
}

# ── Banner ─────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host '   FieldRoutes CRM for 3CX — Middleware Installer'     -ForegroundColor White
Write-Host ''
Write-Host '   Install path : ' -NoNewline -ForegroundColor DarkGray
Write-Host $InstallPath         -ForegroundColor Cyan
Write-Host '   Data root    : ' -NoNewline -ForegroundColor DarkGray
Write-Host $DataRoot            -ForegroundColor Cyan
Write-Host '   Task name    : ' -NoNewline -ForegroundColor DarkGray
Write-Host $TaskName            -ForegroundColor Cyan
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray

# ── 1. Validate source ─────────────────────────────────────────────────────────
Write-Step 'Validating source files'
if (-not (Test-Path $SourceDir)) {
    Write-Fail "server\ source folder not found at: $SourceDir"
}
$requiredFiles = @(
    'Start-PestRoutesMiddleware.ps1'
    'Invoke-CertificateRenewal.ps1'
    'ProtectedConfig.psm1'
)
foreach ($f in $requiredFiles) {
    if (-not (Test-Path (Join-Path $SourceDir $f))) {
        Write-Fail "Required file missing from source: $f"
    }
}
Write-Ok "Source folder valid: $SourceDir"

# ── 2. Create install directory ────────────────────────────────────────────────
Write-Step "Creating install directory"
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    Write-Ok "Created: $InstallPath"
} else {
    Write-Warn "Already exists — files will be overwritten: $InstallPath"
}
Set-TightAcl $InstallPath

# ── 3. Copy server files ───────────────────────────────────────────────────────
Write-Step 'Copying server files'
$files = Get-ChildItem -Path $SourceDir -File
foreach ($file in $files) {
    $dest = Join-Path $InstallPath $file.Name
    Copy-Item -Path $file.FullName -Destination $dest -Force
    Write-Ok "Copied: $($file.Name)"
}

# Rename the main script to its canonical name if it was deployed with the old name
$oldMain = Join-Path $InstallPath 'Start-PestRoutesMiddleware.ps1'
$newMain = Join-Path $InstallPath $MainScript
if ((Test-Path $oldMain) -and -not (Test-Path $newMain)) {
    Rename-Item -Path $oldMain -NewName $MainScript
    Write-Ok "Renamed main script to: $MainScript"
} elseif (Test-Path $newMain) {
    Write-Ok "Main script present: $MainScript"
}

# Create certs subfolder inside install dir (empty placeholder — data goes to DataRoot)
$localCerts = Join-Path $InstallPath 'certs'
if (-not (Test-Path $localCerts)) {
    New-Item -ItemType Directory -Path $localCerts -Force | Out-Null
}

# ── 4. Create data root ────────────────────────────────────────────────────────
Write-Step "Creating ProgramData data root"
foreach ($sub in @($DataRoot, (Join-Path $DataRoot 'certs'), (Join-Path $DataRoot 'logs'))) {
    if (-not (Test-Path $sub)) {
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Write-Ok "Created: $sub"
    } else {
        Write-Ok "Exists : $sub"
    }
}
Set-TightAcl $DataRoot

# ── 5. Install Pode module ─────────────────────────────────────────────────────
Write-Step 'Installing Pode module (AllUsers)'
$existing = Get-Module -ListAvailable -Name Pode |
            Sort-Object Version -Descending | Select-Object -First 1
if ($existing) {
    Write-Ok "Pode already installed (v$($existing.Version))"
    try {
        Update-Module -Name Pode -Scope AllUsers -Force -ErrorAction SilentlyContinue
        $updated = Get-Module -ListAvailable -Name Pode |
                   Sort-Object Version -Descending | Select-Object -First 1
        if ($updated.Version -gt $existing.Version) {
            Write-Ok "Updated to v$($updated.Version)"
        }
    } catch {
        Write-Warn "Update check skipped: $_"
    }
} else {
    # Ensure NuGet first
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Pode -Scope AllUsers -Force -AllowClobber
    $installed = Get-Module -ListAvailable -Name Pode |
                 Sort-Object Version -Descending | Select-Object -First 1
    Write-Ok "Installed v$($installed.Version)"
}

# ── 6. Register scheduled task ─────────────────────────────────────────────────
Write-Step "Registering scheduled task: $TaskName"

$scriptPath = Join-Path $InstallPath $MainScript

$action = New-ScheduledTaskAction `
    -Execute        'pwsh.exe' `
    -Argument       "-NonInteractive -WindowStyle Hidden -File `"$scriptPath`"" `
    -WorkingDirectory $InstallPath

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit    (New-TimeSpan -Hours 0) `   # no timeout — server runs forever
    -RestartCount          3                           `
    -RestartInterval       (New-TimeSpan -Minutes 1)  `
    -StartWhenAvailable    $true

$principal = New-ScheduledTaskPrincipal `
    -UserId    'SYSTEM' `
    -RunLevel  Highest

# Remove existing task if present (allows re-running installer as an update)
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Warn "Task already exists — replacing"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName   $TaskName `
    -Action     $action   `
    -Trigger    $trigger  `
    -Settings   $settings `
    -Principal  $principal `
    -Description "FieldRoutes CRM for 3CX popup middleware. Managed by Install-Middleware.ps1." `
    -Force | Out-Null

Write-Ok "Task registered: $TaskName"
Write-Ok "Runs as SYSTEM at startup, restarts up to 3x on failure"

# ── 7. Optionally start now ────────────────────────────────────────────────────
if ($Start) {
    Write-Step 'Starting task'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Ok "Task state: $state"
}

# ── 8. Firewall rule ───────────────────────────────────────────────────────────
Write-Step 'Checking firewall rule'
$fwRule = Get-NetFirewallRule -DisplayName 'FieldRoutes CRM for 3CX' -ErrorAction SilentlyContinue
if ($fwRule) {
    Write-Ok 'Firewall rule already present'
} else {
    Write-Warn 'No firewall rule found — creating inbound rule for port 3000'
    try {
        New-NetFirewallRule `
            -DisplayName  'FieldRoutes CRM for 3CX' `
            -Description  'Allow inbound connections to the FieldRoutes CRM for 3CX middleware' `
            -Direction    Inbound `
            -Protocol     TCP `
            -LocalPort    3000 `
            -Action       Allow | Out-Null
        Write-Ok 'Firewall rule created (TCP inbound port 3000)'
        Write-Warn 'Update the port in the firewall rule if you change it in settings'
    } catch {
        Write-Warn "Could not create firewall rule (non-fatal): $_"
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host '   Installation complete'                               -ForegroundColor Green
Write-Host ''
Write-Host '   Scripts      : ' -NoNewline -ForegroundColor DarkGray; Write-Host $InstallPath -ForegroundColor Cyan
Write-Host '   Data & certs : ' -NoNewline -ForegroundColor DarkGray; Write-Host $DataRoot    -ForegroundColor Cyan
Write-Host '   Task         : ' -NoNewline -ForegroundColor DarkGray; Write-Host $TaskName    -ForegroundColor Cyan
Write-Host ''
Write-Host '   Next steps:'                                                                        -ForegroundColor DarkGray
Write-Host '     1. Run Installs\Install-PoshAcme.ps1 if not already done'                        -ForegroundColor DarkGray
Write-Host '     2. Open http://localhost:3000/settings to configure port, FQDN, and secret'      -ForegroundColor DarkGray
Write-Host '     3. Open http://localhost:3000/certificate to set up Let''s Encrypt'               -ForegroundColor DarkGray
Write-Host '     4. Update the 3CX CRM template ContactUrl with the notify endpoint'              -ForegroundColor DarkGray
Write-Host "     5. Reboot or run: Start-ScheduledTask -TaskName '$TaskName'"                     -ForegroundColor DarkGray
Write-Host '  ════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host ''
