<#
.SYNOPSIS
    Measures the server's prompt processing and generation speed and GPU memory.

.DESCRIPTION
    Builds a prompt of about -PromptTokens tokens (calibrated against the
    server's own token count), then for each trial streams a completion of
    -GenTokens tokens:
      prompt processing tok/s = prompt tokens / time to first token
      generation tok/s        = (completion tokens - 1) / (last token - first token)
    Each trial starts with a fresh random prefix so prefix caching cannot
    skip the prompt. Then reads the server process's GPU memory from the
    Windows "GPU Process Memory" performance counters.

.PARAMETER BaseUrl
    Server URL. Default: this PC's private address and the configured port.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [int]$PromptTokens = 8000,
    [int]$GenTokens = 256,
    [int]$Trials = 3
)

$ErrorActionPreference = 'Stop'
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\settings.psd1')
if (-not $BaseUrl) {
    $ip = (& (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') ip -4 | Select-Object -First 1).Trim()
    $BaseUrl = "http://$($ip):$($S.Port)"
}
$Model = (Invoke-RestMethod "$BaseUrl/v3/models" -TimeoutSec 10).data[0].id
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(10)

$words = ('plan step verify check order task resource budget risk owner deadline input output ' +
          'state goal constraint result review assume depend fail retry safe cost time data ' +
          'server client queue cache limit rule test ensure valid error report').Split(' ')

function New-Prompt([int]$nWords) {
    $rng = New-Object Random
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("Run $([guid]::NewGuid()). Notes: ")
    for ($i = 0; $i -lt $nWords; $i++) {
        [void]$sb.Append($words[$rng.Next($words.Length)])
        [void]$sb.Append($(if ($i % 12 -eq 11) { '. ' } else { ' ' }))
    }
    [void]$sb.Append("`n`nWrite a long, detailed summary of the notes above.")
    $sb.ToString()
}

function Invoke-Chat([string]$prompt, [int]$maxTokens) {
    $body = @{
        model = $Model; stream = $true; max_tokens = $maxTokens; ignore_eos = $true; temperature = 0
        stream_options = @{ include_usage = $true }
        messages = @(@{ role = 'user'; content = $prompt })
    } | ConvertTo-Json -Depth 5
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$BaseUrl/v3/chat/completions")
    $req.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode): $($resp.Content.ReadAsStringAsync().Result)" }
    $reader = New-Object IO.StreamReader($resp.Content.ReadAsStreamAsync().Result)
    $first = $null; $last = $null; $usage = $null
    while ($null -ne ($line = $reader.ReadLine())) {
        if (-not $line.StartsWith('data: ') -or $line -eq 'data: [DONE]') { continue }
        $chunk = $line.Substring(6) | ConvertFrom-Json
        if ($chunk.choices -and $chunk.choices[0].delta.content) {
            $t = $sw.Elapsed.TotalSeconds
            if ($null -eq $first) { $first = $t }
            $last = $t
        }
        if ($chunk.usage) { $usage = $chunk.usage }
    }
    $reader.Dispose(); $resp.Dispose()
    [pscustomobject]@{ First = $first; Last = $last; Usage = $usage }
}

Write-Host "Server: $BaseUrl   Model: $($Model)"

# Calibrate the prompt length on the server's tokenizer.
$nWords = [int]($PromptTokens / 1.3)
for ($i = 0; $i -lt 4; $i++) {
    $n = (Invoke-Chat (New-Prompt $nWords) 1).Usage.prompt_tokens
    if ([math]::Abs($n - $PromptTokens) -le $PromptTokens * 0.005) { break }
    $nWords = [int]($nWords * $PromptTokens / $n)
}

$results = foreach ($t in 1..$Trials) {
    $r = Invoke-Chat (New-Prompt $nWords) $GenTokens
    $p = $r.Usage.prompt_tokens; $c = $r.Usage.completion_tokens
    $o = [pscustomobject]@{
        Trial = $t; PromptTokens = $p; CompletionTokens = $c
        TTFT_s = [math]::Round($r.First, 2)
        PromptTokPerS = [math]::Round($p / $r.First, 1)
        GenTokPerS = [math]::Round(($c - 1) / ($r.Last - $r.First), 1)
    }
    Write-Host ("  trial {0}: prompt {1} tok, TTFT {2} s -> {3} tok/s prompt; {4} tok generated at {5} tok/s" -f
        $t, $p, $o.TTFT_s, $o.PromptTokPerS, $c, $o.GenTokPerS)
    $o
}
function Median($xs) { $s = @($xs | Sort-Object); $s[[int][math]::Floor($s.Count / 2)] }

# Two requests at once: short prompts, $GenTokens each.
function New-Body { @{ model = $Model; max_tokens = $GenTokens; ignore_eos = $true; temperature = 0
    messages = @(@{ role = 'user'; content = "Run $([guid]::NewGuid()). Count upwards from 1." }) } | ConvertTo-Json -Depth 5 }
$sw = [Diagnostics.Stopwatch]::StartNew()
$tasks = 1..2 | ForEach-Object {
    $http.PostAsync("$BaseUrl/v3/chat/completions", (New-Object System.Net.Http.StringContent((New-Body), [Text.Encoding]::UTF8, 'application/json')))
}
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$wall = $sw.Elapsed.TotalSeconds
$parTokens = ($tasks | ForEach-Object { ($_.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json).usage.completion_tokens } | Measure-Object -Sum).Sum
$parallel = [pscustomobject]@{ Wall = [math]::Round($wall, 1); PerRequest = [math]::Round($parTokens / 2 / $wall, 1); Total = [math]::Round($parTokens / $wall, 1) }
Write-Host ("  2 at once: {0} tokens in {1} s -> {2} tok/s each, {3} tok/s total" -f $parTokens, $parallel.Wall, $parallel.PerRequest, $parallel.Total)

$svcPid = (Get-CimInstance Win32_Service -Filter "Name='$($S.ServiceName)'").ProcessId
$mem = $null
if ($svcPid) {
    $ctr = Get-Counter "\GPU Process Memory(pid_$($svcPid)_*)\Dedicated Usage", "\GPU Process Memory(pid_$($svcPid)_*)\Shared Usage" -ErrorAction SilentlyContinue
    if ($ctr) {
        $ded = ($ctr.CounterSamples | Where-Object Path -like '*dedicated usage' | Measure-Object CookedValue -Sum).Sum
        $shr = ($ctr.CounterSamples | Where-Object Path -like '*shared usage' | Measure-Object CookedValue -Sum).Sum
        $mem = [pscustomobject]@{ DedicatedGB = [math]::Round($ded / 1GB, 2); SharedGB = [math]::Round($shr / 1GB, 2) }
    }
}

Write-Host ''
Write-Host ('Prompt processing: {0} tok/s (median, {1}-token prompt)' -f (Median $results.PromptTokPerS), (Median $results.PromptTokens))
Write-Host ('Generation:        {0} tok/s (median, {1} tokens)' -f (Median $results.GenTokPerS), $GenTokens)
Write-Host ('2 requests at once: {0} tok/s each, {1} tok/s total' -f $parallel.PerRequest, $parallel.Total)
if ($mem) {
    Write-Host ('GPU memory (service process): {0} GB shared + {1} GB dedicated = {2} GB' -f
        $mem.SharedGB, $mem.DedicatedGB, ($mem.SharedGB + $mem.DedicatedGB))
} else {
    Write-Host 'GPU memory: counters unavailable (run elevated, service must be running)'
}
