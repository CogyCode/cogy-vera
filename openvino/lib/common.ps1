# Helpers shared by join-network.ps1, install.ps1 and the scripts. Dot-source it.

# Run a native program. Windows PowerShell 5.1 turns native stderr into a
# terminating error under ErrorActionPreference=Stop, so relax it here and
# let callers check $LASTEXITCODE. Output comes back as strings.
function Native {
    $ErrorActionPreference = 'Continue'
    $exe = $args[0]
    # Always an array: a single leftover argument would otherwise not be passed.
    $rest = @($args | Select-Object -Skip 1)
    & $exe @rest 2>&1 | ForEach-Object { "$_" }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-UInt32([string]$ip) {
    $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0)
}

function ConvertFrom-UInt32([uint32]$n) {
    $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b); ([Net.IPAddress]$b).ToString()
}

function Get-TailscaleExe { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }

# This PC's address on CogyServer's private network, or $null when not joined.
function Get-PrivateIp {
    $ts = Get-TailscaleExe
    if (-not (Test-Path $ts)) { return $null }
    $ip = @(Native $ts ip -4 | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s*$' })
    if ($ip.Count) { $ip[0].Trim() } else { $null }
}
