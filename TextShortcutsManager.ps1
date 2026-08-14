<#
.SYNOPSIS
    Text Shortcuts Manager -- a GUI to create/edit/delete text-expansion shortcuts.

.DESCRIPTION
    Runs the system-wide text expander AND gives you a window to manage the shortcuts.
    Add, edit, rename or delete shortcuts and they take effect immediately. Closing or
    minimizing the window tucks it into the system tray so expansion keeps running;
    use the tray icon (or its right-click Exit) to restore or quit.

    No trigger character: typing a defined abbreviation (e.g. "mysig") instantly
    replaces it with the expansion in any application.

    Run with:  powershell.exe -STA -File TextShortcutsManager.ps1
    (the Start-TextShortcuts.cmd launcher does this for you)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$cfgPath    = Join-Path $here 'shortcuts.json'
$enginePath = Join-Path $here 'Engine.cs'
if (-not (Test-Path $enginePath)) { [void][System.Windows.Forms.MessageBox]::Show("Engine.cs not found next to this script.","Text Shortcuts"); return }

# --- load the engine ---------------------------------------------------------
$cs = Get-Content -LiteralPath $enginePath -Raw
if (-not ('TextShortcuts.Engine' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

# --- single instance ---------------------------------------------------------
# If a manager is already running, just ask it to show its window, then quit.
if (-not ('TSWin' -as [type])) {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class TSWin { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }
"@
}
$script:createdNew = $false
$script:mutex   = New-Object System.Threading.Mutex($true, 'TextShortcutsManager.SingleInstance', [ref]$script:createdNew)
$script:showEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'TextShortcutsManager.ShowWindow')
if (-not $script:createdNew) { [void]$script:showEvt.Set(); return }
$script:showTimer = $null

# --- state -------------------------------------------------------------------
$script:short       = [ordered]@{}     # abbreviation -> expansion
$script:instant     = $true
$script:matchCase   = $false
$script:pasteMode   = 1                # 0 never, 1 auto (long/multiline), 2 always
$script:enabled     = $true
$script:selectedKey = $null
$script:loading     = $false
$script:reallyExit  = $false
$script:comment     = "Managed by Text Shortcuts Manager. Type an abbreviation and it expands instantly. Use distinctive abbreviations you'd never type as a normal word."

function Read-ConfigFile {
    if (-not (Test-Path $cfgPath)) { return }
    $c = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    if ($c.PSObject.Properties.Name -contains 'instantExpand') { $script:instant   = [bool]$c.instantExpand }
    if ($c.PSObject.Properties.Name -contains 'matchCase')     { $script:matchCase = [bool]$c.matchCase }
    if ($c.PSObject.Properties.Name -contains '_comment')      { $script:comment   = [string]$c._comment }
    if ($c.PSObject.Properties.Name -contains 'pasteMode') {
        switch ([string]$c.pasteMode) { 'never' {$script:pasteMode=0} 'always' {$script:pasteMode=2} default {$script:pasteMode=1} }
    }
    $script:short = [ordered]@{}
    if ($c.shortcuts) {
        foreach ($p in $c.shortcuts.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $script:short[[string]$p.Name] = [string]$p.Value
        }
    }
}

function Write-ConfigFile {
    $pmText = switch ($script:pasteMode) { 0 {'never'} 2 {'always'} default {'auto'} }
    $obj = [ordered]@{
        '_comment'    = $script:comment
        instantExpand = $script:instant
        matchCase     = $script:matchCase
        pasteMode     = $pmText
        shortcuts     = $script:short
    }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
}

function Sync-Engine {
    $keys = @($script:short.Keys)
    $vals = @($script:short.Values)
    [TextShortcuts.Engine]::Load([string[]]$keys, [string[]]$vals, $script:instant, $script:matchCase, $script:pasteMode)
    [TextShortcuts.Engine]::SetEnabled($script:enabled)
}

# --- build UI ----------------------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text          = "Text Shortcuts Manager"
$form.Size          = New-Object System.Drawing.Size(780, 520)
$form.MinimumSize   = New-Object System.Drawing.Size(680, 440)
$form.StartPosition = "CenterScreen"

$lblList = New-Object System.Windows.Forms.Label
$lblList.Text = "Shortcuts"; $lblList.Location = New-Object System.Drawing.Point(12,12); $lblList.AutoSize = $true
$form.Controls.Add($lblList)

$lst = New-Object System.Windows.Forms.ListBox
$lst.Location = New-Object System.Drawing.Point(12,34)
$lst.Size     = New-Object System.Drawing.Size(220,360)
$lst.Anchor   = 'Top,Bottom,Left'
$lst.IntegralHeight = $false
$form.Controls.Add($lst)

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Text = "New"; $btnNew.Location = New-Object System.Drawing.Point(12,400); $btnNew.Size = New-Object System.Drawing.Size(105,30); $btnNew.Anchor='Bottom,Left'
$form.Controls.Add($btnNew)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete"; $btnDelete.Location = New-Object System.Drawing.Point(127,400); $btnDelete.Size = New-Object System.Drawing.Size(105,30); $btnDelete.Anchor='Bottom,Left'
$form.Controls.Add($btnDelete)

$lblKey = New-Object System.Windows.Forms.Label
$lblKey.Text = "Abbreviation (type this):"; $lblKey.Location = New-Object System.Drawing.Point(252,34); $lblKey.AutoSize=$true
$form.Controls.Add($lblKey)

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(255,56); $txtKey.Size = New-Object System.Drawing.Size(495,24); $txtKey.Anchor='Top,Left,Right'
$form.Controls.Add($txtKey)

$lblVal = New-Object System.Windows.Forms.Label
$lblVal.Text = "Expands to:"; $lblVal.Location = New-Object System.Drawing.Point(252,90); $lblVal.AutoSize=$true
$form.Controls.Add($lblVal)

$txtVal = New-Object System.Windows.Forms.TextBox
$txtVal.Location = New-Object System.Drawing.Point(255,112); $txtVal.Size = New-Object System.Drawing.Size(495,230)
$txtVal.Multiline = $true; $txtVal.AcceptsReturn = $true; $txtVal.ScrollBars = 'Vertical'; $txtVal.WordWrap = $true
$txtVal.Anchor='Top,Bottom,Left,Right'
$txtVal.Font = New-Object System.Drawing.Font("Consolas",10)
$form.Controls.Add($txtVal)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Tip: use {date}, {time} or {datetime} for live values. Press Enter for new lines."
$lblHint.Location = New-Object System.Drawing.Point(252,346); $lblHint.AutoSize=$true; $lblHint.ForeColor='Gray'; $lblHint.Anchor='Bottom,Left'
$form.Controls.Add($lblHint)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save shortcut"; $btnSave.Location = New-Object System.Drawing.Point(255,368); $btnSave.Size = New-Object System.Drawing.Size(140,32); $btnSave.Anchor='Bottom,Left'
$form.Controls.Add($btnSave)

# options row
$chkEnabled = New-Object System.Windows.Forms.CheckBox
$chkEnabled.Text = "Expansion ON"; $chkEnabled.Location = New-Object System.Drawing.Point(255,408); $chkEnabled.AutoSize=$true; $chkEnabled.Checked=$true; $chkEnabled.Anchor='Bottom,Left'
$form.Controls.Add($chkEnabled)

$chkInstant = New-Object System.Windows.Forms.CheckBox
$chkInstant.Text = "Instant (no space needed)"; $chkInstant.Location = New-Object System.Drawing.Point(395,408); $chkInstant.AutoSize=$true; $chkInstant.Checked=$true; $chkInstant.Anchor='Bottom,Left'
$form.Controls.Add($chkInstant)

$chkCase = New-Object System.Windows.Forms.CheckBox
$chkCase.Text = "Match case"; $chkCase.Location = New-Object System.Drawing.Point(600,408); $chkCase.AutoSize=$true; $chkCase.Checked=$false; $chkCase.Anchor='Bottom,Left'
$form.Controls.Add($chkCase)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(255,436); $status.Size = New-Object System.Drawing.Size(495,22); $status.ForeColor='SteelBlue'; $status.Anchor='Bottom,Left,Right'
$form.Controls.Add($status)

function Set-Status([string]$msg,[string]$color='SteelBlue'){ $status.ForeColor=$color; $status.Text=$msg }

function Refresh-List([string]$select){
    $script:loading = $true
    $lst.Items.Clear()
    foreach($k in $script:short.Keys){ [void]$lst.Items.Add($k) }
    if ($select -and $lst.Items.Contains($select)) { $lst.SelectedItem = $select }
    $script:loading = $false
}

# --- events ------------------------------------------------------------------
$lst.add_SelectedIndexChanged({
    if ($script:loading) { return }
    if ($lst.SelectedItem) {
        $k = [string]$lst.SelectedItem
        $script:selectedKey = $k
        $txtKey.Text = $k
        $txtVal.Text = ([string]$script:short[$k]) -replace "(?<!`r)`n","`r`n"
        Set-Status "Editing '$k'."
    }
})

$btnNew.add_Click({
    $script:selectedKey = $null
    $lst.ClearSelected()
    $txtKey.Clear(); $txtVal.Clear()
    $txtKey.Focus()
    Set-Status "New shortcut -- enter an abbreviation and its expansion, then Save."
})

$btnSave.add_Click({
    $k = $txtKey.Text.Trim()
    $v = $txtVal.Text
    if ([string]::IsNullOrWhiteSpace($k)) { Set-Status "Enter an abbreviation first." 'Firebrick'; return }
    if ($k -notmatch '^[A-Za-z0-9]+$') {
        [void][System.Windows.Forms.MessageBox]::Show("Abbreviations must be letters/numbers only (no spaces or punctuation), because expansion triggers on whole words.","Invalid abbreviation",'OK','Warning')
        return
    }
    # rename: drop the old key if it changed
    if ($script:selectedKey -and $script:selectedKey -ne $k -and $script:short.Contains($script:selectedKey)) {
        $script:short.Remove($script:selectedKey)
    }
    # warn about prefix clashes in instant mode (non-blocking)
    if ($script:instant) {
        foreach($other in @($script:short.Keys)){
            if ($other -eq $k) { continue }
            $cmp = if ($script:matchCase) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
            if ($k.StartsWith($other,$cmp) -or $other.StartsWith($k,$cmp)) {
                Set-Status "Saved '$k'. Note: it shares a prefix with '$other' -- the shorter one fires first." 'DarkOrange'
                break
            }
        }
    }
    $script:short[$k] = $v
    Write-ConfigFile; Sync-Engine; Refresh-List $k
    $script:selectedKey = $k
    if ($status.Text -notlike "*shares a prefix*") { Set-Status "Saved '$k'. $($script:short.Count) shortcut(s) active." 'Green' }
})

$btnDelete.add_Click({
    if (-not $lst.SelectedItem) { Set-Status "Select a shortcut to delete." 'Firebrick'; return }
    $k = [string]$lst.SelectedItem
    if ([System.Windows.Forms.MessageBox]::Show("Delete shortcut '$k'?","Confirm",'YesNo','Question') -ne 'Yes') { return }
    $script:short.Remove($k)
    Write-ConfigFile; Sync-Engine; Refresh-List
    $script:selectedKey = $null; $txtKey.Clear(); $txtVal.Clear()
    Set-Status "Deleted '$k'. $($script:short.Count) shortcut(s) active." 'Green'
})

$chkEnabled.add_CheckedChanged({
    $script:enabled = $chkEnabled.Checked
    [TextShortcuts.Engine]::SetEnabled($script:enabled)
    $form.Text = if ($script:enabled) { "Text Shortcuts Manager" } else { "Text Shortcuts Manager  (PAUSED)" }
    Set-Status $(if($script:enabled){"Expansion enabled."}else{"Expansion paused."})
})

$onOption = {
    $script:instant   = $chkInstant.Checked
    $script:matchCase = $chkCase.Checked
    Write-ConfigFile; Sync-Engine
    Set-Status "Settings updated." 'Green'
}
$chkInstant.add_CheckedChanged($onOption)
$chkCase.add_CheckedChanged($onOption)

# --- system tray -------------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = "Text Shortcuts (running)"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add("Open manager")
$miExit = $menu.Items.Add("Exit")
$tray.ContextMenuStrip = $menu

$showForm = { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
$miOpen.add_Click($showForm)
$tray.add_DoubleClick($showForm)
$miExit.add_Click({ $script:reallyExit = $true; $form.Close() })

$form.add_Resize({ if ($form.WindowState -eq 'Minimized') { $form.Hide() } })
$form.add_FormClosing({
    param($s,$e)
    if (-not $script:reallyExit) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(1500,"Text Shortcuts","Still running in the tray. Right-click the tray icon to exit.",'Info')
    }
})
$form.add_FormClosed({
    [TextShortcuts.Engine]::Uninstall()
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:showTimer) { $script:showTimer.Stop(); $script:showTimer.Dispose() }
    try { $script:mutex.ReleaseMutex() } catch { }
    $script:mutex.Dispose()
    $script:showEvt.Dispose()
})

# Another launch (e.g. double-clicking the shortcut again) signals this event; bring the window up.
$script:showTimer = New-Object System.Windows.Forms.Timer
$script:showTimer.Interval = 120
$script:showTimer.add_Tick({
    [TextShortcuts.Engine]::Tick()   # restores the clipboard after a paste-expansion
    if ($script:showEvt.WaitOne(0)) {
        $form.Show()
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $form.Activate()
        [void][TSWin]::SetForegroundWindow($form.Handle)
    }
})
$script:showTimer.Start()

# --- start -------------------------------------------------------------------
Read-ConfigFile
$chkInstant.Checked = $script:instant
$chkCase.Checked    = $script:matchCase
[TextShortcuts.Engine]::Install([string[]]@($script:short.Keys), [string[]]@($script:short.Values), $script:instant, $script:matchCase, $script:pasteMode)
[TextShortcuts.Engine]::SetEnabled($true)
Refresh-List
Set-Status "Running. $($script:short.Count) shortcut(s) active. Type one in any app to test."

$form.add_Shown({ [TextShortcuts.Engine]::SetOwnWindow($form.Handle) })

[void][System.Windows.Forms.Application]::Run($form)
