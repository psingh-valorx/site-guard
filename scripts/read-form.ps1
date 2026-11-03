# Reads a Marketo form's public definition and prints its fields as JSON, so the fields
# rendered on dev can be compared with what Marketo expects. Read-only, no login needed.
param(
    [Parameter(Mandatory = $true)][string]$Munchkin,
    [Parameter(Mandatory = $true)][int]$FormId
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Done($obj) { $obj | ConvertTo-Json -Depth 5; exit 0 }

if ($Munchkin -notmatch '^\d{3}-[A-Z]{3}-\d{3}$') { Done ([pscustomobject]@{ ok = $false; error = 'Munchkin ID must look like 123-ABC-456.' }) }

try {
    $url = "https://$Munchkin.mktoweb.com/index.php/form/getForm?munchkinId=$Munchkin&form=$FormId&callback=cb"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $start = $text.IndexOf('(')
    $end = $text.LastIndexOf(')')
    if ($start -lt 0 -or $end -le $start) { Done ([pscustomobject]@{ ok = $false; error = 'Marketo returned no form definition.' }) }
    $form = $text.Substring($start + 1, $end - $start - 1) | ConvertFrom-Json
}
catch { Done ([pscustomobject]@{ ok = $false; error = $_.Exception.Message }) }

$fields = @()
foreach ($row in @($form.rows)) {
    foreach ($f in @($row)) {
        if (-not $f -or $f.Datatype -eq 'fieldset' -or $f.Datatype -eq 'htmltext') {
            foreach ($inner in @($f.fieldList)) {
                if ($inner -and $inner.Name) { $fields += [pscustomobject]@{ name = $inner.Name; type = $inner.Datatype; required = [bool]$inner.IsRequired; label = $inner.Label } }
            }
            continue
        }
        if ($f.Name) { $fields += [pscustomobject]@{ name = $f.Name; type = $f.Datatype; required = [bool]$f.IsRequired; label = $f.Label } }
    }
}

Done ([pscustomobject]@{
    ok          = $true
    form_id     = $FormId
    form_name   = $form.Name
    captcha     = [bool]$form.EnableCaptcha
    fields      = $fields
    required    = @($fields | Where-Object { $_.required } | ForEach-Object { $_.name })
    hidden      = @($fields | Where-Object { $_.type -eq 'hidden' } | ForEach-Object { $_.name })
})
