#Requires -Version 5.1
<#
.SYNOPSIS
Install or manage the Kanai Web launcher as a Windows service supervised by NSSM.
.DESCRIPTION
The service runs the built-in Windows PowerShell launcher under the current Windows
account so that %USERPROFILE%\.dsh-kanai resolves to the account that owns the key.
Run this script from an elevated Windows PowerShell 5.1 session under that account.
.PARAMETER Action
Install, Start, Stop, Restart, Status, or Remove the service.
.PARAMETER NssmPath
Path to nssm.exe, or a command name available on PATH.
.PARAMETER Port
Loopback port for the Kanai Web server.
.PARAMETER ServiceName
Windows service name. Keep the default unless a separate installation is required.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Start', 'Stop', 'Restart', 'Status', 'Remove')]
    [string]$Action = 'Install',
    [string]$NssmPath = 'nssm.exe',
    [ValidateRange(1, 65535)]
    [int]$Port = 3000,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ServiceName = 'DeepSeek-Harness-Kanai'
)

$ErrorActionPreference = 'Stop'
$kanaiIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$kanaiAccount = $kanaiIdentity.Name
$kanaiOwner = $kanaiIdentity.User.Value
$kanaiHome = Join-Path $env:USERPROFILE '.dsh-kanai'
$kanaiLogs = Join-Path $kanaiHome 'autostart'
$kanaiScript = Join-Path $PSScriptRoot 'start-kanai.ps1'
$kanaiPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$kanaiMarker = "DeepSeek Harness Kanai NSSM service; owner=$kanaiOwner"
$kanaiLegacyMarker = "$kanaiMarker; repository=$PSScriptRoot"
$kanaiIsAdmin = ([Security.Principal.WindowsPrincipal]$kanaiIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-KanaiService {
    return Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
}

function Assert-KanaiServiceOwner {
    param([object]$Service)
    if (-not $Service) { throw "Service '$ServiceName' is not installed. Run -Action Install first." }
    if ($Service.Description -ne $kanaiMarker -and $Service.Description -ne $kanaiLegacyMarker) {
        throw "Refusing to change an unrelated Windows service: $ServiceName"
    }
}

function Resolve-KanaiNssm {
    if ($NssmPath -ne 'nssm.exe' -and (Test-Path -LiteralPath $NssmPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $NssmPath).Path
    }
    $kanaiCommand = Get-Command $NssmPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($kanaiCommand) { return $kanaiCommand.Source }
    throw "NSSM was not found. Install it from https://nssm.cc/download or pass -NssmPath 'C:\\Tools\\nssm\\win64\\nssm.exe'."
}

function Invoke-KanaiNssm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Sensitive
    )
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        $kanaiShownArguments = if ($Sensitive) { '<redacted>' } else { $Arguments -join ' ' }
        throw "NSSM command failed with exit code ${LASTEXITCODE}: $kanaiShownArguments"
    }
}

function ConvertTo-KanaiArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + ($Value -replace '"', '\\"') + '"'
}

function Assert-KanaiInstallFiles {
    foreach ($kanaiRequired in @(
            $kanaiScript,
            (Join-Path $kanaiHome '.env'),
            (Join-Path $kanaiHome 'kanai-local-api-ca.crt'),
            (Join-Path $PSScriptRoot 'apps/cli/lib/bin.js'),
            (Join-Path $PSScriptRoot 'node_modules')
        )) {
        if (-not (Test-Path -LiteralPath $kanaiRequired)) {
            throw "Required file or directory missing: $kanaiRequired"
        }
    }
    if (-not (Test-Path -LiteralPath $kanaiPowerShell -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found: $kanaiPowerShell"
    }
    $kanaiNodeCommand = Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $kanaiNode = & $kanaiNodeCommand.Source -p process.execPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $kanaiNode -PathType Leaf)) {
        throw 'Cannot resolve the installed Node executable.'
    }
    return $kanaiNode
}

$kanaiExisting = Get-KanaiService
if ($kanaiExisting) {
    Assert-KanaiServiceOwner $kanaiExisting
}

if ($Action -eq 'Status') {
    if (-not $kanaiExisting) {
        Write-Host "Service '$ServiceName' is not installed."
        return
    }
    [pscustomobject]@{
        Service = $kanaiExisting.Name
        State = $kanaiExisting.State
        StartMode = $kanaiExisting.StartMode
        Account = $kanaiExisting.StartName
        Application = $kanaiExisting.PathName
        Repository = $PSScriptRoot
        Logs = $kanaiLogs
    } | Format-List
    return
}

if (-not $kanaiExisting -and $Action -ne 'Install') {
    throw "Service '$ServiceName' is not installed. Run -Action Install first."
}
if (-not $kanaiIsAdmin -and -not $WhatIfPreference) {
    throw 'Run Windows PowerShell as administrator under the Windows account that owns the model configuration.'
}

$kanaiNssm = if ($WhatIfPreference) { $null } else { Resolve-KanaiNssm }

