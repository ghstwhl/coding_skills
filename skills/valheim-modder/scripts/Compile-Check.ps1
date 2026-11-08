<#
.SYNOPSIS
    Compile a mod's sources into a throwaway SDK-style project when the repo's own build cannot be
    restored on this machine (classic csproj + packages.config + no nuget.exe). SKILL.md §9/§15.

.DESCRIPTION
    Answers exactly one question - "do these sources still compile against these game references?" -
    and prints COMPILE OK / COMPILE FAILED plus the artifact path. It writes nothing into the repo: the
    generated .csproj lives in %TEMP% and `<Compile Include>` points at the repo's sources.

    What it is NOT: the release build. It does not package, does not run the version/changelog
    invariants (`Test-ReleaseInvariants.ps1`), does not check Harmony targets
    (`Test-PatchTargets.ps1`) and does not validate transpiled method bodies. A project's own build
    script remains the only sanctioned way to produce a release; use this when that script cannot run
    (missing `packages\`, no MSBuild/nuget, a machine that only has `dotnet`).

    It references the PUBLICIZED game assembly, because sources that touch private members do not
    compile otherwise - that is why `New-ValheimRefs.ps1` produces one. Compiling proves nothing about
    runtime accessibility, so pair it with `nonpublic-refs.ps1` on the artifact.

.PARAMETER RepoRoot
    The mod repository. Every *.cs under it is compiled, minus bin/obj/.git/packages/.references/Release.

.PARAMETER SourceRoot
    Narrow the compile set to one folder (e.g. `<repo>\MyMod`) instead of the whole repository. Use it
    when the repo also contains a Unity project or a test project that needs its own references.

.PARAMETER Publicized
    assembly_valheim_publicized.dll. Default: the newest
    `<RepoRoot>\.references\Valheim\<version>\assembly_valheim_publicized.dll`.

.PARAMETER GameManaged
    Folder with the Unity modules and the other game assemblies (Assembly-CSharp, assembly_guiutils,
    gui_framework, SoftReferenceableAssets). Default: the same `.references` version, else the install.

.PARAMETER BepInExCore
    BepInEx `core` folder (0Harmony.dll, BepInEx.dll, Mono.Cecil.dll, MonoMod.*). Default: newest
    `<RepoRoot>\.references\BepInEx\<version>\BepInEx\core`.

.PARAMETER ExtraReferences
    Additional DLLs to reference (a hard dependency you compile against, a Jötunn/unity dll that lives
    outside the cache, ...). Paths or globs.

.PARAMETER Keep
    Keep the generated project and its bin/obj for inspection; otherwise the folder is deleted on exit.

.EXAMPLE
    powershell -NoProfile -File scripts/Compile-Check.ps1 -RepoRoot C:\repos\MyMod

.EXAMPLE
    powershell -NoProfile -File scripts/Compile-Check.ps1 -RepoRoot C:\repos\MyMod -SourceRoot C:\repos\MyMod\MyMod `
        -ExtraReferences "$env:USERPROFILE\.nuget\packages\jotunnlib\2.30.2\lib\net462\Jotunn.dll"
#>
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$SourceRoot = '',
    [string]$Publicized = '',
    [string]$GameManaged = '',
    [string]$BepInExCore = '',
    [string[]]$ExtraReferences = @(),
    [string[]]$FrameworkReferences = @('System', 'System.Core', 'System.Xml', 'System.Data', 'System.Configuration', 'System.Web', 'Microsoft.CSharp', 'System.Xml.Linq'),
    [string]$TargetFramework = 'net472',
    [string]$LangVersion = '7.3',
    [string]$WorkDir = '',
    [string]$AssemblyName = 'CompileCheck',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# The repo's own nuget/jotunn packages/*.props import may be referenced from an absolute path; the
# generated project below does not import it, so `packages\` being absent is fine here.
if (-not (Test-Path $RepoRoot)) { throw "repo not found: $RepoRoot" }
$RepoRoot = (Resolve-Path $RepoRoot).Path
if ($SourceRoot -eq '') { $SourceRoot = $RepoRoot }
if (-not (Test-Path $SourceRoot)) { throw "source root not found: $SourceRoot" }
$SourceRoot = (Resolve-Path $SourceRoot).Path

$refsRoot = Join-Path $RepoRoot '.references'

# ---- pick the publicized assembly + the matching Managed/BepInEx sets -----------
if ($Publicized -eq '') {
    $candidate = Get-ChildItem (Join-Path $refsRoot 'Valheim') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'assembly_valheim_publicized.dll' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $candidate) {
        throw "no publicized assembly under $refsRoot\Valheim. Run New-ValheimRefs.ps1 first, or pass -Publicized."
    }
    $Publicized = $candidate
}
if (-not (Test-Path $Publicized)) { throw "publicized assembly not found: $Publicized" }
$versionDir = Split-Path $Publicized -Parent

if ($GameManaged -eq '') {
    $GameManaged = Join-Path $versionDir 'Managed'
    if (-not (Test-Path $GameManaged)) {
        $GameManaged = 'C:\Program Files (x86)\Steam\steamapps\common\Valheim\valheim_Data\Managed'
    }
}
if (-not (Test-Path $GameManaged)) { throw "game Managed folder not found: pass -GameManaged (needs UnityEngine.*Module.dll)" }

