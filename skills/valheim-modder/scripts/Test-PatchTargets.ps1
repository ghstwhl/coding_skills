<#
.SYNOPSIS
    Verifies that every Harmony patch this mod ships still applies to the Valheim
    assemblies the build targets.

.DESCRIPTION
    A game patch can break a BepInEx mod without breaking its build: a patch target
    renamed or removed, a field the patch receives by name (`___field`) renamed, or
    the body of a method a transpiler pattern-matches changed underneath it. This
    script reads the built mod assembly with Mono.Cecil and checks, against the
    reference assemblies, that:

      1. every `[HarmonyPatch]` target type still exists in the game assemblies,
      2. it still declares at least one method with the patched name, and
      3. every `___field` parameter a patch method asks Harmony to inject still
         exists on that type (or one of its base types).

    It needs no game install, no Unity and no BepInEx runtime, so it can run in CI
    right after a build. It does NOT prove that a patched method's body is unchanged,
    which is what a transpiler cares about - compare the IL with Mono.Cecil for that
    (see `tools/README.md`).

.PARAMETER ReferencesRoot
    Folder holding the publicized reference assemblies. Defaults to
    `<repo>\.references`, or the ReferencesRoot environment variable.

.PARAMETER GameVersion
    Valheim version folder to check against. Defaults to ValheimGameVersion from
    Directory.Build.props (the single source of truth).

.PARAMETER ModDll
    Built mod assembly to check. Defaults to the newest non-test DLL under
    <repo>\*\bin\Release, then \Debug.

.PARAMETER RepoRoot
    Repository root: used to find .references, Directory.Build.props and the built
    DLL. Inferred from the script's parent folder; pass it when this script does not
    live in <repo>\tools\.

.PARAMETER CecilPath
    Path to Mono.Cecil.dll. Defaults to the copy restored with the JotunnLib package.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Test-PatchTargets.ps1

.OUTPUTS
    One `PASS`/`FAIL` line per patch, a summary, and exit code 0 (all applied) or
    1 (at least one would fail to apply at runtime).
#>
[CmdletBinding()]
param(
    [string]$ReferencesRoot,
    [string]$GameVersion,
    [string]$ModDll,
    [string]$CecilPath,
    [string]$RepoRoot
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

function Get-ConfiguredValheimVersion {
    $propsPath = Join-Path $RepoRoot 'Directory.Build.props'
    if (Test-Path $propsPath) {
        $match = [regex]::Match((Get-Content $propsPath -Raw), '<ValheimGameVersion[^>]*>([^<]+)</ValheimGameVersion>')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
    }
    return $null
}

if (-not $ReferencesRoot) { $ReferencesRoot = $env:ReferencesRoot }
if (-not $ReferencesRoot) { $ReferencesRoot = Join-Path $RepoRoot '.references' }
if (-not $GameVersion) { $GameVersion = Get-ConfiguredValheimVersion }
if (-not $GameVersion) { throw "Could not determine the Valheim version - pass -GameVersion." }

if (-not $ModDll) {
    # Heuristic: a mod repo builds <project>\bin\<config>\<project>.dll. The name must match the
    # project folder, so a copy-local reference beside it (Jotunn.dll, assembly_*_publicized.dll,
    # 0Harmony.dll, the BCL facade DLLs) is never mistaken for the mod.
    foreach ($configuration in @('Release', 'Debug')) {
        $bins = Get-ChildItem -Path $RepoRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "bin\$configuration" } |
            Where-Object { Test-Path -LiteralPath $_ }
        foreach ($bin in $bins) {
            $project = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $bin))
            $match = Get-ChildItem -Path $bin -Filter "$project.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { $ModDll = $match.FullName; break }
        }
        if ($ModDll) { break }
    }
}
if (-not $ModDll -or -not (Test-Path $ModDll)) {
    throw "Mod assembly not found. The default looks for '<project>\bin\<Release|Debug>\<project>.dll' under $RepoRoot - build it first, or pass -ModDll."
}

