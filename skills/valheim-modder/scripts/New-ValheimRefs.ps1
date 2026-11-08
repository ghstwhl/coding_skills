<#
.SYNOPSIS
    Builds the Valheim + BepInEx reference assemblies ("ValheimRefs") that a
    mod project compiles against, using CabbageCrow/AssemblyPublicizer.

.DESCRIPTION
    Produces the exact folder layout the csproj expects under $(ReferencesRoot):

        <OutputPath>\Valheim\<GameVersion>\assembly_*_publicized.dll
        <OutputPath>\Valheim\<GameVersion>\Managed\*.dll
        <OutputPath>\BepInEx\<BepInExVersion>\BepInEx\core\*.dll

    The four Valheim game assemblies are publicized with AssemblyPublicizer so the
    mod can access internal/private members without reflection (the project builds
    with <AllowUnsafeBlocks>true</AllowUnsafeBlocks>).

.PARAMETER ValheimPath
    Path to the Valheim install (the folder that contains Valheim_Data).
    Auto-detected from Steam if omitted.

.PARAMETER OutputPath
    Root folder to write the references into. Defaults to <repo>\.references.
    Point the project at this folder with the MSBuild property ReferencesRoot.

.PARAMETER RepoRoot
    Repository root: used for the default -OutputPath and to read ValheimGameVersion
    from Directory.Build.props. Inferred from the script's parent folder; pass it when
    this script does not live in <repo>\tools\.

.PARAMETER BepInExCorePath
    Folder containing BepInEx.dll, BepInEx.Harmony.dll and 0Harmony.dll.
    Defaults to <ValheimPath>\BepInEx\core when that exists.

.PARAMETER GameVersion
    Valheim version folder name. Defaults to ValheimGameVersion from
    Directory.Build.props (the single source of truth the csproj also uses).

.PARAMETER BepInExVersion
    BepInEx version folder name. Default '5.4.2351' (must match the csproj).

.PARAMETER PublicizerPath
    Path to a prebuilt AssemblyPublicizer.exe. Preferred - see NOTES.

.PARAMETER BuildPublicizer
    Clone and build AssemblyPublicizer from source if no exe can be found.

.PARAMETER Force
    Re-publicize even when the output files already exist.

.EXAMPLE
    .\New-ValheimRefs.ps1 -PublicizerPath C:\tools\AssemblyPublicizer.exe

.EXAMPLE
    .\New-ValheimRefs.ps1 -ValheimPath 'D:\Steam\steamapps\common\Valheim' -BuildPublicizer

.EXAMPLE
    .\New-ValheimRefs.ps1 -OutputPath C:\ValheimRefs -GameVersion 0.217.46

.NOTES
    AssemblyPublicizer (CLI):
        AssemblyPublicizer.exe <inputAssembly> [outputPath]
    Download a release from
        https://github.com/CabbageCrow/AssemblyPublicizer/releases
    and pass it with -PublicizerPath, or use -BuildPublicizer to build from source
    (requires Visual Studio / MSBuild, which you already need for the mod itself).

    This script is NOT affiliated with AssemblyPublicizer. Only publicize
    assemblies you are legally entitled to work with.
