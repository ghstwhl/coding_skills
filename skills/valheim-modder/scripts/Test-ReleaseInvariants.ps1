<#
.SYNOPSIS
    Fails when a mod's release identities disagree: version constant vs every manifest vs the changelog.

.DESCRIPTION
    The cheapest defect a mod can ship is a release where the code, the package manifest and the
    changelog name different versions. A player then cannot say which build they are running, and a
    "published version is immutable" rule becomes unfalsifiable.

    This is the portable kernel of a project's build script (SKILL §15): it validates, and does not
    build. Run it:
      * before a release build, so a mismatch stops you,
      * straight after a version bump, because it takes a second,
      * in CI, because it needs nothing but PowerShell.

    Checks, each PASS/FAIL:
      1. The version constant reads as MAJOR.MINOR.PATCH.
      2. Every manifest.json that carries a version_number agrees with it.
      3. Every manifest.json and every Translations JSON parses.
      4. The changelog's newest '# x.y.z' entry equals it (when a changelog is present).

    Exit code 0 when every check passes, 1 otherwise.

.PARAMETER RepoRoot
    Repository root. Inferred from the script's parent folder, and only accepted when that folder
    looks like a repository (has .git, Directory.Build.props or a .sln). Pass it explicitly when this
    script does not live in <repo>\tools\.

.PARAMETER VersionFile
    File holding the single version constant. Default: the only *\ModInfo.cs (or ModInfo.cs) that
    declares 'const string Version'.

.PARAMETER VersionPattern
    Regex with one capture group for the version. Default matches 'Version = "x.y.z"'.

.PARAMETER Manifest
    Manifest files to check. Default: every manifest.json tracked by git (so build output such as
    Release\<Team>-<Package>\manifest.json is ignored); without git, every manifest.json outside
    bin/obj/packages/Release.

.PARAMETER Changelog
    Changelog to check. Default: <repo>\CHANGELOG.md when it exists.

.PARAMETER SkipChangelog
    Do not check the changelog (e.g. the project keeps release notes elsewhere).

.PARAMETER SkipJson
    Do not parse Translations JSON files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseInvariants.ps1 -RepoRoot C:\Repos\MyMod

.NOTES
    Deliberately build-free and write-free: it reads, reports, and exits. Nothing it does can make a
    working tree dirty.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$VersionFile,
    [string]$VersionPattern = 'Version\s*=\s*"(?<v>\d+\.\d+\.\d+)"',
    [string[]]$Manifest,
    [string]$Changelog,
    [switch]$SkipChangelog,
    [switch]$SkipJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Bundle-safe repo root (this script ships inside a skill, so its parent is NOT a repository).
function Resolve-RepoRoot([string]$ExplicitPath) {
    if ($ExplicitPath) { return (Resolve-Path -LiteralPath $ExplicitPath).Path }
    $candidate = Split-Path -Parent $PSScriptRoot
    if ((Test-Path (Join-Path $candidate '.git')) -or
        (Test-Path (Join-Path $candidate 'Directory.Build.props')) -or
        (Get-ChildItem -Path $candidate -Filter '*.sln' -File -ErrorAction SilentlyContinue)) {
        return $candidate
    }
    throw "Cannot infer the repository root from '$PSScriptRoot'. Pass -RepoRoot, or copy this script into <repo>\tools\ (SKILL §0)."
}

$RepoRoot = Resolve-RepoRoot $RepoRoot

$failures = 0
$checks = 0
function Pass([string]$Message) { $script:checks++; Write-Host "PASS  $Message" }
function Fail([string]$Message) { $script:checks++; $script:failures++; Write-Host "FAIL  $Message" }
function Info([string]$Message) { Write-Host "      $Message" -ForegroundColor DarkGray }

$skipDirs = @('bin', 'obj', 'packages', '.git', '.references', 'node_modules')

function Get-TrackedFiles([string]$Name) {
    # Prefer git: it knows which manifest.json files are hand-maintained and which are build output.
    # The pathspec needs the :(glob)**/ form - a bare 'manifest.json' matches the repo-root file only.
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path (Join-Path $RepoRoot '.git'))) {
        $tracked = & $git.Source -C $RepoRoot ls-files -- ":(glob)**/$Name" $Name 2>$null
        if ($LASTEXITCODE -eq 0) { return @($tracked | Where-Object { $_ }) }
    }

    $found = Get-ChildItem -Path $RepoRoot -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
        Where-Object {
            $relative = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            $segments = $relative -split '[\\/]'
            -not ($segments | Where-Object { $skipDirs -contains $_ })
        }
    return @($found | ForEach-Object { $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') })
}

Write-Host "Release invariants"
Write-Host "    Repo root   $RepoRoot"
Write-Host ""

# ---- 1. the version constant ----------------------------------------------------------------
if (-not $VersionFile) {
    # @() matters: under Set-StrictMode a single result has no .Count.
    $candidates = @(Get-ChildItem -Path $RepoRoot -Recurse -Filter 'ModInfo.cs' -File -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Raw) -match $VersionPattern -and
            -not ((($_.FullName.Substring($RepoRoot.Length) -split '[\\/]') | Where-Object { $skipDirs -contains $_ })) })
    if ($candidates.Count -eq 1) { $VersionFile = $candidates[0].FullName }
    elseif ($candidates.Count -eq 0) { throw "No file declaring a version constant was found under $RepoRoot. Pass -VersionFile, and -VersionPattern if the declaration is not Version = 'x.y.z'." }
    else { throw "More than one version constant file found:`n  $($candidates.FullName -join "`n  ")`nPass -VersionFile." }
}
if (-not (Test-Path -LiteralPath $VersionFile)) { throw "Version file not found: $VersionFile" }