if (-not $CecilPath -and $env:CECIL_PATH -and (Test-Path $env:CECIL_PATH)) { $CecilPath = $env:CECIL_PATH }
if (-not $CecilPath) {
    $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
    foreach ($candidate in @(
            (Join-Path $RepoRoot 'packages\JotunnLib.2.30.2\build\Mono.Cecil.dll'),
            (Join-Path $RepoRoot 'tools\.cache\publicizer\AssemblyPublicizer\Mono.Cecil.dll'),
            (Join-Path $nugetRoot 'jotunnlib\2.30.2\build\Mono.Cecil.dll'),
            (Join-Path $PSScriptRoot 'Mono.Cecil.dll')
        )) {
        if (Test-Path $candidate) { $CecilPath = $candidate; break }
    }
}
if (-not $CecilPath -or -not (Test-Path $CecilPath)) { throw "Mono.Cecil.dll not found - pass -CecilPath." }

Add-Type -Path (Resolve-Path $CecilPath).Path

$gameDir = Join-Path $ReferencesRoot "Valheim\$GameVersion"
if (-not (Test-Path $gameDir)) { throw "Reference assemblies for Valheim $GameVersion not found at '$gameDir'. Run tools/New-ValheimRefs.ps1." }

# The assemblies a patch may target: the publicized game assemblies plus the Unity
# UI module (UnityEngine.UI.Dropdown is patched directly).
$gameAssemblies = New-Object 'System.Collections.Generic.List[string]'
foreach ($name in @('assembly_valheim', 'assembly_utils', 'assembly_guiutils', 'assembly_postprocessing')) {
    $p = Join-Path $gameDir "${name}_publicized.dll"
    if (Test-Path $p) { $gameAssemblies.Add($p) }
}
foreach ($name in @('UnityEngine.UI.dll', 'UnityEngine.CoreModule.dll', 'UnityEngine.dll')) {
    $p = Join-Path $gameDir "Managed\$name"
    if (Test-Path $p) { $gameAssemblies.Add($p) }
}

# typeFullName -> TypeDefinition, so a patch target can be resolved by name across
# all of the game assemblies (the mod never names the assembly, only the type).
$types = @{}
$modules = New-Object 'System.Collections.Generic.List[object]'
foreach ($path in $gameAssemblies) {
    $asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($path)
    $modules.Add($asm)
    foreach ($t in $asm.MainModule.GetTypes()) {
        if (-not $types.ContainsKey($t.FullName)) { $types[$t.FullName] = $t }
    }
}

function Find-Field {
    param($TypeDefinition, [string]$Name)
    $t = $TypeDefinition
    while ($null -ne $t) {
        foreach ($f in $t.Fields) { if ($f.Name -ceq $Name) { return $f } }
        if ($null -eq $t.BaseType) { break }
        $t = if ($types.ContainsKey($t.BaseType.FullName)) { $types[$t.BaseType.FullName] } else { $null }
    }
    return $null
}

# Parses one [HarmonyPatch] attribute into its target type, patched method name and argument types.
function Read-PatchArgs($Attribute) {
    $target = $null; $patchMethod = $null; $argTypes = @()
    foreach ($arg in $Attribute.ConstructorArguments) {
        $argTypeName = $arg.Type.FullName
        if ($argTypeName -ceq 'System.Type') {
            if ($null -eq $target) { $target = $arg.Value.FullName }
        }
        elseif ($argTypeName -ceq 'System.String') {
            if ($null -eq $patchMethod) { $patchMethod = [string]$arg.Value }
        }
        elseif ($argTypeName -ceq 'System.Type[]') {
            foreach ($element in $arg.Value) { $argTypes += $element.Value.FullName }
        }
    }
    return [pscustomobject]@{ Target = $target; Method = $patchMethod; ArgTypes = $argTypes }
}

$mod = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($ModDll)
$failures = 0
$checks = 0

