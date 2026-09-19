#Requires -Version 5.1
<#
.SYNOPSIS
Install or manage a per-user Kanai Web task using Windows PowerShell.
.DESCRIPTION
Install defaults to boot startup and asks for the current Windows account password.
Use -AtLogon for an interactive logon task that does not store a password.
Logs stay under the current user's .dsh-kanai directory, outside the repository.
.PARAMETER Action
Install, Start, Stop, Status, Open, or Remove the current user's task.
.PARAMETER AtLogon
Install a logon trigger instead of a boot trigger. Applies only to Install.
.PARAMETER Port
Loopback port to record when installing the task.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Start', 'Stop', 'Status', 'Open', 'Remove')]
    [string]$Action = 'Install',
    [switch]$AtLogon,
    [ValidateRange(1, 65535)]
    [int]$Port = 3000
)

$ErrorActionPreference = 'Stop'
$kanaiIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$kanaiAccount = $kanaiIdentity.Name
$kanaiOwner = $kanaiIdentity.User.Value
$kanaiTaskName = "DeepSeek-Harness-Kanai-$kanaiOwner"
$kanaiMarker = "DeepSeek Harness Kanai task; owner=$kanaiOwner"
$kanaiHome = Join-Path $env:USERPROFILE '.dsh-kanai'
$kanaiLogs = Join-Path $kanaiHome 'autostart'
$kanaiScript = Join-Path $PSScriptRoot 'start-kanai.ps1'
$kanaiPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$kanaiExisting = Get-ScheduledTask | Where-Object { $_.TaskName -eq $kanaiTaskName -and $_.TaskPath -eq '\' }
if ($kanaiExisting -and $kanaiExisting.Description -ne $kanaiMarker) {
    throw "Refusing to change an unrelated task: $kanaiTaskName"
}

# A scheduled PowerShell process can leave native children behind when stopped by Windows.
function Stop-KanaiBackground {
    $kanaiRunnerFile = Join-Path $kanaiLogs 'runner.json'
    if (Test-Path -LiteralPath $kanaiRunnerFile) {
        $kanaiRunner = Get-Content -LiteralPath $kanaiRunnerFile -Raw | ConvertFrom-Json
        $kanaiProcess = Get-Process -Id ([int]$kanaiRunner.ProcessId) -ErrorAction SilentlyContinue
        if ($kanaiProcess -and [string]$kanaiProcess.StartTime.ToUniversalTime().Ticks -eq $kanaiRunner.StartedTicks) {
            $kanaiProcessCommand = (Get-CimInstance Win32_Process -Filter "ProcessId=$($kanaiProcess.Id)").CommandLine
            $kanaiQuotedScript = '"' + $kanaiRunner.ScriptPath + '"'
            if (-not $kanaiExisting.Actions.Arguments.Contains($kanaiQuotedScript) -or -not $kanaiProcessCommand.Contains($kanaiQuotedScript)) {
                throw 'Recorded runner does not match the scheduled launcher; refusing to stop another process.'
            }
            & "$env:SystemRoot\System32\taskkill.exe" /PID $kanaiProcess.Id /T /F | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not stop the scheduled process tree.' }
            if (-not $kanaiProcess.WaitForExit(10000)) { throw 'Scheduled launcher did not exit.' }
        }
    }
    Stop-ScheduledTask -TaskName $kanaiTaskName
}

if ($Action -eq 'Install') {
    foreach ($kanaiRequired in @($kanaiScript, (Join-Path $kanaiHome '.env'), (Join-Path $kanaiHome 'kanai-local-api-ca.crt'), (Join-Path $PSScriptRoot 'apps/cli/lib/bin.js'))) {
        if (-not (Test-Path -LiteralPath $kanaiRequired -PathType Leaf)) {
            throw "Required file missing: $kanaiRequired"
        }
    }
    $kanaiNode = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $kanaiNode = & $kanaiNode -p process.execPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $kanaiNode -PathType Leaf)) { throw 'Cannot resolve the installed Node executable.' }
    if ($kanaiExisting -and $kanaiExisting.State -eq 'Running') {
        throw 'Stop the existing task with -Action Stop before reinstalling it.'
    }
    if ([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -contains $Port) {
        throw "Port $Port is occupied. Stop the foreground server first, or install with -Port <another port>."
    }
    $kanaiArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -NoOpen -Port {1} -NodePath "{2}" -LogDirectory "{3}"' -f $kanaiScript, $Port, $kanaiNode, $kanaiLogs
    $kanaiTaskAction = New-ScheduledTaskAction -Execute $kanaiPowerShell -Argument $kanaiArguments -WorkingDirectory $PSScriptRoot
    $kanaiSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    if ($AtLogon) {
        $kanaiTrigger = New-ScheduledTaskTrigger -AtLogOn -User $kanaiAccount
        $kanaiPrincipal = New-ScheduledTaskPrincipal -UserId $kanaiAccount -LogonType Interactive -RunLevel Limited
    } else {
        $kanaiPrincipal = New-ScheduledTaskPrincipal -UserId $kanaiAccount -LogonType Password -RunLevel Limited
        $kanaiTrigger = New-ScheduledTaskTrigger -AtStartup
        $kanaiTrigger.Delay = 'PT30S'
    }
    $kanaiDefinition = New-ScheduledTask -Action $kanaiTaskAction -Trigger $kanaiTrigger -Settings $kanaiSettings -Principal $kanaiPrincipal -Description $kanaiMarker
    if (-not $PSCmdlet.ShouldProcess($kanaiTaskName, "Install and start for $kanaiAccount from $PSScriptRoot")) { return }
    if (-not $AtLogon) {
        $kanaiIsAdmin = ([Security.Principal.WindowsPrincipal]$kanaiIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $kanaiIsAdmin) { throw 'Open CMD as administrator using this same Windows account, then run this command again. Or use -AtLogon.' }
        Write-Host "Windows account: $kanaiAccount"
        Write-Host 'Enter the Windows account password, NOT a PIN or model API Key. Windows Task Scheduler stores the credential.'
        $kanaiSecret = Read-Host 'Windows password' -AsSecureString
        if ($kanaiSecret.Length -eq 0) { throw 'Boot startup requires an account password. Use -AtLogon if you only use a PIN.' }
        $kanaiCredential = New-Object Management.Automation.PSCredential($kanaiAccount, $kanaiSecret)
        try {
            Register-ScheduledTask -TaskName $kanaiTaskName -InputObject $kanaiDefinition -User $kanaiAccount -Password $kanaiCredential.GetNetworkCredential().Password -Force | Out-Null
        } finally {
            $kanaiSecret.Dispose()
            $kanaiCredential = $null
        }
    } else {
        Register-ScheduledTask -TaskName $kanaiTaskName -InputObject $kanaiDefinition -Force | Out-Null
    }
    Write-Host "Installed: $kanaiTaskName"
    Write-Host "Account: $kanaiAccount; repository: $PSScriptRoot"
    if ($AtLogon) { Write-Host 'Starts after this user logs in; does not run before login.' }
    else { Write-Host 'Starts 30 seconds after boot, including before login.' }
    Start-ScheduledTask -TaskName $kanaiTaskName
    Write-Host "Background start requested. Logs: $kanaiLogs"
    Write-Host 'Use -Action Status to check the task and -Action Open to open the authenticated Web page.'
    return
}