if ($BepInExCore -eq '') {
    $candidate2 = Get-ChildItem (Join-Path $refsRoot 'BepInEx') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'BepInEx\core' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $candidate2) { throw "no BepInEx core under $refsRoot\BepInEx. Run New-ValheimRefs.ps1 first, or pass -BepInExCore." }
    $BepInExCore = $candidate2
}

# ---- collect references ---------------------------------------------------------
$referencePaths = New-Object System.Collections.Generic.List[string]
$referencePaths.Add($Publicized)
foreach ($n in 'Assembly-CSharp.dll', 'assembly_utils.dll', 'assembly_guiutils.dll', 'gui_framework.dll', 'SoftReferenceableAssets.dll') {
    $p = Join-Path $GameManaged $n
    if (Test-Path $p) { $referencePaths.Add($p) }
}
Get-ChildItem $GameManaged -Filter 'UnityEngine*.dll' | ForEach-Object { $referencePaths.Add($_.FullName) }
Get-ChildItem $GameManaged -Filter 'Unity.TextMeshPro.dll' -ErrorAction SilentlyContinue | ForEach-Object { $referencePaths.Add($_.FullName) }
Get-ChildItem $BepInExCore -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object { $referencePaths.Add($_.FullName) }
foreach ($extra in $ExtraReferences) {
    $matched = Get-ChildItem $extra -ErrorAction SilentlyContinue
    if ($matched) { foreach ($f in $matched) { $referencePaths.Add($f.FullName) } }
    elseif (Test-Path $extra) { $referencePaths.Add((Resolve-Path $extra).Path) }
    else { throw "extra reference not found: $extra" }
}

# ---- generate the project in %TEMP% --------------------------------------------
if ($WorkDir -eq '') { $WorkDir = Join-Path $env:TEMP ('compile-check-' + [System.IO.Path]::GetFileNameWithoutExtension($AssemblyName) + '-' + $PID) }
if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$exclude = 'bin\**;obj\**;.git\**;packages\**;.references\**;Release\**'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<Project Sdk="Microsoft.NET.Sdk">')
[void]$sb.AppendLine('  <PropertyGroup>')
[void]$sb.AppendLine("    <TargetFramework>$TargetFramework</TargetFramework>")
[void]$sb.AppendLine("    <LangVersion>$LangVersion</LangVersion>")
[void]$sb.AppendLine('    <!-- the repo already has Properties/AssemblyInfo.cs: do not generate a second one -->')
[void]$sb.AppendLine('    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>')
[void]$sb.AppendLine('    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>')
[void]$sb.AppendLine('    <OutputType>Library</OutputType>')
[void]$sb.AppendLine("    <AssemblyName>$AssemblyName</AssemblyName>")
[void]$sb.AppendLine('    <DebugType>none</DebugType>')
[void]$sb.AppendLine('    <NoWarn>CS0618;CS0649;CS0169;CS0414;CS0162;CS0219</NoWarn>')
[void]$sb.AppendLine('  </PropertyGroup>')
[void]$sb.AppendLine('  <ItemGroup>')
[void]$sb.AppendLine(('    <Compile Include="{0}\**\*.cs" Exclude="{0}\{1}" />' -f $SourceRoot, $exclude))
[void]$sb.AppendLine('  </ItemGroup>')
[void]$sb.AppendLine('  <ItemGroup>')
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($r in $referencePaths) {
    $simple = [System.IO.Path]::GetFileNameWithoutExtension($r)
    if (-not $seen.Add($simple)) { continue }
    [void]$sb.AppendLine(('    <Reference Include="{0}"><HintPath>{1}</HintPath><Private>false</Private></Reference>' -f $simple, $r))
}
foreach ($fr in $FrameworkReferences) {
    [void]$sb.AppendLine(('    <Reference Include="{0}" />' -f $fr))
}
[void]$sb.AppendLine('  </ItemGroup>')
[void]$sb.AppendLine('</Project>')

$csproj = Join-Path $WorkDir "$AssemblyName.csproj"
Set-Content -LiteralPath $csproj -Value $sb.ToString() -Encoding UTF8

Write-Output "repo        : $RepoRoot"
Write-Output "sources     : $SourceRoot"
Write-Output "publicized  : $Publicized"
Write-Output "managed     : $GameManaged"
Write-Output "bepinex core: $BepInExCore"
Write-Output "references  : $($seen.Count) assemblies"
Write-Output "project     : $csproj"

# ---- build ---------------------------------------------------------------------
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'dotnet not found on PATH. A CLI installed after the shell started is not on its PATH (SKILL.md §12).' }
& $dotnet.Source build $csproj -c Debug -v q --nologo
$exit = $LASTEXITCODE

$artifact = Join-Path $WorkDir "bin\Debug\$TargetFramework\$AssemblyName.dll"
if ($exit -eq 0) {
    Write-Output ''
    Write-Output 'COMPILE OK'
    Write-Output "artifact: $artifact"
    Write-Output 'Next: verify the artifact, not the source -'
    Write-Output "  cecil.ps1 -Assembly `"$artifact`" -Type <Type> -Method <Method> -IL"
    Write-Output "  nonpublic-refs.ps1 -Mod `"$artifact`""
} else {
    Write-Output ''
    Write-Output 'COMPILE FAILED'
}

if (-not $Keep) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -Confirm:$false }
exit $exit
