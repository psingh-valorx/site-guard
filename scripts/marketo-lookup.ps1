# Read-only Marketo lookup for the Site Guard test address. Prints JSON.
# It only sends GET requests, plus the token request, and refuses any address but the configured one.
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [string]$Since = (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'),
    [string]$Fields = 'id,email,firstName,lastName,company,createdAt,updatedAt,sfdcType,sfdcLeadId,sfdcContactId,sfdcAccountId',
    [Parameter(Mandatory = $true)][string]$AllowedEmail,
    [string]$EnvPath = (Join-Path $env:USERPROFILE '.site-guard\.env')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Out-Result($obj) { $obj | ConvertTo-Json -Depth 8; exit 0 }
function Fail($msg) { Out-Result ([pscustomobject]@{ ok = $false; error = $msg }) }

if ($Email -ne $AllowedEmail) { Fail "Refused: this script only looks up the configured test address." }
if (-not (Test-Path $EnvPath)) { Fail "No .env file at $EnvPath." }

$cfg = @{}
foreach ($line in Get-Content $EnvPath) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'") }
}
foreach ($k in 'MARKETO_BASE_URL', 'MARKETO_CLIENT_ID', 'MARKETO_CLIENT_SECRET') {
    if (-not $cfg[$k]) { Fail "$k is missing from the .env file." }
}
$base = $cfg['MARKETO_BASE_URL'].TrimEnd('/') -replace '/rest$', '' -replace '/identity$', ''

function Invoke-Marketo($path, $headers) {
    $r = Invoke-RestMethod -Method Get -Uri ($base + $path) -Headers $headers -TimeoutSec 30
    if (-not $r.success) {
        $e = @($r.errors)[0]
        throw "Marketo error $($e.code): $($e.message)"
    }
    return $r
}

try {
    $body = @{ grant_type = 'client_credentials'; client_id = $cfg['MARKETO_CLIENT_ID']; client_secret = $cfg['MARKETO_CLIENT_SECRET'] }
    $tok = Invoke-RestMethod -Method Post -Uri "$base/identity/oauth/token" -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30
    if (-not $tok.access_token) { Fail 'Could not get a Marketo access token. Check the .env values.' }
    $h = @{ Authorization = "Bearer $($tok.access_token)" }

    $q = [uri]::EscapeDataString($Email)
    $leads = @((Invoke-Marketo "/rest/v1/leads.json?filterType=email&filterValues=$q&fields=$Fields" $h).result)
    if ($leads.Count -eq 0) {
        Out-Result ([pscustomobject]@{ ok = $true; checked_at = (Get-Date).ToUniversalTime().ToString('o'); email = $Email; lead_exists = $false; leads = @(); form_fills = @() })
    }

    $sinceQ = [uri]::EscapeDataString($Since)
    $page = (Invoke-Marketo "/rest/v1/activities/pagingtoken.json?sinceDatetime=$sinceQ" $h).nextPageToken
    $ids = ($leads | ForEach-Object { $_.id }) -join ','
    $fills = @()
    for ($i = 0; $i -lt 10; $i++) {
        $p = [uri]::EscapeDataString($page)
        $a = Invoke-Marketo "/rest/v1/activities.json?activityTypeIds=2&leadIds=$ids&nextPageToken=$p" $h
        foreach ($act in @($a.result)) {
            if (-not $act) { continue }
            $attrs = @{}
            foreach ($at in @($act.attributes)) {
                if ($at.name -notmatch 'IP Address') { $attrs[$at.name] = $at.value }
            }
            $fills += [pscustomobject]@{ activity_date = $act.activityDate; lead_id = $act.leadId; form = $act.primaryAttributeValue; form_id = $act.primaryAttributeValueId; attributes = $attrs }
        }
        if (-not $a.moreResult) { break }
        $page = $a.nextPageToken
    }
    Out-Result ([pscustomobject]@{ ok = $true; checked_at = (Get-Date).ToUniversalTime().ToString('o'); email = $Email; lead_exists = $true; leads = $leads; form_fills = $fills })
}
catch {
    # The exception text can contain a request URL but never the secret, which only travels in the POST body.
    Fail $_.Exception.Message
}
