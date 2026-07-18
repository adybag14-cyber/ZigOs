[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Terminate
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRootSlash = $repoRoot.Replace('\', '/')
$currentProcessId = $PID

function Test-RepoCommandLine {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    return $CommandLine.IndexOf($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $CommandLine.IndexOf($repoRootSlash, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$targets = Get-CimInstance Win32_Process | Where-Object {
    if ($_.ProcessId -eq $currentProcessId -or -not (Test-RepoCommandLine $_.CommandLine)) {
        return $false
    }

    $name = $_.Name.ToLowerInvariant()
    if ($name -eq 'qemu-system-x86_64.exe') { return $true }
    if ($name -in @('python.exe', 'pythonw.exe', 'py.exe')) {
        return $_.CommandLine -match 'create-nvme-test-image\.py|milestone_[0-9]+\.py'
    }
    if ($name -in @('powershell.exe', 'pwsh.exe')) {
        return $_.CommandLine -match 'scripts[\\/]test-qemu\.ps1|matrix-[0-9]+'
    }
    return $false
}

if (-not $targets) {
    Write-Host 'No active ZigOs test, QEMU, or repository Python helper processes were found.'
    return
}

$targets | Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine | Format-Table -Wrap
if (-not $Terminate) {
    Write-Host 'Inspection only. Re-run with -Terminate to stop only the listed ZigOs-owned processes.'
    return
}

foreach ($target in $targets) {
    $description = "$($target.Name) PID $($target.ProcessId)"
    if ($PSCmdlet.ShouldProcess($description, 'Terminate ZigOs-owned process')) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$deadline = (Get-Date).AddSeconds(5)
do {
    $remaining = @($targets | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Milliseconds 100
} while ((Get-Date) -lt $deadline)

$remaining = @($targets | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
if ($remaining.Count -ne 0) {
    throw "Failed to terminate $($remaining.Count) ZigOs-owned process(es)."
}
Write-Host "Terminated $($targets.Count) ZigOs-owned process(es)."
