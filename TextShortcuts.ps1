<#
.SYNOPSIS
    A self-contained, system-wide text-expansion tool (no extra software required).

.DESCRIPTION
    Installs a low-level keyboard hook and watches what you type. There is NO trigger
    character: the instant you finish typing a defined abbreviation, it is deleted and
    replaced with the full expansion -- in ANY application.

    Shortcuts live in shortcuts.json next to this script. EDIT THAT FILE ANY TIME and
    save it -- this tool reloads it automatically within a fraction of a second, so your
    changes take effect immediately without restarting.

.PARAMETER List
    Print the loaded shortcuts and exit.

.PARAMETER RunSeconds
    Run for N seconds then exit (used for self-testing). 0 = run until closed (default).
#>
[CmdletBinding()]
param(
    [switch]$List,
    [int]$RunSeconds = 0
)

$ErrorActionPreference = 'Stop'

$here    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$cfgPath = Join-Path $here 'shortcuts.json'
$enginePath = Join-Path $here 'Engine.cs'
if (-not (Test-Path $cfgPath))    { throw "shortcuts.json not found next to the script ($cfgPath)." }
if (-not (Test-Path $enginePath)) { throw "Engine.cs not found next to the script ($enginePath)." }

# Parse shortcuts.json -> a hashtable of @{ keys; vals; instant; matchCase }
function Read-Shortcuts {
    param([string]$Path)
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $instant = $true
    if ($c.PSObject.Properties.Name -contains 'instantExpand') { $instant = [bool]$c.instantExpand }
    $matchCase = $false
    if ($c.PSObject.Properties.Name -contains 'matchCase') { $matchCase = [bool]$c.matchCase }
    $pasteMode = 1
    if ($c.PSObject.Properties.Name -contains 'pasteMode') {
        switch ([string]$c.pasteMode) { 'never' {$pasteMode=0} 'always' {$pasteMode=2} default {$pasteMode=1} }
    }
    $keys = New-Object System.Collections.Generic.List[string]
    $vals = New-Object System.Collections.Generic.List[string]
    foreach ($p in $c.shortcuts.PSObject.Properties) {
        if ($p.Name -eq '_comment') { continue }
        $keys.Add([string]$p.Name); $vals.Add([string]$p.Value)
    }
    [pscustomobject]@{ keys = $keys.ToArray(); vals = $vals.ToArray(); instant = $instant; matchCase = $matchCase; pasteMode = $pasteMode }
}

$sc = Read-Shortcuts -Path $cfgPath
if ($sc.keys.Count -eq 0) { throw "No shortcuts defined in shortcuts.json." }

if ($List) {
    $mode = if ($sc.instant) { 'instant' } else { 'on ending character' }
    Write-Host "Loaded $($sc.keys.Count) shortcut(s). Mode: $mode" -ForegroundColor Cyan
    for ($i = 0; $i -lt $sc.keys.Count; $i++) {
        $preview = ($sc.vals[$i] -replace "`r?`n", ' | ')
        if ($preview.Length -gt 70) { $preview = $preview.Substring(0, 67) + '...' }
        '{0,-12} -> {1}' -f $sc.keys[$i], $preview | Write-Host
    }
    return
}

# Compile + install the engine
$cs = Get-Content -LiteralPath $enginePath -Raw
if (-not ('TextShortcuts.Engine' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }
[TextShortcuts.Engine]::Install([string[]]$sc.keys, [string[]]$sc.vals, $sc.instant, $sc.matchCase, $sc.pasteMode)

Write-Host ""
Write-Host "  Text Shortcuts is running (no trigger character)." -ForegroundColor Green
Write-Host "  Loaded $($sc.keys.Count) shortcut(s).  Edit shortcuts.json and save -- it reloads automatically." -ForegroundColor Cyan
Write-Host "  Try typing (in any app):  mysig   myem   ddate" -ForegroundColor DarkGray
Write-Host "  Press Ctrl+C or close this window to stop." -ForegroundColor DarkGray
Write-Host ""

$lastWrite = (Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc
$deadline  = if ($RunSeconds -gt 0) { (Get-Date).AddSeconds($RunSeconds) } else { $null }
$check     = 0
try {
    while ($true) {
        [TextShortcuts.Engine]::Pump()
        [TextShortcuts.Engine]::Tick()
        Start-Sleep -Milliseconds 15

        # Auto-reload shortcuts.json when it changes (checked ~5x/second)
        if ((++$check % 20) -eq 0) {
            $now = (Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc
            if ($now -ne $lastWrite) {
                Start-Sleep -Milliseconds 150   # let the editor finish writing the file
                try {
                    $sc = Read-Shortcuts -Path $cfgPath
                    [TextShortcuts.Engine]::Load([string[]]$sc.keys, [string[]]$sc.vals, $sc.instant, $sc.matchCase, $sc.pasteMode)
                    $stamp = (Get-Date).ToString('HH:mm:ss')
                    Write-Host "  [$stamp] Reloaded shortcuts.json -- $($sc.keys.Count) shortcut(s) active." -ForegroundColor Green
                }
                catch {
                    Write-Host "  shortcuts.json could not be parsed (keeping previous shortcuts): $($_.Exception.Message)" -ForegroundColor Yellow
                }
                $lastWrite = (Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc
            }
        }

        if ($deadline -and (Get-Date) -ge $deadline) { break }
    }
}
finally {
    [TextShortcuts.Engine]::Uninstall()
    Write-Host "Text Shortcuts stopped. Expansions this run: $([TextShortcuts.Engine]::Count)" -ForegroundColor Yellow
}