try {
    Write-Host "Patch-target check (Harmony target / method / ___field resolution)"
    Write-Host "    Mod DLL     $ModDll"
    Write-Host "    References  $gameDir"
    Write-Host ""

    foreach ($type in $mod.MainModule.GetTypes()) {
        # A patch class carries [HarmonyPatch] on the type, on its methods, or both. Harmony supports
        # a BARE class attribute with the real targets on the methods (SKILL §3.1 recommends exactly
        # that), so a checker that only reads the type attribute reports false failures.
        $classTarget = $null; $classMethod = $null; $classArgTypes = @()
        foreach ($ca in $type.CustomAttributes) {
            if ($ca.AttributeType.FullName -cne 'HarmonyLib.HarmonyPatch') { continue }
            $parsed = Read-PatchArgs $ca
            if ($parsed.Target -and -not $classTarget) { $classTarget = $parsed.Target }
            if ($parsed.Method -and -not $classMethod) { $classMethod = $parsed.Method }
            if ($parsed.ArgTypes.Count -gt 0 -and $classArgTypes.Count -eq 0) { $classArgTypes = $parsed.ArgTypes }
        }

        $declarations = New-Object System.Collections.Generic.List[object]
        foreach ($method in $type.Methods) {
            foreach ($ca in $method.CustomAttributes) {
                if ($ca.AttributeType.FullName -cne 'HarmonyLib.HarmonyPatch') { continue }
                $parsed = Read-PatchArgs $ca
                # A method attribute may carry only the method name; the type comes from the class.
                $dTarget = if ($parsed.Target) { $parsed.Target } else { $classTarget }
                $dMethod = if ($parsed.Method) { $parsed.Method } else { $classMethod }
                $dArgs = if ($parsed.ArgTypes.Count -gt 0) { $parsed.ArgTypes } else { $classArgTypes }
                $declarations.Add([pscustomobject]@{
                        Target = $dTarget; Method = $dMethod; ArgTypes = $dArgs
                        Owner = $method; Label = "$($type.Name).$($method.Name)"
                    })
            }
        }
        if ($declarations.Count -eq 0) {
            if (-not $classTarget) { continue }   # not a patch class at all
            $declarations.Add([pscustomobject]@{
                    Target = $classTarget; Method = $classMethod; ArgTypes = $classArgTypes
                    Owner = $null; Label = $type.Name
                })
        }

        foreach ($declaration in $declarations) {
            $targetName = $declaration.Target
            $methodName = $declaration.Method
            $argTypes = @($declaration.ArgTypes)
            $label = $declaration.Label

            if (-not $targetName) {
                Write-Host ("FAIL  {0}: no target type in [HarmonyPatch]" -f $label)
                $failures++
                continue
            }

            $target = if ($types.ContainsKey($targetName)) { $types[$targetName] } else { $null }
            if ($null -eq $target) {
                Write-Host ("FAIL  {0}: target type '{1}' no longer exists" -f $label, $targetName)
                $failures++
                continue
            }

            $checks++
            $shape = "$targetName"
            if ($methodName) { $shape += "::$methodName" }
            if ($argTypes.Count -gt 0) { $shape += "(" + ($argTypes -join ',') + ")" }

            if ($methodName) {
                $methods = @($target.Methods | Where-Object { $_.Name -ceq $methodName })
                if ($methods.Count -eq 0) {
                    Write-Host ("FAIL  {0}: {1} - no method named '{2}'" -f $label, $shape, $methodName)
                    $failures++
                    continue
                }
                if ($argTypes.Count -gt 0) {
                    $exact = @($methods | Where-Object {
                            $params = @($_.Parameters | ForEach-Object { $_.ParameterType.FullName })
                            ($params -join ',') -ceq ($argTypes -join ',')
                        })
                    if ($exact.Count -eq 0) {
                        Write-Host ("FAIL  {0}: {1} - no overload with the patched parameter types" -f $label, $shape)
                        $failures++
                        continue
                    }
                }
            }

            # Fields Harmony injects by naming convention: ___field. Check the methods of THIS
            # declaration only, otherwise every method in the class is checked against one target.
            $methodsToScan = if ($null -ne $declaration.Owner) { @($declaration.Owner) } else { @($type.Methods) }
            $missingFields = @()
            foreach ($method in $methodsToScan) {
                foreach ($param in $method.Parameters) {
                    if ($param.Name -like '___*') {
                        $fieldName = $param.Name.Substring(3)
                        if ($null -eq (Find-Field -TypeDefinition $target -Name $fieldName)) { $missingFields += $fieldName }
                    }
                }
            }
            if ($missingFields.Count -gt 0) {
                Write-Host ("FAIL  {0}: {1} - injected field(s) missing: {2}" -f $label, $shape, ($missingFields -join ','))
                $failures++
                continue
            }

            Write-Host ("PASS  {0}: {1}" -f $label, $shape)
        }
    }
}
finally {
    $mod.Dispose()
    foreach ($m in $modules) { $m.Dispose() }
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host ("PATCH TARGETS FAILED - {0} of {1} patch classes would not apply." -f $failures, $checks)
    exit 1
}
Write-Host ("PATCH TARGETS OK - all {0} patch classes resolve against Valheim {1}." -f $checks, $GameVersion)
exit 0