switch ($Action) {
    'Install' {
        $kanaiNode = Assert-KanaiInstallFiles
        if ($kanaiExisting -and $kanaiExisting.State -ne 'STOPPED') {
            throw "Stop '$ServiceName' before reinstalling it."
        }
        if ([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -contains $Port) {
            throw "Port $Port is occupied. Stop the existing server or choose another port with -Port."
        }
        $kanaiArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File {0} -NoOpen -Port {1} -NodePath {2} -LogDirectory {3}' -f `
            (ConvertTo-KanaiArgument $kanaiScript),
            $Port,
            (ConvertTo-KanaiArgument $kanaiNode),
            (ConvertTo-KanaiArgument $kanaiLogs)
        if (-not $PSCmdlet.ShouldProcess($ServiceName, "Install NSSM service for $kanaiAccount")) { return }

        New-Item -ItemType Directory -Path $kanaiLogs -Force | Out-Null
        if (-not $kanaiExisting) {
            Invoke-KanaiNssm $kanaiNssm @('install', $ServiceName, $kanaiPowerShell)
        }
        foreach ($kanaiSetting in @(
                @('set', $ServiceName, 'Application', $kanaiPowerShell),
                @('set', $ServiceName, 'AppDirectory', $PSScriptRoot),
                @('set', $ServiceName, 'AppParameters', $kanaiArguments),
                @('set', $ServiceName, 'AppEnvironmentExtra', "USERPROFILE=$env:USERPROFILE"),
                @('set', $ServiceName, 'DisplayName', 'DeepSeek Harness Kanai'),
                @('set', $ServiceName, 'Description', $kanaiMarker),
                @('set', $ServiceName, 'Start', 'SERVICE_DELAYED_AUTO_START'),
                @('set', $ServiceName, 'AppNoConsole', '1'),
                @('set', $ServiceName, 'AppStdout', (Join-Path $kanaiLogs 'nssm.stdout.log')),
                @('set', $ServiceName, 'AppStderr', (Join-Path $kanaiLogs 'nssm.stderr.log')),
                @('set', $ServiceName, 'AppRotateFiles', '1'),
                @('set', $ServiceName, 'AppRotateOnline', '1'),
                @('set', $ServiceName, 'AppRotateBytes', '10485760'),
                @('set', $ServiceName, 'AppExit', '0', 'Exit'),
                @('set', $ServiceName, 'AppExit', 'Default', 'Restart'),
                @('set', $ServiceName, 'AppRestartDelay', '5000'),
                @('set', $ServiceName, 'AppThrottle', '10000'),
                @('set', $ServiceName, 'AppStopMethodConsole', '1500'),
                @('set', $ServiceName, 'AppStopMethodWindow', '1500'),
                @('set', $ServiceName, 'AppStopMethodThreads', '1500')
            )) {
            Invoke-KanaiNssm $kanaiNssm $kanaiSetting
        }
        Write-Host "Windows account: $kanaiAccount"
        Write-Host 'Enter the Windows account password, NOT a PIN or model API Key. NSSM uses it for the service logon.'
        $kanaiSecret = Read-Host 'Windows password' -AsSecureString
        if ($kanaiSecret.Length -eq 0) { throw 'The service requires the Windows account password.' }
        $kanaiCredential = New-Object Management.Automation.PSCredential($kanaiAccount, $kanaiSecret)
        try {
            Invoke-KanaiNssm $kanaiNssm @('set', $ServiceName, 'ObjectName', $kanaiAccount, $kanaiCredential.GetNetworkCredential().Password) -Sensitive
        } finally {
            $kanaiSecret.Dispose()
            $kanaiCredential = $null
        }
        Write-Host "Installed NSSM service: $ServiceName"
        Write-Host "Repository: $PSScriptRoot"
        Write-Host "Logs: $kanaiLogs"
        Invoke-KanaiNssm $kanaiNssm @('start', $ServiceName)
        Write-Host 'Background start requested. Use -Action Status and inspect the logs if the state is not Running.'
    }
    'Start' {
        if ($kanaiExisting.State -eq 'RUNNING') { Write-Host "Service '$ServiceName' is already running."; return }
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Start')) {
            Invoke-KanaiNssm $kanaiNssm @('start', $ServiceName)
            Write-Host "Background start requested. Logs: $kanaiLogs"
        }
    }
    'Stop' {
        if ($kanaiExisting.State -eq 'STOPPED') { Write-Host "Service '$ServiceName' is already stopped."; return }
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop')) {
            Invoke-KanaiNssm $kanaiNssm @('stop', $ServiceName)
            Write-Host 'Background service stopped. Installation remains present.'
        }
    }
    'Restart' {
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Restart')) {
            if ($kanaiExisting.State -ne 'STOPPED') { Invoke-KanaiNssm $kanaiNssm @('stop', $ServiceName) }
            Invoke-KanaiNssm $kanaiNssm @('start', $ServiceName)
            Write-Host "Background restart requested. Logs: $kanaiLogs"
        }
    }
    'Remove' {
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop and remove')) {
            if ($kanaiExisting.State -ne 'STOPPED') { Invoke-KanaiNssm $kanaiNssm @('stop', $ServiceName) }
            Invoke-KanaiNssm $kanaiNssm @('remove', $ServiceName, 'confirm')
            Write-Host "NSSM service removed. Credentials, logs, sessions, and $kanaiHome remain."
        }
    }
}
