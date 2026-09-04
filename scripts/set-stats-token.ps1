[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'stats-credential.ps1')

Write-Host 'Store GitHub profile-stats token in Windows Credential Manager'
Write-Host 'Required classic PAT scopes: repo + read:user'
Write-Host 'The token will not be written to this repository, a .env file, command history, or logs.'
Write-Host ''

$secureToken = Read-Host 'Paste the classic PAT' -AsSecureString
if ($secureToken.Length -lt 20) {
    throw 'That token is unexpectedly short. Nothing was stored.'
}

Set-StatsToken -Token $secureToken
$secureToken.Dispose()

# Verify that the credential can be read back without displaying it.
$stored = Get-StatsToken
try {
    if ([string]::IsNullOrWhiteSpace($stored)) {
        throw 'Credential Manager returned an empty credential after storage.'
    }
    Write-Host 'Token stored successfully in Windows Credential Manager.'
    Write-Host 'Run .\scripts\refresh-stats.ps1 to validate its GitHub scopes and refresh the card.'
}
finally {
    $stored = $null
}
