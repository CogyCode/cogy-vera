<#
.SYNOPSIS
    Removes the model server installed by install.ps1.

.DESCRIPTION
    Always removes the Windows services (Vera's code and the model server)
    and the firewall rules.
    Files (OVMS, model, logs) are kept unless -RemoveFiles is given, so a
    re-install does not download the model again.
    The PC stays on CogyServer's private network (join-network.ps1 is a
    separate step); run "tailscale logout" to leave it.

.PARAMETER RemoveFiles
    Also delete the install directory (OVMS, model, cache, logs).

.PARAMETER InstallDir
    Install directory used by install.ps1. Default %ProgramData%\<InstallDirName>.
#>
[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }

if (-not (Test-Admin)) {
    Write-Host 'Administrator rights needed; relaunching elevated (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($RemoveFiles) { $argList += '-RemoveFiles' }
    if ($InstallDir) { $argList += '-InstallDir', "`"$InstallDir`"" }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

foreach ($name in $S.ServiceName, $S.OvmsServiceName) {
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
        Write-Host "Removing service $name"
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $name | Out-Null
        for ($i = 0; $i -lt 30 -and (Get-Service -Name $name -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    }
}

$rules = Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue
if ($rules) {
    Write-Host "Removing firewall rules ($($S.FirewallGroup))"
    $rules | Remove-NetFirewallRule
}

if ($RemoveFiles -and (Test-Path $InstallDir)) {
    Write-Host "Deleting $InstallDir"
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host "$($S.Name) uninstalled." -ForegroundColor Green