#>
[CmdletBinding()]
param(
    [string]$ValheimPath,
    [string]$OutputPath,
    [string]$RepoRoot,
    [string]$BepInExCorePath,
    [string]$GameVersion,
    [string]$BepInExVersion = '5.4.2351',
    [string]$PublicizerPath,
    [switch]$BuildPublicizer,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Bundle-safe repo root: infer it, but never silently fall back to the skill's own folder.
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
if (-not $OutputPath) { $OutputPath = Join-Path $RepoRoot '.references' }

function Get-ConfiguredValheimVersion {
    # Single source of truth is Directory.Build.props (also used by the csproj).
    $propsPath = Join-Path $RepoRoot 'Directory.Build.props'
    if (Test-Path $propsPath) {
        $match = [regex]::Match((Get-Content $propsPath -Raw), '<ValheimGameVersion[^>]*>([^<]+)</ValheimGameVersion>')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
    }

    return $null
}

if (-not $GameVersion) {
    $GameVersion = Get-ConfiguredValheimVersion
    if (-not $GameVersion) { $GameVersion = '1.0.20' }
}

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2{ param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

# Assemblies that get publicized (name without extension).
$GameAssemblies = @(
    'assembly_valheim',
    'assembly_utils',
    'assembly_guiutils',
    'assembly_postprocessing'
)

# BepInEx core assemblies the project references.
$BepInExCoreFiles = @('BepInEx.dll', 'BepInEx.Harmony.dll', '0Harmony.dll')

function Get-ValheimPath {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($hive in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $install = Get-ItemProperty -Path $hive -ErrorAction Stop
            $p = $null
            if ($install.PSObject.Properties['SteamPath']) { $p = $install.SteamPath }
            elseif ($install.PSObject.Properties['InstallPath']) { $p = $install.InstallPath }
            if ($p) { $roots.Add(($p -replace '/', '\')) }
        }
        catch { }
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $text = Get-Content -Raw -Path $vdf
            foreach ($m in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '/', '\' -replace '\\\\', '\'
                if ($lib) { $roots.Add($lib) }
            }
        }
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        $candidate = Join-Path $root 'steamapps\common\Valheim'
        if (Test-Path (Join-Path $candidate 'Valheim_Data\Managed\assembly_valheim.dll')) {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
}

function Get-MSBuildPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($found) { return $found }
    }

    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Resolve-Publicizer {
    param([string]$CacheDir)

    if ($PublicizerPath) {
        if (-not (Test-Path $PublicizerPath)) { throw "AssemblyPublicizer.exe not found at '$PublicizerPath'." }
        return (Resolve-Path $PublicizerPath).Path
    }

    $candidates = @(
        (Join-Path $CacheDir 'AssemblyPublicizer\bin\Release\AssemblyPublicizer.exe'),
        (Join-Path $CacheDir 'AssemblyPublicizer\bin\Debug\AssemblyPublicizer.exe'),
        (Join-Path $CacheDir 'bin\Release\AssemblyPublicizer.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }

    if (-not $BuildPublicizer) {
        throw @"
AssemblyPublicizer.exe could not be found.
  * Download a release from https://github.com/CabbageCrow/AssemblyPublicizer/releases
    and pass it with -PublicizerPath, OR
  * Re-run this script with -BuildPublicizer to clone and build it from source.
"@
    }

    Write-Step "Building AssemblyPublicizer from source"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is required to clone AssemblyPublicizer." }

    $cloneDir = Join-Path $CacheDir 'AssemblyPublicizer'
    if (-not (Test-Path (Join-Path $cloneDir '.git'))) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        & git clone --depth 1 https://github.com/CabbageCrow/AssemblyPublicizer $cloneDir
        if ($LASTEXITCODE -ne 0) { throw "git clone of AssemblyPublicizer failed." }
    }

    $sln = Join-Path $cloneDir 'AssemblyPublicizer.sln'
    $msbuild = Get-MSBuildPath
    if (-not $msbuild) {
        throw "MSBuild was not found. Install Visual Studio (or Build Tools) with the .NET desktop workload."
    }

    $nuget = Get-Command nuget -ErrorAction SilentlyContinue
    if ($nuget) {
        Write-Host "    Restoring packages (nuget restore)..."
        & $nuget.Source restore $sln -Verbosity quiet
    }
    else {
        Write-Warn2 "NuGet CLI not found; relying on MSBuild restore (may fail for packages.config)."
        & $msbuild $sln /t:Restore /nologo /v:minimal
    }

    & $msbuild $sln /p:Configuration=Release /nologo /v:minimal
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed while building AssemblyPublicizer." }

    $exe = Join-Path $cloneDir 'AssemblyPublicizer\bin\Release\AssemblyPublicizer.exe'
    if (-not (Test-Path $exe)) { throw "Build completed but '$exe' was not produced." }
    return (Resolve-Path $exe).Path
}

function Invoke-Publicize {
    param(
        [string]$Publicizer,
        [string]$ManagedDir,
        [string]$AssemblyName,
        [string]$DestinationDir
    )

    $input = Join-Path $ManagedDir "$AssemblyName.dll"
    if (-not (Test-Path $input)) { throw "Missing game assembly: $input" }

    $output = Join-Path $DestinationDir "${AssemblyName}_publicized.dll"
    if ((Test-Path $output) -and -not $Force) {
        Write-Ok "Skipping ${AssemblyName}_publicized.dll (already exists; use -Force to rebuild)"
        return
    }

    Write-Host "    Publicizing $AssemblyName.dll"
    # Run from the Managed folder so Mono.Cecil can resolve sibling dependencies.
    Push-Location $ManagedDir
    try {
        & $Publicizer $input $output | Write-Host
    }
    finally {
        Pop-Location
    }

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) {
        throw "AssemblyPublicizer failed for '$AssemblyName'."
    }
}

# ---------------------------------------------------------------------------

Write-Step 'Locating Valheim'
if (-not $ValheimPath) { $ValheimPath = Get-ValheimPath }
if (-not $ValheimPath) {
    throw "Could not auto-detect Valheim. Pass -ValheimPath 'X:\...\steamapps\common\Valheim'."
}
$ValheimPath = (Resolve-Path $ValheimPath).Path
$Managed = Join-Path $ValheimPath 'Valheim_Data\Managed'
if (-not (Test-Path (Join-Path $Managed 'assembly_valheim.dll'))) {
    throw "'$Managed' does not look like a Valheim Managed folder (assembly_valheim.dll not found)."
}
Write-Ok "Valheim: $ValheimPath"

Write-Step "Preparing output at $OutputPath"
$outValheim = Join-Path $OutputPath "Valheim\$GameVersion"
$outManaged = Join-Path $outValheim 'Managed'
$outBepCore = Join-Path $OutputPath "BepInEx\$BepInExVersion\BepInEx\core"
New-Item -ItemType Directory -Force -Path $outValheim, $outManaged, $outBepCore | Out-Null

Write-Step 'Resolving AssemblyPublicizer'
$cacheDir = Join-Path $PSScriptRoot '.cache'
$publicizer = Resolve-Publicizer -CacheDir $cacheDir
Write-Ok "Publicizer: $publicizer"

Write-Step 'Publicizing Valheim game assemblies'
foreach ($asm in $GameAssemblies) {
    Invoke-Publicize -Publicizer $publicizer -ManagedDir $Managed -AssemblyName $asm -DestinationDir $outValheim
}

Write-Step 'Copying Unity/Managed reference assemblies'
Copy-Item -Path (Join-Path $Managed '*') -Destination $outManaged -Recurse -Force
Write-Ok "Copied Managed\* -> $outManaged"

Write-Step 'Copying BepInEx core assemblies'
if (-not $BepInExCorePath) {
    $defaultBep = Join-Path $ValheimPath 'BepInEx\core'
    if (Test-Path (Join-Path $defaultBep 'BepInEx.dll')) { $BepInExCorePath = $defaultBep }
}
if (-not $BepInExCorePath) {
    throw @"
BepInEx core assemblies were not found.
  * Install BepInEx 5.4.2351 into the Valheim folder, OR
  * Extract them from the 'denikson-BepInExPack_Valheim-5.4.2351' package
    and pass -BepInExCorePath '<folder with BepInEx.dll>'.
"@
}
foreach ($file in $BepInExCoreFiles) {
    $src = Join-Path $BepInExCorePath $file
    if (-not (Test-Path $src)) { throw "Missing BepInEx assembly: $src" }
    Copy-Item -Path $src -Destination $outBepCore -Force
}
Write-Ok "Copied BepInEx core -> $outBepCore"

Write-Host ''
Write-Host 'Reference assemblies are ready.' -ForegroundColor Green
Write-Host ''
Write-Host 'Point the project at them by setting ReferencesRoot, e.g. add a'
Write-Host 'Directory.Build.props at the repo root containing:'
Write-Host ''
Write-Host "  <Project>"
Write-Host "    <PropertyGroup>"
Write-Host "      <ReferencesRoot>$OutputPath</ReferencesRoot>"
Write-Host "    </PropertyGroup>"
Write-Host "  </Project>"
Write-Host ''
Write-Host "Or build from a terminal with:  msbuild <your-solution>.sln /p:ReferencesRoot=`"$OutputPath`""
