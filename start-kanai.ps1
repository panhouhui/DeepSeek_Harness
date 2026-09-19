[CmdletBinding()]
param(
    [ValidateSet('web', 'headless')]
    [string]$Profile = 'web',
    [ValidateSet('fast', 'normal', 'thinking', 'max')]
    [string]$Mode = 'fast',
    [ValidateSet('off', 'auto', 'force')]
    [string]$WebSearch = 'auto',
    [ValidateRange(1, 262144)]
    [int]$MaxTokens = 65536,
    [string]$Prompt,
    [ValidateRange(1, 65535)]
    [int]$Port = 3000,
    [switch]$NoOpen,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$kanaiHome = Join-Path $env:USERPROFILE '.dsh-kanai'
$kanaiCert = Join-Path $kanaiHome 'kanai-local-api-ca.crt'
if (-not (Test-Path -LiteralPath $kanaiCert)) {
    throw "Missing gateway CA certificate: $kanaiCert"
}
if (-not (Test-Path -LiteralPath (Join-Path $kanaiHome '.env'))) {
    throw "Missing KANAI_API_KEY configuration: $kanaiHome\.env"
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'node_modules'))) {
    throw 'Install workspace dependencies with pnpm install --frozen-lockfile first.'
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'apps/cli/lib/bin.js'))) {
    throw 'Build the workspace with pnpm run build first.'
}
if ($Profile -eq 'headless' -and [string]::IsNullOrWhiteSpace($Prompt)) {
    throw 'Headless mode requires -Prompt.'
}

$kanaiEnvironment = @{
    DSH_HOME = $kanaiHome
    NODE_EXTRA_CA_CERTS = $kanaiCert
    NO_PROXY = '*'
    DSH_TELEMETRY_DISABLED = '1'
    KANAI_WEB_SEARCH = $WebSearch
    KANAI_REASONING_EFFORT = $(if ($Mode -eq 'fast') { 'off' } elseif ($Mode -eq 'max') { 'max' } else { 'high' })
    KANAI_MAX_TOKENS = $(if ($Mode -eq 'max' -and -not $PSBoundParameters.ContainsKey('MaxTokens')) { '262144' } else { [string]$MaxTokens })
}
$previousEnvironment = @{}
foreach ($key in $kanaiEnvironment.Keys) {
    $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$kanaiExitCode = 1
Push-Location $PSScriptRoot
try {
    foreach ($key in $kanaiEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $kanaiEnvironment[$key], 'Process')
    }
    $kanaiArgs = @('apps/cli/lib/bin.js', $Profile, '--patch', 'apps/cli/config/examples/kanai/cordis.patch.yml')
    if ($Profile -eq 'web') {
        $kanaiArgs += @('--host', '127.0.0.1', '--port', [string]$Port)
        if ($NoOpen) { $kanaiArgs += '--no-open' }
    } else {
        if ($Json) { $kanaiArgs += '--json' }
        $kanaiArgs += @('--', $Prompt)
    }
    & node @kanaiArgs
    $kanaiExitCode = $LASTEXITCODE
} finally {
    foreach ($key in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
    }
    Pop-Location
}
exit $kanaiExitCode
