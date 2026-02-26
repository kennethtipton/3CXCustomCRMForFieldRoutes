# ==============================================================================
# ProtectedConfig.psm1  —  FieldRoutes CRM for 3CX
# ==============================================================================
# DPAPI-backed helpers for storing and retrieving sensitive values in config.json.
#
# All encryption uses LocalMachine scope so any process running as SYSTEM or
# Administrators on this machine can decrypt — compatible with scheduled tasks,
# the Pode web server, and the renewal script regardless of which account runs them.
#
# On-disk format for a protected value (stored as a JSON object):
#   { "protected": true, "data": "<Base64 DPAPI blob>" }
#
# Plaintext strings are stored as plain JSON strings (backward compatible).
# The helpers detect the format automatically so Read-Config works whether
# a value was written before or after encryption was introduced.
#
# USAGE (both scripts do this at the top of their PATHS block):
#   Import-Module (Join-Path $PSScriptRoot 'ProtectedConfig.psm1') -Force
#
# FUNCTIONS:
#   Protect-Value   [string] -> [hashtable]  Encrypts a plaintext string
#   Unprotect-Value [object] -> [string]     Decrypts a protected object or
#                                            passes through a plain string
#   Read-SecureConfig  [path] -> [hashtable] Reads config.json, decrypting all
#                                            protected fields transparently
#   Save-SecureConfig  [hashtable] [path]    Encrypts sensitive fields then
#                                            writes config.json
# ==============================================================================

Add-Type -AssemblyName System.Security   # for ProtectedData

# Scope: LocalMachine — decryptable by SYSTEM and Administrators on this machine.
# Do NOT use CurrentUser scope; scheduled tasks running as SYSTEM cannot decrypt
# values protected under a different user account.
$Script:Scope    = [System.Security.Cryptography.DataProtectionScope]::LocalMachine
$Script:Encoding = [System.Text.Encoding]::UTF8

# Fields in config.json that contain sensitive data and must be encrypted.
# AcmeHEDynRecords is handled separately (array of objects with a Password sub-field).
$Script:SensitiveFields = @('Secret', 'CertPassword', 'AcmeHEPass')

# ==============================================================================
# Protect-Value
# Encrypts a plaintext string using DPAPI (LocalMachine scope).
# Returns a hashtable that serializes to: {"protected":true,"data":"BASE64"}
# Returns $null if the input is null or empty (nothing to encrypt).
# ==============================================================================
function Protect-Value {
    [CmdletBinding()]
    param([string]$Plaintext)

    if ([string]::IsNullOrEmpty($Plaintext)) { return $null }

    $bytes     = $Script:Encoding.GetBytes($Plaintext)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
                     $bytes, $null, $Script:Scope)
    return @{
        protected = $true
        data      = [Convert]::ToBase64String($encrypted)
    }
}

# ==============================================================================
# Unprotect-Value
# Accepts either:
#   - A hashtable/PSCustomObject with {protected=$true; data="BASE64"} -> decrypts
#   - A plain string                                                    -> returns as-is
#   - $null / empty                                                     -> returns ''
# ==============================================================================
function Unprotect-Value {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return '' }

    # Plain string — written before encryption was introduced, or not sensitive
    if ($Value -is [string]) { return $Value }

    # Protected object
    $obj = $Value
    if ($obj.protected -eq $true -and $obj.data) {
        try {
            $encrypted = [Convert]::FromBase64String($obj.data)
            $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                             $encrypted, $null, $Script:Scope)
            return $Script:Encoding.GetString($decrypted)
        } catch {
            Write-Warning "ProtectedConfig: failed to decrypt value — returning empty string. Error: $_"
            return ''
        }
    }

    # Unrecognised shape — treat as plain string representation
    return [string]$Value
}

# ==============================================================================
# Read-SecureConfig
# Reads config.json from $ConfigPath and returns a plain hashtable with all
# sensitive fields already decrypted to plaintext strings.
# AcmeHEDynRecords passwords are decrypted individually.
# ==============================================================================
function Read-SecureConfig {
    [CmdletBinding()]
    param([string]$ConfigPath)

    $defaults = @{
        Port             = 3000
        BindAddress      = '*'
        Fqdn             = 'YOUR_SERVER_IP'
        UseHttps         = $false
        CertPath         = ''
        CertPassword     = ''
        Secret           = 'CHANGE_ME_TO_A_RANDOM_SECRET_STRING'
        LogRetainDays    = 30
        AcmeContact      = ''
        AcmeDomain       = ''
        AcmePlugin       = 'HurricaneElectric'
        AcmeHEUser       = ''
        AcmeHEPass       = ''
        AcmeHEDynRecords = @()
        AcmeUseStaging   = $false
        DeployType       = 'PodePfx'
        IISSiteName      = 'Default Web Site'
        IISPort          = 443
        IISIPAddress     = '*'
        AcmePfxSrc       = ''
        AcmePaHome       = ''
    }

    if (-not (Test-Path $ConfigPath)) { return $defaults }

    try {
        $raw = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

        foreach ($key in $raw.PSObject.Properties.Name) {
            $val = $raw.$key

            if ($key -in $Script:SensitiveFields) {
                # Decrypt if protected, pass through if plain string
                $defaults[$key] = Unprotect-Value $val
            }
            elseif ($key -eq 'AcmeHEDynRecords') {
                # Array of { Record, Password } — decrypt each Password
                $defaults[$key] = @($val | ForEach-Object {
                    @{
                        Record   = $_.Record
                        Password = Unprotect-Value $_.Password
                    }
                })
            }
            else {
                $defaults[$key] = $val
            }
        }
    } catch {
        Write-Warning "ProtectedConfig: could not read $ConfigPath — using defaults. Error: $_"
    }

    return $defaults
}

# ==============================================================================
# Save-SecureConfig
# Takes a plain-text config hashtable, encrypts all sensitive fields,
# then writes the result to $ConfigPath as formatted JSON.
# ==============================================================================
function Save-SecureConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]   $ConfigPath
    )

    # Build a copy so we don't mutate the caller's hashtable
    $toWrite = @{}
    foreach ($key in $Config.Keys) {
        $val = $Config[$key]

        if ($key -in $Script:SensitiveFields) {
            if ([string]::IsNullOrEmpty($val)) {
                $toWrite[$key] = $null
            } else {
                $toWrite[$key] = Protect-Value $val
            }
        }
        elseif ($key -eq 'AcmeHEDynRecords') {
            $toWrite[$key] = @(@($val) | ForEach-Object {
                @{
                    Record   = $_.Record
                    Password = if ($_.Password) { Protect-Value $_.Password } else { $null }
                }
            })
        }
        else {
            $toWrite[$key] = $val
        }
    }

    $toWrite | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding utf8
}

Export-ModuleMember -Function Protect-Value, Unprotect-Value, Read-SecureConfig, Save-SecureConfig
