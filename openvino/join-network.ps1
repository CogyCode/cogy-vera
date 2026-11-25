<#
.SYNOPSIS
    Adds this PC to CogyServer's private network. Run it before install.ps1.

.DESCRIPTION
    Installs Tailscale if it is missing and joins CogyServer's network with a
    join key. Does nothing when the PC is already on the network, so it is safe
    to run again.

.PARAMETER LoginServer
    CogyServer's network control URL, e.g. http://<server-ip>:8780. Use an IP
    address: the Tailscale service runs as SYSTEM and may not resolve .local names.

.PARAMETER AuthKey
    Join key from CogyServer > Machines > Add a machine to the network.

.EXAMPLE
    .\join-network.ps1 -LoginServer http://<server-ip>:8780 -AuthKey <key>
#>
[CmdletBinding()]
param(
    [string]$LoginServer,
    [string]$AuthKey,
    # Internal: the key is handed to the elevated instance in a file so it
    # never appears on a command line or in the log.
    [string]$AuthKeyFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config\settings.psd1')
$LogDir = Join-Path $env:ProgramData "$($S.InstallDirName)\logs"
$log = Join-Path $LogDir 'join-network.log'

# Already on the network: nothing to do (no admin rights needed to check).
$ip = Get-PrivateIp
if ($ip -and -not $LoginServer) {
    Write-Host "This PC is already on CogyServer's private network: $ip"
    exit 0
}

if (-not (Test-Admin)) {
    Write-Host 'Administrator rights needed; relaunching elevated (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($LoginServer) { $argList += '-LoginServer', "`"$LoginServer`"" }
    if ($AuthKey) {
        $AuthKeyFile = Join-Path $env:TEMP "cogy-$([guid]::NewGuid()).key"
        Set-Content -Path $AuthKeyFile -Value $AuthKey -NoNewline -Encoding ascii
        $argList += '-AuthKeyFile', "`"$AuthKeyFile`""
    }
    try { $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru }
    finally { if ($AuthKeyFile) { Remove-Item $AuthKeyFile -Force -ErrorAction SilentlyContinue } }
    if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^(==>|    |JOIN)' } }
    exit $p.ExitCode
}

if ($AuthKeyFile) {
    $AuthKey = (Get-Content $AuthKeyFile -Raw).Trim()
    Remove-Item $AuthKeyFile -Force
}

New-Item -ItemType Directory -Force $LogDir | Out-Null
Start-Transcript -Path $log -Force | Out-Null
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }

try {
    $ts = Get-TailscaleExe
    Step 'Tailscale'
    if (Test-Path $ts) {
        Info 'Already installed'
    } else {
        $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
        Info "Installing from $($S.TailscaleMsiUrl)"
        Invoke-WebRequest -Uri $S.TailscaleMsiUrl -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Tailscale') {
            throw "Tailscale installer signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
        }
        $r = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
        Remove-Item $msi -Force
        if ($r.ExitCode -notin 0, 3010) { throw "Tailscale install failed (msiexec $($r.ExitCode))" }
        for ($i = 0; $i -lt 30 -and -not (Get-Service Tailscale -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    }

    Step "CogyServer's private network"
    $controlUrl = $null
    try { $controlUrl = (Native $ts debug prefs | Out-String | ConvertFrom-Json).ControlURL } catch {}
    $ip = Get-PrivateIp
    $sameServer = (-not $LoginServer) -or ($controlUrl -and $controlUrl.TrimEnd('/') -eq $LoginServer.TrimEnd('/'))
    if ($ip -and $sameServer) {
        Info "Already joined ($controlUrl)"
    } else {
        if (-not $LoginServer -or -not $AuthKey) {
            throw ("This PC is not on CogyServer's private network. Ask the owner for a join key " +
                   "(CogyServer > Machines > Add a machine to the network), then run:`n" +
                   "    .\join-network.ps1 -LoginServer http://<server-ip>:8780 -AuthKey <key>")
        }
        Info "Joining $LoginServer"
        $out = Native $ts up --login-server $LoginServer --authkey $AuthKey --unattended --reset --timeout 120s
        if ($LASTEXITCODE -ne 0) {
            throw ("tailscale up failed ($LASTEXITCODE): $($out -join ' ')`n" +
                   "Check that $LoginServer is reachable from this PC. Use the server's IP address: " +
                   "the Tailscale service runs as SYSTEM and may not resolve .local names.")
        }
        for ($i = 0; $i -lt 60 -and -not ($ip = Get-PrivateIp); $i++) { Start-Sleep 1 }
        if (-not $ip) { throw "Joined, but no private address was assigned" }
    }
    Info "Private address: $ip"
    Write-Host "`nJOINED: this PC is on CogyServer's private network at $ip" -ForegroundColor Green
    $exit = 0
}
catch {
    Write-Host "`nJOIN FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exit = 1
}
finally {
    Stop-Transcript | Out-Null
    # Never leave the join key in the log.
    if ($AuthKey -and (Test-Path $log)) {
        $text = [IO.File]::ReadAllText($log)
        if ($text.Contains($AuthKey)) { [IO.File]::WriteAllText($log, $text.Replace($AuthKey, '<join key>')) }
    }
}
exit $exit
