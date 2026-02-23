#Requires -Version 5.1
<#
.SYNOPSIS
    Tests the FieldRoutesCRMfor3CX REST API scenarios against the live FieldRoutes API.

.DESCRIPTION
    This script replicates exactly what the 3CX CRM engine does when:
      - Scenario 1: An inbound call arrives and 3CX looks up the caller by phone number
      - Scenario 2: A call ends and 3CX posts a note to the customer record (ReportCall)

    Run this BEFORE importing the XML template into 3CX to confirm your credentials
    and API endpoints are working correctly.

.PARAMETER OfficeID
    Your FieldRoutes numeric Office ID.

.PARAMETER AuthKey
    Your FieldRoutes Authentication Key.

.PARAMETER AuthToken
    Your FieldRoutes Authentication Token.

.PARAMETER CompanyName
    Your FieldRoutes subdomain (e.g. "mycompany" from https://mycompany.fieldroutes.com).

.PARAMETER PhoneNumber
    The 10-digit phone number to look up (digits only, no dashes, spaces, or +1).
    Example: 5551234567

.PARAMETER TestReportCall
    If specified, also tests the ReportCall (note creation) scenario.
    Requires a valid CustomerID found from the phone lookup.

.PARAMETER CustomerID
    Override CustomerID to use for the ReportCall test. If not provided,
    the script will use the CustomerID found in the phone lookup.

.EXAMPLE
    .\Test-FieldRoutesCRM.ps1 -OfficeID 1234 -AuthKey "mykey" -AuthToken "mytoken" `
        -CompanyName "mycompany" -PhoneNumber "5551234567"

.EXAMPLE
    .\Test-FieldRoutesCRM.ps1 -OfficeID 1234 -AuthKey "mykey" -AuthToken "mytoken" `
        -CompanyName "mycompany" -PhoneNumber "5551234567" -TestReportCall

.NOTES
    Author  : FieldRoutesCRMfor3CX Project
    Version : 1.0
    Requires: PowerShell 5.1 or later. Internet access to fieldroutes.com.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$OfficeID,

    [Parameter(Mandatory = $true)]
    [string]$AuthKey,

    [Parameter(Mandatory = $true)]
    [string]$AuthToken,

    [Parameter(Mandatory = $true)]
    [string]$CompanyName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{10}$')]
    [string]$PhoneNumber,

    [Parameter(Mandatory = $false)]
    [switch]$TestReportCall,

    [Parameter(Mandatory = $false)]
    [string]$CustomerID
)

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Header {
    param([string]$Title)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ── $Title" -ForegroundColor Yellow
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-Detail {
    param([string]$Label, [string]$Value)
    Write-Host ("  {0,-22} {1}" -f "$Label :", $Value) -ForegroundColor White
}

function Format-PhoneNumber {
    <#
    .SYNOPSIS
        Replicates the 3CX Number element transformation.
        Strips +1 / 001 / 1 country code prefix and takes last 10 digits.
    #>
    param([string]$RawNumber)

    # Remove all non-digit characters
    $digits = $RawNumber -replace '\D', ''

    # Take last 10 digits (replicates MaxLength="10")
    if ($digits.Length -gt 10) {
        $digits = $digits.Substring($digits.Length - 10)
    }

    return $digits
}

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT START
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "FieldRoutesCRMfor3CX — REST Scenario Tester"

Write-Section "Configuration"
Write-Detail "OfficeID"     $OfficeID
Write-Detail "CompanyName"  $CompanyName
Write-Detail "AuthKey"      ("*" * [Math]::Min($AuthKey.Length, 6) + "..." )
Write-Detail "AuthToken"    ("*" * [Math]::Min($AuthToken.Length, 6) + "...")
Write-Detail "PhoneNumber"  $PhoneNumber
Write-Detail "Test ReportCall" $(if ($TestReportCall) { "Yes" } else { "No" })

$BaseUrl = "https://$CompanyName.fieldroutes.com"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: PHONE NUMBER FORMATTING (mirrors the <Number> XML element)
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "PHASE 1 — Phone Number Formatting (mirrors <Number Prefix=Off MaxLength=10/>)"

$FormattedPhone = Format-PhoneNumber -RawNumber $PhoneNumber
Write-Detail "Raw Input"     $PhoneNumber
Write-Detail "Formatted"     $FormattedPhone

if ($FormattedPhone -match '^\d{10}$') {
    Write-Pass "Phone number is valid 10-digit format for FieldRoutes API."
} else {
    Write-Fail "Phone number did not format to 10 digits. Got: '$FormattedPhone'"
    Write-Host ""
    Write-Host "  Please provide a 10-digit US phone number (digits only)." -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: SCENARIO 1 — CUSTOMER LOOKUP BY PHONE NUMBER
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "PHASE 2 — Scenario 1: Customer Lookup by Phone Number"
Write-Info "This mirrors what 3CX does on every inbound call."

$LookupUrl = "$BaseUrl/api/customer/search" +
             "?officeID=$OfficeID" +
             "&authenticationKey=$([Uri]::EscapeDataString($AuthKey))" +
             "&authenticationToken=$([Uri]::EscapeDataString($AuthToken))" +
             "&phone=$FormattedPhone" +
             "&includeData=1"

Write-Section "Request"
# Mask credentials in displayed URL for security
$DisplayUrl = "$BaseUrl/api/customer/search?officeID=$OfficeID" +
              "&authenticationKey=****&authenticationToken=****" +
              "&phone=$FormattedPhone&includeData=1"
Write-Detail "Method"  "GET"
Write-Detail "URL"     $DisplayUrl

$LookupSuccess = $false
$FoundCustomerID = $null
$LookupResponse = $null

try {
    Write-Info "Sending request..."
    $Response = Invoke-WebRequest -Uri $LookupUrl -Method GET -UseBasicParsing -ErrorAction Stop
    $LookupResponse = $Response.Content | ConvertFrom-Json

    Write-Section "Response — HTTP Status"
    Write-Detail "Status Code"  $Response.StatusCode
    Write-Detail "Status"       $Response.StatusDescription

    if ($Response.StatusCode -eq 200) {
        Write-Pass "HTTP 200 OK received."
    } else {
        Write-Fail "Unexpected HTTP status: $($Response.StatusCode)"
    }

    Write-Section "Response — API Result"

    # Check the "success" flag
    if ($LookupResponse.PSObject.Properties.Name -contains 'success') {
        Write-Detail "success"  $LookupResponse.success
        if ($LookupResponse.success -eq $true) {
            Write-Pass "API returned success: true"
        } else {
            Write-Fail "API returned success: false"
            if ($LookupResponse.PSObject.Properties.Name -contains 'errorMessage') {
                Write-Detail "errorMessage" $LookupResponse.errorMessage
            }
        }
    }

    # Check customer count
    if ($LookupResponse.PSObject.Properties.Name -contains 'count') {
        Write-Detail "count"  $LookupResponse.count
    }

    # Parse the customers object (keyed by customerID)
    if ($LookupResponse.PSObject.Properties.Name -contains 'customers') {
        $Customers = $LookupResponse.customers
        $CustomerKeys = $Customers.PSObject.Properties.Name

        if ($CustomerKeys.Count -eq 0) {
            Write-Fail "No customers found for phone number: $FormattedPhone"
            Write-Info "Check that the phone number exists in FieldRoutes and matches exactly."
        } else {
            Write-Pass "$($CustomerKeys.Count) customer record(s) found."
            $LookupSuccess = $true

            foreach ($Key in $CustomerKeys) {
                $Customer = $Customers.$Key

                Write-Section "Customer Record — Key: $Key"

                # These are the exact fields the XML template extracts as Variables
                $FoundCustomerID  = $Customer.customerID
                $FirstName        = $Customer.fname
                $LastName         = $Customer.lname
                $CompanyNameField = $Customer.companyName
                $Email            = $Customer.email
                $Phone1           = $Customer.phone1
                $Phone2           = $Customer.phone2

                Write-Detail "customerID"   $FoundCustomerID
                Write-Detail "fname"        $FirstName
                Write-Detail "lname"        $LastName
                Write-Detail "companyName"  $CompanyNameField
                Write-Detail "email"        $Email
                Write-Detail "phone1"       $Phone1
                Write-Detail "phone2"       $Phone2

                # Simulate the <Outputs> section
                Write-Section "3CX Outputs (what would be sent to the operator)"
                $ContactUrl = "$BaseUrl/customer/$FoundCustomerID"
                Write-Detail "ContactUrl"      $ContactUrl
                Write-Detail "FirstName"       $FirstName
                Write-Detail "LastName"        $LastName
                Write-Detail "CompanyName"     $CompanyNameField
                Write-Detail "Email"           $Email
                Write-Detail "PhoneBusiness"   $Phone1
                Write-Detail "PhoneHome"       $Phone2
                Write-Detail "EntityId"        $FoundCustomerID
                Write-Detail "EntityType"      "Customer"

                Write-Section "3CX Behavior Simulation"
                Write-Pass "ContactUrl constructed: $ContactUrl"
                Write-Info "When operator ANSWERS the call, 3CX will open this URL in their browser."
                Write-Info "(Requires 'Open Contact URL on: Answer' in 3CX CRM Integration settings)"

                # Validate: at least one name field must be populated
                if ($FirstName -or $LastName -or $CompanyNameField) {
                    Write-Pass "Name validation passed (FirstName/LastName/CompanyName present)."
                } else {
                    Write-Fail "Name validation FAILED — none of fname/lname/companyName are populated."
                }

                # Validate: at least one phone field must match the searched number
                $PhoneMatch = ($Phone1 -eq $FormattedPhone) -or ($Phone2 -eq $FormattedPhone)
                if ($PhoneMatch) {
                    Write-Pass "Phone match validation passed — a phone field matches the searched number."
                } else {
                    Write-Fail "Phone match WARNING — neither phone1 ('$Phone1') nor phone2 ('$Phone2') " +
                               "exactly matches searched number '$FormattedPhone'."
                    Write-Info "3CX requires a phone output field to equal the searched number for a valid match."
                    Write-Info "This may cause the contact to not display in 3CX even though the API found them."
                }
            }
        }
    } else {
        Write-Fail "Response JSON does not contain a 'customers' property."
        Write-Info "Raw response (first 500 chars):"
        Write-Host ($Response.Content.Substring(0, [Math]::Min(500, $Response.Content.Length))) -ForegroundColor DarkGray
    }

} catch [System.Net.WebException] {
    $StatusCode = [int]$_.Exception.Response.StatusCode
    Write-Fail "HTTP request failed with status: $StatusCode"
    Write-Detail "Error"  $_.Exception.Message

    switch ($StatusCode) {
        401 { Write-Info "401 Unauthorized — Check your AuthKey and AuthToken." }
        403 { Write-Info "403 Forbidden — Your credentials may not have API access. Contact FieldRoutes support." }
        404 { Write-Info "404 Not Found — Check your CompanyName subdomain: '$CompanyName'" }
        429 { Write-Info "429 Too Many Requests — Rate limited. Wait and try again." }
        500 { Write-Info "500 Server Error — FieldRoutes API error. Try again or contact support." }
        default { Write-Info "Check your CompanyName, OfficeID, AuthKey, and AuthToken." }
    }
} catch {
    Write-Fail "Unexpected error during lookup request."
    Write-Detail "Error"  $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: SCENARIO 2 — REPORT CALL (note creation)
# ─────────────────────────────────────────────────────────────────────────────

if ($TestReportCall) {
    Write-Header "PHASE 3 — Scenario 2: ReportCall (Note Creation)"
    Write-Info "This mirrors what 3CX does after a call ends."

    # Determine which CustomerID to use
    $TestCustomerID = if ($CustomerID) { $CustomerID } else { $FoundCustomerID }

    if (-not $TestCustomerID) {
        Write-Fail "No CustomerID available for ReportCall test."
        Write-Info "Either provide -CustomerID on the command line, or ensure the phone lookup found a customer."
    } else {
        Write-Detail "CustomerID" $TestCustomerID

        # Simulate the 3CX predefined variables that would be present
        $SimCallType       = "Inbound"
        $SimNumber         = $FormattedPhone
        $SimAgentFirstName = "Test"
        $SimAgentLastName  = "Operator"
        $SimDuration       = "00:02:35"
        $SimDateTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        $NoteText = "3CX Call Log | Type: $SimCallType | Number: $SimNumber | " +
                    "Agent: $SimAgentFirstName $SimAgentLastName | " +
                    "Duration: $SimDuration | Date: $SimDateTime"

        $NoteUrl = "$BaseUrl/api/note/create"

        Write-Section "Request"
        Write-Detail "Method"  "POST (application/x-www-form-urlencoded)"
        Write-Detail "URL"     $NoteUrl

        $PostBody = @{
            officeID            = $OfficeID
            authenticationKey   = $AuthKey
            authenticationToken = $AuthToken
            customerID          = $TestCustomerID
            notes               = $NoteText
        }

        Write-Section "POST Body (simulated 3CX variables)"
        Write-Detail "officeID"    $OfficeID
        Write-Detail "customerID"  $TestCustomerID
        Write-Detail "notes"       $NoteText

        try {
            Write-Info "Sending ReportCall (note create) request..."
            $NoteResponse = Invoke-WebRequest -Uri $NoteUrl -Method POST -Body $PostBody `
                                -ContentType "application/x-www-form-urlencoded" `
                                -UseBasicParsing -ErrorAction Stop

            $NoteResult = $NoteResponse.Content | ConvertFrom-Json

            Write-Section "Response"
            Write-Detail "Status Code"  $NoteResponse.StatusCode

            if ($NoteResponse.StatusCode -eq 200) {
                Write-Pass "HTTP 200 OK received."
            }

            if ($NoteResult.PSObject.Properties.Name -contains 'success') {
                Write-Detail "success"  $NoteResult.success
                if ($NoteResult.success -eq $true) {
                    Write-Pass "Note created successfully in FieldRoutes!"
                    if ($NoteResult.PSObject.Properties.Name -contains 'noteID') {
                        Write-Detail "noteID"  $NoteResult.noteID
                    }
                } else {
                    Write-Fail "API returned success: false for note creation."
                    if ($NoteResult.PSObject.Properties.Name -contains 'errorMessage') {
                        Write-Detail "errorMessage" $NoteResult.errorMessage
                    }
                }
            } else {
                Write-Info "Raw response: $($NoteResponse.Content.Substring(0, [Math]::Min(300, $NoteResponse.Content.Length)))"
            }

        } catch [System.Net.WebException] {
            $StatusCode = [int]$_.Exception.Response.StatusCode
            Write-Fail "Note creation request failed with HTTP status: $StatusCode"
            Write-Detail "Error"  $_.Exception.Message
            if ($StatusCode -eq 404) {
                Write-Info "404 — The /api/note/create endpoint may not exist or may have a different path."
                Write-Info "Contact FieldRoutes support to confirm the correct note creation endpoint."
                Write-Info "If this endpoint is unavailable, remove the ReportCall scenario from the XML template."
            }
        } catch {
            Write-Fail "Unexpected error during ReportCall request."
            Write-Detail "Error"  $_.Exception.Message
        }
    }
} else {
    Write-Host ""
    Write-Info "ReportCall test skipped. Re-run with -TestReportCall to test note creation."
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "SUMMARY"

if ($LookupSuccess) {
    Write-Pass "Lookup scenario PASSED — FieldRoutes API is reachable and returned customer data."
    Write-Pass "Your credentials and company subdomain are correct."
    Write-Info "Next steps:"
    Write-Info "  1. Import FieldRoutesCRMfor3CX.xml into 3CX Admin Console > Settings > CRM Integration"
    Write-Info "  2. Enter your OfficeID, AuthKey, AuthToken, and CompanyName in the Configure screen"
    Write-Info "  3. Set 'Open Contact URL on:' to 'Answer'"
    Write-Info "  4. Use the Test button in 3CX to do a final verification"
} else {
    Write-Fail "Lookup scenario FAILED — review the errors above before importing into 3CX."
}

Write-Host ""