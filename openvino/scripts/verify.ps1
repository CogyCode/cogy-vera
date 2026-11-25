<#
.SYNOPSIS
    Checks that the installed server meets its requirements.

.DESCRIPTION
    - Service: running, automatic start after Tailscale, restart on failure
    - Network: listens on the private address only, never 0.0.0.0
    - Firewall: port allowed from CogyServer only
    - API: model listed, chat works, thinking off
    - Context: a ~31k-token prompt is served; a ~34k-token prompt is refused
    - Crash recovery (-TestRestart): kills OVMS and waits for the service to
      bring it back

    Needs administrator rights (asks through UAC). Output also goes to
    %ProgramData%\CogyVera\logs\verify.log.
#>
[CmdletBinding()]
param(
    [switch]$TestRestart,
    [switch]$SkipContext,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }
$log = Join-Path $InstallDir 'logs\verify.log'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights needed; relaunching elevated (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } } else { $argList += "-$k", "`"$v`"" }
    }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^(PASS|FAIL|INFO|  |Result)' } }
    exit $p.ExitCode
}

Start-Transcript -Path $log -Force | Out-Null
$failures = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host "PASS  $name  $detail" } else { Write-Host "FAIL  $name  $detail"; $script:failures++ }
}
function Native { $ErrorActionPreference = 'Continue'; $exe, $rest = $args; & $exe @rest 2>&1 | ForEach-Object { "$_" } }

try {
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    $ip = @(Native $ts ip -4 | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s*$' })
    $ip = if ($ip.Count) { $ip[0].Trim() } else { $null }
    Check 'Private address' ([bool]$ip) "$ip"
    $base = "http://$($ip):$($S.Port)"
    $Model = (Get-Content (Join-Path $InstallDir 'config.json') -Raw | ConvertFrom-Json).model_config_list[0].config.name

    # --- Services -------------------------------------------------------------
    foreach ($name in $S.OvmsServiceName, $S.ServiceName) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
        Check "$name running" ($svc -and $svc.State -eq 'Running') "$($svc.State)"
        $qc = (Native sc.exe qc $name) -join "`n"
        Check "$name starts at boot" ($qc -match 'AUTO_START') (($qc -split "`n" | Where-Object { $_ -match 'START_TYPE' }).Trim())
        $qf = (Native sc.exe qfailure $name) -join "`n"
        Check "$name restarts on failure" ($qf -match 'RESTART -- Delay = \d+') ((($qf -split "`n") | Where-Object { $_ -match 'RESTART' } | Select-Object -First 1).Trim())
    }
    $deps = @((Get-Service -Name $S.ServiceName).ServicesDependedOn | ForEach-Object Name)
    Check "$($S.ServiceName) starts after $($S.OvmsServiceName) and Tailscale" `
        ($deps -contains $S.OvmsServiceName -and $deps -contains 'Tailscale') ($deps -join ', ')
    $tsSvc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'"
    Check 'Tailscale starts at boot' ($tsSvc.StartMode -eq 'Auto') $tsSvc.StartMode

    # --- Network ---------------------------------------------------------------
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $S.Port -ErrorAction SilentlyContinue)
    $addrs = ($listen | ForEach-Object LocalAddress | Sort-Object -Unique) -join ', '
    Check "$($S.Name) listens on private address only" ($listen.Count -gt 0 -and -not ($listen | Where-Object LocalAddress -ne $ip)) $addrs
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $S.OvmsPort -ErrorAction SilentlyContinue)
    $addrs = ($listen | ForEach-Object LocalAddress | Sort-Object -Unique) -join ', '
    Check 'Model server listens on 127.0.0.1 only' ($listen.Count -gt 0 -and -not ($listen | Where-Object LocalAddress -ne '127.0.0.1')) $addrs

    # --- Firewall --------------------------------------------------------------
    $rules = @(Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
    # CogyServer's address is kept in the installed rule, not in the repository.
    $allow = $rules | Where-Object Action -eq 'Allow' | Where-Object {
        ($_ | Get-NetFirewallPortFilter).LocalPort -contains "$($S.Port)" }
    $allowFrom = @($allow | Get-NetFirewallAddressFilter | ForEach-Object RemoteAddress)
    Check 'Firewall allows one address only' ($allowFrom.Count -eq 1 -and $allowFrom[0] -match '^\d+\.\d+\.\d+\.\d+$') ($allowFrom -join ', ')
    $block = $rules | Where-Object Action -eq 'Block'
    $blockAddr = if ($block) { ($block | Get-NetFirewallAddressFilter).RemoteAddress -join ', ' } else { '' }
    Check 'Firewall blocks all other IPv4 sources' ([bool]$block -and $blockAddr -notmatch [regex]::Escape($allowFrom[0] + '-')) $blockAddr

    # --- API -------------------------------------------------------------------
    $health = try { Invoke-RestMethod "$base/health" -TimeoutSec 10 } catch { $null }
    Check 'GET /health' ($health.status -eq 'ready') "$($health.status)"
    $plan = "# Plan`n1. Delete old logs.`n## Diff`n+rm -rf /`$LOG_DIR/*"
    $v = Invoke-RestMethod "$base/verify" -Method Post -ContentType 'application/json' -Body (@{ plan = $plan } | ConvertTo-Json) -TimeoutSec 600
    Check 'POST /verify' ('approve', 'changes' -contains $v.verdict -and $null -ne $v.findings -and $v.summary) `
        "verdict $($v.verdict), $(@($v.findings).Count) findings, $($v.seconds) s"
    $bad = try { Invoke-WebRequest "$base/verify" -Method Post -ContentType 'application/json' -Body '{}' -UseBasicParsing; 200 } catch { [int]$_.Exception.Response.StatusCode }
    Check 'POST /verify without a plan is refused' ($bad -eq 400) "HTTP $bad"
    $models = Invoke-RestMethod "$base/v3/models" -TimeoutSec 10
    Check 'GET /v3/models' (($models.data | ForEach-Object id) -contains $Model) (($models.data | ForEach-Object id) -join ', ')
    function Chat($content, $maxTokens) {
        $body = @{ model = $Model; max_tokens = $maxTokens; temperature = 0
                   messages = @(@{ role = 'user'; content = $content }) } | ConvertTo-Json -Depth 5
        Invoke-WebRequest "$base/v3/chat/completions" -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 600
    }
    $r = (Chat 'Is 17 a prime number? Answer yes or no.' 200).Content | ConvertFrom-Json
    $ans = $r.choices[0].message.content
    Check 'POST /v3/chat/completions' ([bool]$ans) "'$($ans.Trim())'"
    Check 'Thinking off' ($ans -notmatch '<think>|</think>') ''

    # --- Parallel slots ---------------------------------------------------------
    # Two requests at once must be scheduled together, not one after the other.
    # OVMS logs "Scheduled requests: N" while it works, so read it from the log.
    $gen = {
        param($url, $model)
        $b = @{ model = $model; max_tokens = 300; ignore_eos = $true; temperature = 0
                messages = @(@{ role = 'user'; content = "Count upwards from $(Get-Random)." }) } | ConvertTo-Json -Depth 5
        $null = Invoke-RestMethod "$url/v3/chat/completions" -Method Post -ContentType 'application/json' -Body $b -TimeoutSec 600
        'done'
    }
    $ovmsLog = Join-Path $InstallDir 'logs\ovms.log'
    $logStart = (Get-Item $ovmsLog).Length
    $jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $gen -ArgumentList $base, $Model }
    $done = @($jobs | Wait-Job | Receive-Job -ErrorAction SilentlyContinue | Where-Object { $_ -eq 'done' }).Count
    $jobs | Remove-Job -Force
    $fs = [IO.File]::Open($ovmsLog, 'Open', 'Read', 'ReadWrite')
    $null = $fs.Seek($logStart, 'Begin')
    $newLog = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Dispose()
    $maxScheduled = ([regex]::Matches($newLog, 'Scheduled requests: (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } |
                     Measure-Object -Maximum).Maximum
    Check '2 requests in parallel' ($done -eq 2 -and $maxScheduled -ge 2) "$done of 2 completed; at most $maxScheduled scheduled together"

    # --- Context ---------------------------------------------------------------
    if (-not $SkipContext) {
        $words = 'plan step verify check order task resource budget risk owner deadline input output state goal'.Split(' ')
        function Text([int]$n) { $rng = New-Object Random; (1..$n | ForEach-Object { $words[$rng.Next($words.Length)] }) -join ' ' }
        $probe = (Chat (Text 2000) 1).Content | ConvertFrom-Json
        $perWord = $probe.usage.prompt_tokens / 2000
        $okWords = [int](($S.ContextLength - 1800) / $perWord)
        $r = (Chat (Text $okWords) 16).Content | ConvertFrom-Json
        Check "Serves a $($r.usage.prompt_tokens)-token prompt" ($r.usage.prompt_tokens -gt $S.ContextLength - 3000) ''
        $tooLong = [int](($S.ContextLength + 1500) / $perWord)
        $refused = $false; $msg = ''
        try { $null = Chat (Text $tooLong) 16 } catch { $refused = $true; $msg = $_.ErrorDetails.Message }
        Check "Refuses ~$([int]($tooLong * $perWord))-token prompt (limit $($S.ContextLength))" $refused $msg
    }

    # --- Crash recovery --------------------------------------------------------
    if ($TestRestart) {
        function Wait-Ready {
            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep 3
                try { if ((Invoke-RestMethod "$base/health" -TimeoutSec 3).status -eq 'ready') { return $true } } catch {}
            }
            $false
        }
        # Vera's code: kill python running vera.py.
        $py = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object CommandLine -match 'vera\.py' | Select-Object -First 1
        Stop-Process -Id $py.ProcessId -Force
        Write-Host "INFO  killed vera.py (pid $($py.ProcessId)); waiting for $($S.ServiceName) to restart it"
        $back = Wait-Ready
        $py2 = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object CommandLine -match 'vera\.py' | Select-Object -First 1
        Check "$($S.Name) restarts after a crash" ($back -and $py2 -and $py2.ProcessId -ne $py.ProcessId) "new pid $($py2.ProcessId)"

        # Model server: kill ovms.exe.
        $ovms = (Get-CimInstance Win32_Service -Filter "Name='$($S.OvmsServiceName)'").ProcessId
        Stop-Process -Id $ovms -Force
        Write-Host "INFO  killed ovms.exe (pid $ovms); waiting for $($S.OvmsServiceName) to restart it"
        $back = Wait-Ready
        $ovms2 = (Get-CimInstance Win32_Service -Filter "Name='$($S.OvmsServiceName)'").ProcessId
        Check 'Model server restarts after a crash' ($back -and $ovms2 -ne $ovms) "new pid $ovms2"
    }

    Write-Host "Result: $(if ($failures) { "$failures check(s) failed" } else { 'all checks passed' })"
}
catch {
    Write-Host "FAIL  error: $($_.Exception.Message)"
    $failures++
}
finally { Stop-Transcript | Out-Null }
exit [int]($failures -gt 0)
