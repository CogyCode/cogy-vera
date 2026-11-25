<#
.SYNOPSIS
    Installs the model server: an OpenVINO model on OpenVINO Model Server,
    served on this PC's private CogyServer address, started at boot and
    restarted on a crash. Project name, port and model: config\settings.psd1.

.DESCRIPTION
    Run join-network.ps1 first: this PC must be on CogyServer's private network.
    Safe to re-run; each step is skipped when already done.
      1. OpenVINO Model Server (pinned version, SHA-256 checked)
      2. Model download (ModelId in config\settings.psd1, from Hugging Face)
      3. OVMS config + graph, thinking off by default, context from settings
      4. Check: this PC is on CogyServer's private network
      5. Windows Firewall: the API port is reachable only from CogyServer
      6. Python (embeddable) and Vera's code (veraera.py)
      7. Windows services: the model server on 127.0.0.1, Vera's code on the
         private address; automatic start, restart on failure
      8. Self-test: /health, POST /verify, OpenAI passthrough

.PARAMETER InstallDir
    Where OVMS, the model, config and logs go. Default %ProgramData%\<InstallDirName>.

.PARAMETER ModelId
    OpenVINO model on Hugging Face. Default: ModelId in config\settings.psd1.

.PARAMETER AllowFrom
    CogyServer's private address, the only one admitted to the API port. A re-run
    can leave it out and keeps the address in the installed firewall rule.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$ModelId,
    [string]$AllowFrom
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoDir = $PSScriptRoot
. (Join-Path $RepoDir 'lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $RepoDir 'config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }

# CogyServer's address is not kept in the repository.
if (-not $AllowFrom) {
    $AllowFrom = @(Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue |
        Where-Object Action -eq 'Allow' | Get-NetFirewallAddressFilter | ForEach-Object RemoteAddress) | Select-Object -First 1
}
$parsedAllowFrom = $null
if (-not $AllowFrom -or -not [Net.IPAddress]::TryParse($AllowFrom, [ref]$parsedAllowFrom)) {
    Write-Host "CogyServer's address is required:`n    .\install.ps1 -AllowFrom <cogyserver-address>" -ForegroundColor Red
    exit 1
}

# The private network is a separate step that may already be done.
if (-not (Get-PrivateIp)) {
    Write-Host ("This PC is not on CogyServer's private network. Run join-network.ps1 first:`n" +
                "    .\join-network.ps1 -LoginServer http://<server-ip>:8780 -AuthKey <key>") -ForegroundColor Red
    exit 1
}

# --- Elevation -------------------------------------------------------------
if (-not (Test-Admin)) {
    Write-Host 'Administrator rights needed; relaunching elevated (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) { $argList += "-$k", "`"$($PSBoundParameters[$k])`"" }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    $log = Join-Path $InstallDir 'logs\install.log'
    if (Test-Path $log) { Get-Content $log -Tail 40 }
    exit $p.ExitCode
}

$OvmsDir    = Join-Path $InstallDir 'ovms'
$OvmsExe    = Join-Path $OvmsDir 'ovms.exe'
$ModelsDir  = Join-Path $InstallDir 'models'
if (-not $ModelId) { $ModelId = $S.ModelId }
$ModelDir   = Join-Path $ModelsDir ($ModelId -replace '/', '\')
$CacheDir   = Join-Path $InstallDir 'cache'
$LogDir     = Join-Path $InstallDir 'logs'
$ConfigPath = Join-Path $InstallDir 'config.json'

# Install directory, locked down because the service runs as SYSTEM:
# SYSTEM and Administrators full control, Users read and execute only.
foreach ($d in $InstallDir, $ModelsDir, $CacheDir, $LogDir) { New-Item -ItemType Directory -Force $d | Out-Null }
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed ($LASTEXITCODE)" }
& icacls.exe "$InstallDir\*" /reset /T /C /Q | Out-Null

Start-Transcript -Path (Join-Path $LogDir 'install.log') -Force | Out-Null

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }

