[CmdletBinding()]
param(
    [switch]$Scheduled
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ExpectedRemote = 'https://github.com/QuickkNastyy/QuickkNastyy.git'
$ExpectedBranch = 'main'
$AuthorName = 'QuickkNastyy'
$AuthorEmail = '125114991+QuickkNastyy@users.noreply.github.com'
$LogDir = Join-Path $env:LOCALAPPDATA 'QuickkNastyy\profile-stats'
$LogFile = Join-Path $LogDir 'refresh.log'
$MaxLogBytes = 2MB

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) {
    $oldLog = "$LogFile.1"
    if (Test-Path $oldLog) { Remove-Item $oldLog -Force }
    Move-Item $LogFile $oldLog -Force
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if (-not $Scheduled) { Write-Host $Message }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$LogOutput
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($LogOutput) {
        foreach ($line in @($output)) {
            if ($null -ne $line -and "$line".Length -gt 0) { Write-Log "$line" }
        }
    }
    if ($exitCode -ne 0) {
        throw "$FilePath exited with code $exitCode"
    }
    return @($output)
}

function Get-GitValue {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $value = & git -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $value" }
    return (($value | Out-String).Trim())
}

$lock = $null
$token = $null
$previousStatsToken = $env:STATS_TOKEN
try {
    # Prevent a manual run and Scheduled Task run from racing each other.
    $createdNew = $false
    $lock = New-Object Threading.Mutex($true, 'Local\QuickkNastyyProfileStatsRefresh', [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log 'Another stats refresh is already running; exiting.'
        exit 0
    }

    Write-Log 'Starting profile stats refresh.'

    $gitCommand = Get-Command git -ErrorAction Stop
    $nodeCommand = Get-Command node -ErrorAction Stop

    $remote = Get-GitValue @('remote', 'get-url', 'origin')
    if ($remote -ne $ExpectedRemote) {
        throw "Refusing to run: origin is '$remote', expected '$ExpectedRemote'."
    }

    $branch = Get-GitValue @('branch', '--show-current')
    if ($branch -ne $ExpectedBranch) {
        throw "Refusing to run: current branch is '$branch', expected '$ExpectedBranch'."
    }

    $initialStatus = Get-GitValue @('status', '--porcelain=v1', '--untracked-files=all')
    if ($initialStatus) {
        throw 'Refusing to run because the working tree is not clean. This prevents the scheduled refresh from touching unrelated work.'
    }

    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'fetch', '--quiet', 'origin', $ExpectedBranch) | Out-Null
    $head = Get-GitValue @('rev-parse', 'HEAD')
    $originHead = Get-GitValue @('rev-parse', "origin/$ExpectedBranch")
    if ($head -ne $originHead) {
        throw 'Refusing to run because local main and origin/main differ. Sync the profile repo first so automation cannot push unrelated commits.'
    }

    # Repo-local identity only; no unrelated repositories are changed.
    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'config', 'user.name', $AuthorName) | Out-Null
    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'config', 'user.email', $AuthorEmail) | Out-Null

    . (Join-Path $PSScriptRoot 'stats-credential.ps1')
    $token = Get-StatsToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'No stats token is stored. Run .\scripts\set-stats-token.ps1 once from the profile repo.'
    }

    $env:STATS_TOKEN = $token
    Push-Location $RepoRoot
    try {
        Invoke-External -FilePath $nodeCommand.Source -Arguments @('scripts/refresh-stats.mjs') -LogOutput | Out-Null
    }
    finally {
        Pop-Location
        $env:STATS_TOKEN = $previousStatsToken
        $token = $null
    }

    $statusAfter = Get-GitValue @('status', '--porcelain=v1', '--untracked-files=all')
    $changed = @($statusAfter -split "`r?`n" | Where-Object { $_ })
    if ($changed.Count -eq 0) {
        Write-Log 'Stats are unchanged; nothing to commit.'
        exit 0
    }
    if ($changed.Count -ne 1 -or $changed[0] -notmatch 'assets/stats\.svg$') {
        throw "Refusing to commit because files other than assets/stats.svg changed: $($changed -join '; ')"
    }

    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'add', '--', 'assets/stats.svg') | Out-Null
    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'commit', '-m', 'chore: refresh stats card') -LogOutput | Out-Null

    $author = Get-GitValue @('log', '-1', '--format=%an <%ae>')
    if ($author -ne "$AuthorName <$AuthorEmail>") {
        throw "Created commit has unexpected author '$author'. Push was blocked."
    }

    Invoke-External -FilePath $gitCommand.Source -Arguments @('-C', $RepoRoot, 'push', 'origin', "HEAD:$ExpectedBranch") -LogOutput | Out-Null
    $commit = Get-GitValue @('rev-parse', '--short', 'HEAD')
    Write-Log "Refresh complete; pushed commit $commit as $author."
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    if (-not $Scheduled) {
        Write-Host "Log: $LogFile"
    }
    exit 1
}
finally {
    $env:STATS_TOKEN = $previousStatsToken
    $token = $null
    if ($null -ne $lock) {
        try { $lock.ReleaseMutex() } catch { }
        $lock.Dispose()
    }
}
