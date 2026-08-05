<#
.SYNOPSIS
    Bare-machine entry point. Installs git and node, then hands over to install.mjs.

.DESCRIPTION
    Everything else in this repo is applied by install.mjs, which is a node script in a git
    repository, so it cannot be what puts git and node on a machine that has neither. This
    script is the one piece that runs before them: stock Windows PowerShell, no dependencies,
    nothing to install first.

    Its scope stops there on purpose. It installs the two tools needed to run the installer
    and nothing else; the wider software list belongs to `install.mjs --machine
    --install-software`, which reads it from machine/machine.json.

.PARAMETER DryRun
    Report every step and change nothing.

.PARAMETER Repo
    Deploy from a checkout you already have instead of cloning.

.PARAMETER InstallerArgs
    Everything else is passed through to install.mjs untouched, so `--machine` and friends
    work exactly as documented there.

.EXAMPLE
    .\bootstrap.ps1 -DryRun
    .\bootstrap.ps1
    .\bootstrap.ps1 --machine
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [string] $Repo,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $InstallerArgs
)

$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/baairon/dotfiles'

# Package ids are NOT written here. They live in machine/machine.json, which is the only
# place in this repo allowed to name one, and every id there is verified against winget.
# This script needs two of them before that file can be read, so it looks them up by the
# binary it is trying to provide once a checkout exists, and only falls back to a constant
# when there is no checkout yet to read.
$FallbackIds = @{ git = 'Git.Git'; node = 'OpenJS.NodeJS.LTS' }

function Write-Step {
    param([string] $Message)
    Write-Host "* $Message"
}

function Test-OnPath {
    param([string] $Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $null -ne $cmd
}

# winget writes the new PATH to the registry, not to the environment of the shell that
# called it, so a freshly installed git stays invisible until a new terminal is opened.
# Rebuilding $env:Path from both scopes is what makes install-then-use work in one run.
function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    foreach ($scope in @($machine, $user)) {
        if ($scope) { $parts += $scope.Split(';') }
    }
    $clean = $parts | Where-Object { $_ -ne '' } | Select-Object -Unique
    $env:Path = ($clean -join ';')
}

# The id for a binary, read from the manifest when a checkout is available so that this
# script and the installer can never disagree about what to install.
function Get-PackageId {
    param([string] $Binary, [string] $Checkout)

    if ($Checkout) {
        $manifestPath = Join-Path $Checkout 'machine\machine.json'
        if (Test-Path $manifestPath) {
            try {
                $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($entry in $manifest.software) {
                    if ($entry.detectOnPath -eq $Binary) { return $entry.winget }
                }
            } catch {
                Write-Host "    manifest unreadable, using the built-in id: $($_.Exception.Message)"
            }
        }
    }
    return $FallbackIds[$Binary]
}

function Install-Prerequisite {
    param([string] $Binary, [string] $Checkout)

    if (Test-OnPath $Binary) {
        Write-Step "$Binary already present, skipping"
        return $true
    }

    $id = Get-PackageId -Binary $Binary -Checkout $Checkout
    if (-not $id) {
        Write-Host "    no package id known for $Binary"
        return $false
    }

    if ($DryRun) {
        Write-Step "would install $Binary (winget install --id $id)"
        return $true
    }

    Write-Step "installing $Binary ($id)"
    winget install --id $id --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    Update-PathFromRegistry

    if (Test-OnPath $Binary) {
        Write-Step "$Binary is now on PATH"
        return $true
    }
    # An install can succeed while the binary needs a new session to appear. Say so plainly
    # rather than failing in a way that looks like the install itself broke.
    Write-Host "    $Binary installed but not visible in this session; open a new terminal and re-run"
    return $false
}

Write-Host ''
if ($DryRun) { Write-Host 'dotfiles bootstrap (dry run)' } else { Write-Host 'dotfiles bootstrap' }
Write-Host ''

# A checkout may already be here: this script sits in the repo, so running it from a clone
# means the manifest is readable before anything is installed.
$selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkout = $null
if ($Repo) {
    if (-not (Test-Path $Repo)) { Write-Error "-Repo path not found: $Repo"; exit 1 }
    $checkout = (Resolve-Path $Repo).Path
} elseif (Test-Path (Join-Path $selfDir 'install.mjs')) {
    $checkout = $selfDir
}

if (-not (Test-OnPath 'winget')) {
    Write-Host 'winget is not available on this machine.'
    Write-Host 'It ships with App Installer: https://apps.microsoft.com/detail/9nblggh4nns1'
    Write-Host 'Install that, open a new terminal, and run this again.'
    exit 1
}

$ok = $true
foreach ($binary in @('git', 'node')) {
    if (-not (Install-Prerequisite -Binary $binary -Checkout $checkout)) { $ok = $false }
}
if (-not $ok) {
    Write-Host ''
    Write-Host 'Stopped: the installer needs both git and node.'
    exit 1
}

# Clone only when there is nothing to deploy from. The cache location matches the one the
# dotfiles-setup skill uses, so the two entry points share a checkout instead of keeping
# one each.
if (-not $checkout) {
    $cache = Join-Path $env:LOCALAPPDATA 'dotfiles-cache'
    if (Test-Path (Join-Path $cache '.git')) {
        Write-Step "reusing $cache"
        if (-not $DryRun) {
            git -C $cache pull --ff-only
            if (-not $?) { Write-Host '    offline, using the cached checkout' }
        }
    } else {
        Write-Step "cloning $RepoUrl into $cache"
        if (-not $DryRun) { git clone --depth 1 $RepoUrl $cache }
    }
    $checkout = $cache
}

if ($DryRun -and -not (Test-Path (Join-Path $checkout 'install.mjs'))) {
    Write-Host ''
    Write-Step 'would run: node install.mjs'
    Write-Host ''
    Write-Host 'Dry run complete. Nothing was installed or written.'
    exit 0
}

$installer = Join-Path $checkout 'install.mjs'
if (-not (Test-Path $installer)) { Write-Error "no install.mjs at $installer"; exit 1 }

$forward = @()
if ($InstallerArgs) { $forward += $InstallerArgs }
if ($DryRun) { $forward += '--dry-run' }

Write-Host ''
Write-Step "handing over to $installer"
Write-Host ''
& node $installer --repo $checkout @forward
exit $LASTEXITCODE