try {
    Step "Install directory $InstallDir"

    # Stop a running instance before replacing anything it uses.
    foreach ($name in $S.ServiceName, $S.OvmsServiceName) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Info "Stopping service $name"
            Stop-Service -Name $name -Force
        }
    }

    # --- 1. OpenVINO Model Server ------------------------------------------
    Step "OpenVINO Model Server $($S.OvmsVersion)"
    $versionFile = Join-Path $OvmsDir 'ovms-version.txt'
    if ((Test-Path $OvmsExe) -and (Test-Path $versionFile) -and ((Get-Content $versionFile -Raw).Trim() -eq $S.OvmsVersion)) {
        Info 'Already installed'
    } else {
        $dl = Join-Path $InstallDir 'download'
        New-Item -ItemType Directory -Force $dl | Out-Null
        $zip = Join-Path $dl $S.OvmsZip
        $url = "https://github.com/openvinotoolkit/model_server/releases/download/v$($S.OvmsVersion)/$($S.OvmsZip)"
        Info "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($hash -ne $S.OvmsSha256) { throw "SHA-256 mismatch for $($S.OvmsZip): got $hash" }
        Info 'SHA-256 OK'
        if (Test-Path $OvmsDir) { Remove-Item -Recurse -Force $OvmsDir }
        Expand-Archive -Path $zip -DestinationPath $dl -Force
        Move-Item (Join-Path $dl 'ovms') $OvmsDir
        Set-Content -Path $versionFile -Value $S.OvmsVersion -Encoding ascii
        Remove-Item -Recurse -Force $dl
    }

    # --- 2. Model ------------------------------------------------------------
    # Downloads a model from Hugging Face with ovms --pull unless complete.
    # Complete = weight files present, none still a Git LFS pointer, and no
    # download in progress.
    function Get-Model([string]$id) {
        $dir = Join-Path $ModelsDir ($id -replace '/', '\')
        $complete = {
            $bins = @(Get-ChildItem $dir -Filter 'openvino_*.bin' -ErrorAction SilentlyContinue)
            $pointers = @($bins | Where-Object { $_.Length -lt 1KB -and (Get-Content $_.FullName -TotalCount 1) -match '^version https://git-lfs' })
            ($bins | Measure-Object Length -Sum).Sum -gt 50MB -and $pointers.Count -eq 0 -and
                -not (Test-Path "$dir.lfswip") -and -not (Get-ChildItem $dir -Filter '*lfs_part' -ErrorAction SilentlyContinue)
        }
        if (& $complete) {
            Info 'Already downloaded'
        } else {
            if (Test-Path $dir) {
                Info 'Removing incomplete download'
                Remove-Item -Recurse -Force $dir
            }
            Remove-Item -Force "$dir.lfswip" -ErrorAction SilentlyContinue
            Info 'Downloading from Hugging Face (this can take a while)...'
            Native $OvmsExe --pull --source_model $id --model_repository_path $ModelsDir --task text_generation |
                Where-Object { $_ -match 'error|fail|download|finished' } | ForEach-Object { Info $_ }
            if (-not (& $complete)) { throw "Download of $id failed (ovms exit $LASTEXITCODE)" }
        }
        $sizeGB = (Get-ChildItem $dir -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
                   Measure-Object Length -Sum).Sum / 1GB
        Info ('On disk: {0:N2} GB' -f $sizeGB)
        $dir
    }

    Step "Model $ModelId"
    $null = Get-Model $ModelId

    # Only the configured model is kept; others are removed to free disk.
    $keep = @(Join-Path $ModelsDir ($ModelId -replace '/', '\'))
    foreach ($org in Get-ChildItem $ModelsDir -Directory) {
        foreach ($m in Get-ChildItem $org.FullName -Directory) {
            if ($keep -notcontains $m.FullName) {
                Info "Removing unused model $($org.Name)/$($m.Name)"
                Remove-Item -Recurse -Force $m.FullName
            }
        }
        Get-ChildItem $org.FullName -Filter '*.lfswip' | Where-Object { $keep -notcontains ($_.FullName -replace '\.lfswip$', '') } | Remove-Item -Force
        if (-not (Get-ChildItem $org.FullName)) { Remove-Item -Force $org.FullName }
    }

    # --- 3. Config -----------------------------------------------------------
    Step 'OVMS configuration'
    $json = (Get-Content (Join-Path $RepoDir 'config\config.json') -Raw).Replace('@MODEL_ID@', $ModelId)
    [IO.File]::WriteAllText($ConfigPath, $json)
    Copy-Item (Join-Path $RepoDir 'config\graph.pbtxt') (Join-Path $ModelDir 'graph.pbtxt') -Force
    Info 'config.json and graph.pbtxt installed'

    # Context limit: OVMS caps prompt + output at max_position_embeddings.
    $cfgFile = Join-Path $ModelDir 'config.json'
    $cfgText = Get-Content $cfgFile -Raw
    $cfgNew = [regex]::Replace($cfgText, '"max_position_embeddings"\s*:\s*\d+', "`"max_position_embeddings`": $($S.ContextLength)")
    if ($cfgNew -ne $cfgText) { [IO.File]::WriteAllText($cfgFile, $cfgNew) }
    Info "Context length $($S.ContextLength)"

    # Thinking off: default enable_thinking to false in the chat template.
    # A request can still pass chat_template_kwargs {"enable_thinking": true}.
    $marker = '{#- cogy: thinking off by default #}'
    $prefix = $marker + '{%- if enable_thinking is not defined %}{%- set enable_thinking = false %}{%- endif %}'
    $tpl = Join-Path $ModelDir 'chat_template.jinja'
    if (Test-Path $tpl) {
        $t = [IO.File]::ReadAllText($tpl)
        if (-not $t.Contains('set enable_thinking = false %}{%- endif %}')) { [IO.File]::WriteAllText($tpl, $prefix + $t) }
    }
    $tc = Join-Path $ModelDir 'tokenizer_config.json'
    if (Test-Path $tc) {
        $j = Get-Content $tc -Raw | ConvertFrom-Json
        if ($j.chat_template -and -not $j.chat_template.Contains('set enable_thinking = false %}{%- endif %}')) {
            $j.chat_template = $prefix + $j.chat_template
            [IO.File]::WriteAllText($tc, ($j | ConvertTo-Json -Depth 20))
        }
    }
    Info 'Thinking off by default'

    # --- 4. Private network --------------------------------------------------
    Step "CogyServer's private network"
    $PrivateIp = Get-PrivateIp
    if (-not $PrivateIp) { throw 'This PC is not on the private network; run join-network.ps1 first' }
    Info "Private address: $PrivateIp"

    # --- 5. Firewall ---------------------------------------------------------
    Step "Firewall: port $($S.Port) from $AllowFrom only"
    Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Group $S.FirewallGroup -DisplayName "$($S.FirewallGroup) API (allow CogyServer)" `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $S.Port -RemoteAddress $AllowFrom -Profile Any | Out-Null
    # Block every other IPv4 source. Block rules win over any allow rule,
    # including program rules Windows may have created for ovms.exe.
    # (OVMS listens on the private IPv4 address only, so IPv6 cannot reach it.)
    $a = ConvertTo-UInt32 $AllowFrom
    $others = @()
    if ($a -gt 1) { $others += '0.0.0.1-' + (ConvertFrom-UInt32 ($a - 1)) }
    if ($a -lt [uint32]::MaxValue - 1) { $others += (ConvertFrom-UInt32 ($a + 1)) + '-255.255.255.254' }
    New-NetFirewallRule -Group $S.FirewallGroup -DisplayName "$($S.FirewallGroup) API (block all others)" `
        -Direction Inbound -Action Block -Protocol TCP -LocalPort $S.Port -RemoteAddress $others -Profile Any | Out-Null
    Info 'Rules installed'

    # --- 6. Python and Vera's code --------------------------------------------
    # Downloads $url to $out unless it is already there with the right SHA-256.
    function Get-Verified([string]$url, [string]$sha256, [string]$out) {
        if ((Test-Path $out) -and (Get-FileHash $out -Algorithm SHA256).Hash -eq $sha256) { return }
        Info "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        $hash = (Get-FileHash $out -Algorithm SHA256).Hash
        if ($hash -ne $sha256) { Remove-Item $out -Force; throw "SHA-256 mismatch for $($url): got $hash" }
    }

    Step "Python $($S.PythonVersion) (embeddable, standard library only)"
    $PythonDir = Join-Path $InstallDir 'python'
    $PythonExe = Join-Path $PythonDir 'python.exe'
    $pyVersionFile = Join-Path $PythonDir 'python-version.txt'
    if ((Test-Path $PythonExe) -and (Test-Path $pyVersionFile) -and ((Get-Content $pyVersionFile -Raw).Trim() -eq $S.PythonVersion)) {
        Info 'Already installed'
    } else {
        $zip = Join-Path $env:TEMP "python-$($S.PythonVersion)-embed.zip"
        Get-Verified $S.PythonZipUrl $S.PythonSha256 $zip
        Info 'SHA-256 OK'
        if (Test-Path $PythonDir) { Remove-Item -Recurse -Force $PythonDir }
        Expand-Archive -Path $zip -DestinationPath $PythonDir -Force
        Remove-Item $zip -Force
        Set-Content -Path $pyVersionFile -Value $S.PythonVersion -Encoding ascii
    }
    Info (Native $PythonExe --version)

    Step "$($S.Name) code"
    $VeraDir = Join-Path $InstallDir 'vera'
    New-Item -ItemType Directory -Force $VeraDir | Out-Null
    Copy-Item (Join-Path $RepoDir 'vera\vera.py') $VeraDir -Force
    Copy-Item (Join-Path $RepoDir 'config\review-prompt.txt') $VeraDir -Force
    Copy-Item (Join-Path $RepoDir 'config\verdict.schema.json') $VeraDir -Force
    $VeraConfig = Join-Path $VeraDir 'vera.json'
    $veraCfg = [ordered]@{
        bind        = $PrivateIp
        port        = $S.Port
        upstream    = "http://127.0.0.1:$($S.OvmsPort)"
        model       = $ModelId
        prompt_file = Join-Path $VeraDir 'review-prompt.txt'
        schema_file = Join-Path $VeraDir 'verdict.schema.json'
        max_tokens  = $S.MaxTokens
        retries     = 1
        timeout     = 900
        log_file    = Join-Path $LogDir 'vera.log'
    }
    [IO.File]::WriteAllText($VeraConfig, ($veraCfg | ConvertTo-Json))
    Info "Installed to $VeraDir"

    # --- 7. Services -----------------------------------------------------------
    function Remove-ServiceIfPresent([string]$name) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { return }
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        & sc.exe delete $name | Out-Null
        for ($i = 0; $i -lt 30 -and (Get-Service -Name $name -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    }
    Remove-ServiceIfPresent $S.ServiceName
    Remove-ServiceIfPresent $S.OvmsServiceName

    # Model server: localhost only; Vera's code is the only client.
    Step "Windows service $($S.OvmsServiceName) (model server, 127.0.0.1:$($S.OvmsPort))"
    $bin = "`"$OvmsExe`" --config_path `"$ConfigPath`" --rest_port $($S.OvmsPort) --rest_bind_address 127.0.0.1 " +
           "--port 0 --cache_dir `"$CacheDir`" --log_level INFO --log_path `"$(Join-Path $LogDir 'ovms.log')`""
    New-Service -Name $S.OvmsServiceName -DisplayName $S.OvmsDisplayName -BinaryPathName $bin -StartupType Automatic `
        -Description "Model server for $($S.Name): $ModelId on http://127.0.0.1:$($S.OvmsPort)" | Out-Null
    # Restart 10 s after any failure, failure count reset daily.
    & sc.exe failure $S.OvmsServiceName reset= 86400 actions= restart/10000/restart/10000/restart/30000 | Out-Null
    & sc.exe failureflag $S.OvmsServiceName 1 | Out-Null
    Start-Service -Name $S.OvmsServiceName
    Info 'Started'

    # Vera's code, run by WinSW: delayed start after the model server and
    # Tailscale (it binds to the private address), restart on failure.
    Step "Windows service $($S.ServiceName) ($($S.Name), http://$($PrivateIp):$($S.Port))"
    $SvcDir = Join-Path $InstallDir 'service'
    New-Item -ItemType Directory -Force $SvcDir | Out-Null
    $wrapper = Join-Path $SvcDir "$($S.ServiceName).exe"
    Get-Verified $S.WinSWUrl $S.WinSWSha256 $wrapper
    $xml = (Get-Content (Join-Path $RepoDir 'config\service.xml') -Raw).
        Replace('@SERVICE_NAME@', $S.ServiceName).
        Replace('@DISPLAY_NAME@', $S.ServiceDisplayName).
        Replace('@DESCRIPTION@', "$($S.Name) ($($S.Role)) on http://$($PrivateIp):$($S.Port)").
        Replace('@PYTHON@', $PythonExe).
        Replace('@VERA_PY@', (Join-Path $VeraDir 'vera.py')).
        Replace('@VERA_CONFIG@', $VeraConfig).
        Replace('@VERA_DIR@', $VeraDir).
        Replace('@OVMS_SERVICE@', $S.OvmsServiceName).
        Replace('@LOG_DIR@', $LogDir)
    [IO.File]::WriteAllText((Join-Path $SvcDir "$($S.ServiceName).xml"), $xml)
    $out = Native $wrapper install
    if ($LASTEXITCODE -ne 0) { throw "WinSW install failed ($LASTEXITCODE): $($out -join ' ')" }
    & sc.exe failure $S.ServiceName reset= 86400 actions= restart/10000/restart/10000/restart/30000 | Out-Null
    & sc.exe failureflag $S.ServiceName 1 | Out-Null
    Start-Service -Name $S.ServiceName
    Info 'Started'

    # --- 8. Self-test --------------------------------------------------------
    Step 'Self-test'
    $base = "http://$($PrivateIp):$($S.Port)"
    $deadline = (Get-Date).AddMinutes(15)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) {
        Start-Sleep 5
        try { $ready = (Invoke-RestMethod "$base/health" -TimeoutSec 5).status -eq 'ready' } catch {}
    }
    if (-not $ready) { throw "$($S.Name) not ready within 15 minutes; see $LogDir (vera.log, ovms.log)" }
    Info 'Model loaded, /health ready'

    $plan = "# Plan`n1. Add a README.md with the project name.`n## Diff`n--- /dev/null`n+++ b/README.md`n@@ -0,0 +1 @@`n+# Demo"
    $r = Invoke-RestMethod "$base/verify" -Method Post -ContentType 'application/json' `
        -Body (@{ plan = $plan } | ConvertTo-Json) -TimeoutSec 600
    if ('approve', 'changes' -notcontains $r.verdict) { throw "POST /verify gave no verdict: $($r | ConvertTo-Json -Depth 5)" }
    Info "POST /verify: $($r.verdict), $(@($r.findings).Count) findings, $($r.seconds) s"

    $body = @{ model = $ModelId; max_tokens = 64; temperature = 0
               messages = @(@{ role = 'user'; content = 'Reply with exactly: OK' }) } | ConvertTo-Json -Depth 5
    $c = Invoke-RestMethod "$base/v3/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
    $answer = $c.choices[0].message.content
    if ($answer -match '<think>|</think>') { throw "Thinking is still on; reply was: $answer" }
    Info "Chat passthrough OK, no thinking: '$($answer.Trim())'"

    Write-Host ''
    Write-Host "$($S.Name) is installed." -ForegroundColor Green
    Write-Host "  Verify: POST $base/verify   {`"plan`": `"...`", `"diff`": `"...`"}"
    Write-Host "  Health: GET  $base/health"
    Write-Host "  OpenAI: POST $base/v3/chat/completions, GET $base/v3/models"
    Write-Host "  Model:  $ModelId  (context $($S.ContextLength))"
    Write-Host "  Logs:   $LogDir"
    $exit = 0
}
catch {
    Write-Host "`nINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exit = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $exit