if (-not $kanaiExisting) {
    if ($Action -eq 'Remove') { Write-Host 'No Kanai autostart task is installed for this user.'; return }
    throw 'No Kanai autostart task is installed for this user. Run -Action Install first.'
}

switch ($Action) {
    'Start' {
        if ($PSCmdlet.ShouldProcess($kanaiTaskName, 'Start')) {
            Start-ScheduledTask -TaskName $kanaiTaskName
            Write-Host "Background start requested. Logs: $kanaiLogs"
        }
    }
    'Stop' {
        if ($PSCmdlet.ShouldProcess($kanaiTaskName, 'Stop')) {
            Stop-KanaiBackground
            Write-Host 'Background task stopped. Autostart remains installed.'
        }
    }
    'Remove' {
        if ($PSCmdlet.ShouldProcess($kanaiTaskName, 'Stop and remove')) {
            Stop-KanaiBackground
            Unregister-ScheduledTask -TaskName $kanaiTaskName -Confirm:$false
            Write-Host 'Autostart removed. Credentials, logs, and sessions remain in the user directory.'
        }
    }
    'Status' {
        $kanaiInfo = Get-ScheduledTaskInfo -TaskName $kanaiTaskName
        [pscustomobject]@{ Task = $kanaiTaskName; State = $kanaiExisting.State; LastRun = $kanaiInfo.LastRunTime; LastResult = $kanaiInfo.LastTaskResult; Logs = $kanaiLogs } | Format-List
    }
    'Open' {
        if ($kanaiExisting.State -ne 'Running') { throw 'The task is not running. Use -Action Start and check the logs.' }
        $kanaiLog = Join-Path $kanaiLogs 'web.stdout.log'
        if (-not (Test-Path -LiteralPath $kanaiLog)) { throw "The server has not written its URL yet. Check $kanaiLogs and retry." }
        $kanaiLogStream = [IO.File]::Open($kanaiLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $kanaiReader = New-Object IO.StreamReader($kanaiLogStream)
            try { $kanaiLogText = $kanaiReader.ReadToEnd() } finally { $kanaiReader.Dispose() }
        } finally {
            $kanaiLogStream.Dispose()
        }
        $kanaiUrls = [regex]::Matches($kanaiLogText, 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9._~%-]+')
        if ($kanaiUrls.Count -eq 0) { throw "No authenticated URL found. Check $kanaiLogs and retry after startup." }
        $kanaiUrl = $kanaiUrls[$kanaiUrls.Count - 1].Value
        $kanaiResponse = Invoke-WebRequest -Uri $kanaiUrl -UseBasicParsing -TimeoutSec 10
        if ($kanaiResponse.StatusCode -ne 200) { throw 'The logged Web URL is not ready.' }
        if ($PSCmdlet.ShouldProcess('Kanai Web UI', 'Open in the default browser')) { Start-Process -FilePath $kanaiUrl }
    }
}