$versionMatch = [regex]::Match((Get-Content -LiteralPath $VersionFile -Raw), $VersionPattern)
if (-not $versionMatch.Success) { throw "Version pattern '$VersionPattern' did not match in '$VersionFile'. Pass the pattern that captures your version constant." }

$version = $versionMatch.Groups['v'].Value
if ($version -notmatch '^\d+\.\d+\.\d+$') { Fail "version '$version' is not MAJOR.MINOR.PATCH ($VersionFile)" }
else { Pass "version constant = $version ($([IO.Path]::GetFileName($VersionFile)))" }

# ---- 2. manifests ----------------------------------------------------------------------------
if (-not $Manifest) { $Manifest = Get-TrackedFiles 'manifest.json' }
if ($Manifest.Count -eq 0) {
    Fail 'no manifest.json found - a Thunderstore/Vortex package needs one (SKILL §10)'
}

$parsedManifests = @()
foreach ($relative in $Manifest) {
    $path = if ([IO.Path]::IsPathRooted($relative)) { $relative } else { Join-Path $RepoRoot $relative }
    if (-not (Test-Path -LiteralPath $path)) { Fail "manifest listed but missing: $relative"; continue }

    try { $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { Fail "invalid JSON: $relative -> $($_.Exception.Message)"; continue }

    $parsedManifests += , $path
    $property = $json.PSObject.Properties['version_number']
    if ($null -eq $property) { Info "no version_number in $relative (skipped)"; continue }
    if ([string]$property.Value -cne $version) {
        Fail "$relative version_number '$($property.Value)' != version constant '$version' - bump them together"
    }
    else { Pass "$relative version_number = $version" }
}

# ---- 3. JSON data files ----------------------------------------------------------------------
if (-not $SkipJson) {
    $jsonFiles = @()
    $translationDirs = @(Get-ChildItem -Path $RepoRoot -Recurse -Directory -Filter 'Translations' -ErrorAction SilentlyContinue |
        Where-Object { -not ((($_.FullName.Substring($RepoRoot.Length) -split '[\\/]') | Where-Object { $skipDirs -contains $_ })) })
    foreach ($dir in $translationDirs) {
        $jsonFiles += Get-ChildItem -Path $dir.FullName -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue
    }
    foreach ($file in $jsonFiles) {
        try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json | Out-Null }
        catch { Fail "invalid JSON: $($file.FullName) -> $($_.Exception.Message)" }
    }
    if ($jsonFiles.Count -gt 0) { Pass "JSON parses ($($jsonFiles.Count) file(s) under Translations)" }
}

# ---- 4. changelog ----------------------------------------------------------------------------
if (-not $SkipChangelog) {
    if (-not $Changelog) {
        $rootChangelog = Join-Path $RepoRoot 'CHANGELOG.md'
        if (Test-Path -LiteralPath $rootChangelog) { $Changelog = $rootChangelog }
    }
    if ($Changelog) {
        $heading = Select-String -LiteralPath $Changelog -Pattern '^#\s+(?<v>\d+\.\d+\.\d+)' | Select-Object -First 1
        if (-not $heading) { Fail "no '# x.y.z' heading found in $Changelog" }
        elseif ($heading.Matches[0].Groups['v'].Value -cne $version) {
            Fail "newest changelog entry is '$($heading.Matches[0].Groups['v'].Value)' in $([IO.Path]::GetFileName($Changelog)), version constant is '$version'"
        }
        else { Pass "changelog top entry = $version ($([IO.Path]::GetFileName($Changelog)))" }
    }
    else { Info 'no CHANGELOG.md at the repo root (skipped; pass -Changelog or -SkipChangelog)' }
}

# ---- summary ---------------------------------------------------------------------------------
Write-Host ''
if ($failures -gt 0) {
    Write-Host "INVARIANTS FAILED - $failures of $checks check(s)" -ForegroundColor Red
    exit 1
}
Write-Host "INVARIANTS OK - $checks check(s), version $version" -ForegroundColor Green
exit 0
