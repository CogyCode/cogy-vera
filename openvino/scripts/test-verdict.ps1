<#
.SYNOPSIS
    Tests the review verdict: format and judgement.

.DESCRIPTION
    Sends the test plan in testdata\plan-with-hashes.md to Vera's POST /verify.
    The plan has two real problems (rm -rf /$CACHE_DIR wipes / when the
    variable is empty; strcpy into a buffer of unknown size). Each run must:
      - return JSON matching the schema (analysis, findings, summary, verdict)
      - keep '#' characters intact
      - find both problems, with fixes that change the code (and no
        sizeof() of the pointer parameter for strcpy)
      - give verdict "changes", consistent with its findings
    Prints the time and the full JSON of the first run.
    Exit code 0 when every run passes.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [int]$Runs = 3
)

$ErrorActionPreference = 'Stop'
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\settings.psd1')
if (-not $BaseUrl) {
    $ip = @(& (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') ip -4)[0].Trim()
    $BaseUrl = "http://$($ip):$($S.Port)"
}
$schema = Get-Content (Join-Path $PSScriptRoot '..\config\verdict.schema.json') -Raw | ConvertFrom-Json
$plan = (Get-Content (Join-Path $PSScriptRoot 'testdata\plan-with-hashes.md') -Raw).Trim()
$body = @{ plan = $plan } | ConvertTo-Json
# Fields Vera adds to the verdict.
$meta = 'verdict_overridden', 'model', 'seconds', 'usage', 'attempts'

function Test-Verdict($v) {
    $errs = @()
    $want = @($schema.required)
    $names = @($v.PSObject.Properties.Name)
    foreach ($k in $want) { if ($names -notcontains $k) { $errs += "missing $k" } }
    foreach ($k in $names) { if ($want -notcontains $k -and $meta -notcontains $k) { $errs += "extra field $k" } }
    if ('approve', 'changes' -notcontains $v.verdict) { $errs += "bad verdict '$($v.verdict)'" }
    foreach ($f in @($v.findings)) {
        foreach ($k in 'file', 'line', 'problem', 'fix') { if (@($f.PSObject.Properties.Name) -notcontains $k) { $errs += "finding missing $k" } }
        if ($f.line -isnot [int] -and $f.line -isnot [long]) { $errs += "finding line not an integer" }
    }
    $findings = @($v.findings)
    if ($findings.Count -gt 0 -and $v.verdict -ne 'changes') { $errs += "verdict '$($v.verdict)' despite $($findings.Count) findings" }
    if ($v.verdict -ne 'changes') { $errs += "expected verdict 'changes'" }

    $rm = $findings | Where-Object { "$($_.problem)" -match 'rm -rf' } | Select-Object -First 1
    if (-not $rm) { $errs += 'missed rm -rf /$CACHE_DIR' }
    elseif ($rm.fix -notmatch ':\?|-z |-n |if ') { $errs += "rm -rf fix does not stop on an empty CACHE_DIR: $($rm.fix)" }

    $cp = $findings | Where-Object { "$($_.problem)" -match 'strcpy' } | Select-Object -First 1
    if (-not $cp) { $errs += 'missed strcpy overflow' }
    elseif ($cp.fix -match 'sizeof\s*\(\s*d\s*\)') { $errs += "strcpy fix uses sizeof(d) on a pointer: $($cp.fix)" }
    elseif ($cp.fix -match '^\s*strcpy\(d, s\);') { $errs += 'strcpy fix is unchanged' }
    elseif ($cp.fix -notmatch 'read_key\s*\([^)]*,[^)]*,' -and $cp.fix -cnotmatch '\b[A-Z][A-Z0-9_]{2,}\b') {
        $errs += "strcpy fix does not take the buffer size from the caller or a named constant: $($cp.fix)"
    }
    foreach ($f in $findings) { if ("$($f.fix)" -match '\\n') { $errs += "literal \n in fix for $($f.file)" } }

    if (($v | ConvertTo-Json -Depth 10) -notmatch '#') { $errs += "no '#' in the reply" }
    $errs
}

$failed = 0
foreach ($run in 1..$Runs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest "$BaseUrl/verify" -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 900
    } catch {
        Write-Host "FAIL  run $run`: POST /verify failed: $($_.ErrorDetails.Message) $($_.Exception.Message)"
        $failed++; continue
    }
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    # Decode the bytes as UTF-8 (Windows PowerShell may guess another charset).
    $v = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($run -eq 1) { Write-Host "Model: $($v.model)"; Write-Host ($v | ConvertTo-Json -Depth 10) }
    $errs = @(Test-Verdict $v)
    $tokens = $v.usage.completion_tokens
    $note = if ($v.verdict_overridden) { ', verdict overridden by Vera' } else { '' }
    if ($errs) {
        Write-Host "FAIL  run $run ($secs s, $tokens tokens): $($errs -join '; ')"; $failed++
    } else {
        Write-Host ("PASS  run {0} ({1} s, {2} tokens, attempts {3}): verdict {4}, {5} findings{6}" -f
            $run, $secs, $tokens, $v.attempts, $v.verdict, @($v.findings).Count, $note)
    }
}
Write-Host "Result: $(if ($failed) { "$failed of $Runs runs failed" } else { "all $Runs runs passed" })"
exit [int]($failed -gt 0)
