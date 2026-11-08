<#
.SYNOPSIS
    Lists the members of the SHIPPING game assembly that a built mod DLL binds to directly, flagging the
    ones that are not public (the publicized-assembly trap, SKILL.md §4).

.DESCRIPTION
    Compiles-against-publicized vs runs-against-shipping is the one mismatch a build cannot catch. This
    scans a built DLL's member references, resolves each one against the shipping assembly, and reports
    every reference whose target is not callable from another assembly (member non-public, or its
    declaring type not public).

    Two uses:

      - Pre-release / game-update check: the list IS your private-API surface. Diff it between game
        versions instead of re-reading the whole mod (`dump-api.ps1` tells you what changed; this tells
        you whether you depend on it).
      - Calibration (§4): run it over the released DLLs of the mods you already trust. On Valheim 1.0.21
        every released mod tested binds to private members and works, which is why the rule in §4 is
        "prefer public" and not "private access throws".

    Scoping: only references whose declaring type is scoped to the shipping assembly are checked, so a
    mod's own <PrivateImplementationDetails>::ComputeStringHash (same type name, different assembly) is
    not reported. Nested/internal declaring types are treated as not callable unless every enclosing
    type is public.

.PARAMETER Mod
    Built DLLs and/or directories to scan (required). Directories are searched one level deep for *.dll.

.PARAMETER Shipping
    The unpublicized game assembly to resolve against. Defaults to the Valheim install.

.PARAMETER MaxExamples
    Distinct members printed per DLL (default 10, 0 = all).

.PARAMETER CecilPath
    Mono.Cecil.dll. Defaults to $env:CECIL_PATH, then the JötunnLib package in the NuGet cache.

.PARAMETER NoExitCode
    Always exit 0 (report only). Without it, the script exits 1 when a non-public binding is found, so a
    build can gate on "no new private surface" once the known list is baselined.

.EXAMPLE
    # what does my mod bind to that the shipping assembly does not expose?
    powershell -NoProfile -File scripts/nonpublic-refs.ps1 -Mod .\bin\Release\MyMod.dll

.EXAMPLE
    # calibrate the rule against a profile's released mods
    powershell -NoProfile -File scripts/nonpublic-refs.ps1 -MaxExamples 0 `
        -Mod '<profile>\BepInEx\plugins' -NoExitCode
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Mod,
    [string]$Shipping = 'C:\Program Files (x86)\Steam\steamapps\common\Valheim\valheim_Data\Managed\assembly_valheim.dll',
    [int]$MaxExamples = 10,
    [string]$CecilPath = '',
    [switch]$NoExitCode
)

$ErrorActionPreference = 'Stop'

# ---- locate Mono.Cecil ---------------------------------------------------------
if ($CecilPath -eq '') { $CecilPath = $env:CECIL_PATH }
if (-not $CecilPath -or -not (Test-Path $CecilPath)) {
    $cache = Join-Path $env:USERPROFILE '.nuget\packages\jotunnlib'
    if (Test-Path $cache) {
        $candidate = Get-ChildItem $cache -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'build\Mono.Cecil.dll' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($candidate) { $CecilPath = $candidate }
    }
}
if (-not $CecilPath -or -not (Test-Path $CecilPath)) {
    throw 'Mono.Cecil.dll not found: pass -CecilPath, set $env:CECIL_PATH, or restore the JotunnLib package.'
}
if (-not (Test-Path $Shipping)) { throw "shipping assembly not found: $Shipping" }
Add-Type -Path $CecilPath

# ---- resolve everything the loops need BEFORE looping (SKILL.md §12) -----------
$asmRefType = [Mono.Cecil.AssemblyNameReference]
$typeSpecType = [Mono.Cecil.TypeSpecification]
$methodRefType = [Mono.Cecil.MethodReference]
$fieldRefType = [Mono.Cecil.FieldReference]

function Get-ElementType([Mono.Cecil.TypeReference]$Ref) {
    $t = $Ref
    while ($t -is $typeSpecType) { $t = $t.ElementType }
    return $t
}

function Test-TypeCallable([Mono.Cecil.TypeDefinition]$Def) {
    $t = $Def
    while ($t -ne $null) {
        if ($t.IsNested) {
            if (-not $t.IsNestedPublic) { return $false }
            $t = $t.DeclaringType
        } else {
            return [bool]$t.IsPublic
        }
    }
    return $false
}

function Get-MemberKey([Mono.Cecil.TypeReference]$TypeRef, [string]$Kind, [string]$Name, [int]$ParamCount) {
    $el = Get-ElementType $TypeRef
    if ($Kind -eq 'F') { return "$($el.FullName)::F:$Name" }
    return "$($el.FullName)::M:$Name/$ParamCount"
}

# ---- accessibility map of the shipping assembly --------------------------------
$shipAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Shipping)
$shipName = $shipAsm.Name.Name
$notCallable = New-Object 'System.Collections.Generic.HashSet[string]'
$callable = New-Object 'System.Collections.Generic.HashSet[string]'
try {
    foreach ($t in $shipAsm.MainModule.GetTypes()) {
        $typeOk = Test-TypeCallable $t
        foreach ($f in $t.Fields) {
            $k = "$($t.FullName)::F:$($f.Name)"
            if ($typeOk -and $f.IsPublic) { [void]$callable.Add($k) } else { [void]$notCallable.Add($k) }
        }
        foreach ($m in $t.Methods) {
            $k = "$($t.FullName)::M:$($m.Name)/$($m.Parameters.Count)"
            if ($typeOk -and $m.IsPublic) { [void]$callable.Add($k) } else { [void]$notCallable.Add($k) }
        }
    }
} finally {
    $shipAsm.Dispose()
}
Write-Output "shipping: $shipName ($([System.IO.Path]::GetFileName($Shipping)))"
Write-Output "members: $($callable.Count) callable, $($notCallable.Count) not callable from another assembly"

# ---- expand the -Mod targets ---------------------------------------------------
$dlls = New-Object System.Collections.Generic.List[string]
foreach ($m in $Mod) {
    if (Test-Path -Path $m -PathType Container) {
        Get-ChildItem $m -Filter '*.dll' -File | ForEach-Object { $dlls.Add($_.FullName) }
        Get-ChildItem $m -Filter '*.dll' -File -Recurse -Depth 1 |
            Where-Object { $dlls -notcontains $_.FullName } | ForEach-Object { $dlls.Add($_.FullName) }
    } elseif (Test-Path -Path $m -PathType Leaf) {
        $dlls.Add((Resolve-Path $m).Path)
    } else {
        Write-Warning "skipped (not found): $m"
    }
}
if ($dlls.Count -eq 0) { throw 'no DLL matched -Mod' }

$anyHit = $false
foreach ($dll in $dlls) {
    $modAsm = $null
    try {
        $modAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($dll)
    } catch {
        Write-Output ("`n### {0}: not a managed assembly, skipped" -f [System.IO.Path]::GetFileName($dll))
        continue
    }
    try {
        $hits = New-Object 'System.Collections.Generic.HashSet[string]'
        $refCount = 0
        foreach ($t in $modAsm.MainModule.GetTypes()) {
            foreach ($m in $t.Methods) {
                if (-not $m.HasBody) { continue }
                foreach ($ins in $m.Body.Instructions) {
                    $operand = $ins.Operand
                    $key = $null
                    if ($operand -is $methodRefType) {
                        $declRef = Get-ElementType $operand.DeclaringType
                        if (-not ($declRef.Scope -is $asmRefType)) { continue }
                        if ($declRef.Scope.Name -cne $shipName) { continue }
                        $key = Get-MemberKey $operand.DeclaringType 'M' $operand.Name $operand.Parameters.Count
                    } elseif ($operand -is $fieldRefType) {
                        $declRef2 = Get-ElementType $operand.DeclaringType
                        if (-not ($declRef2.Scope -is $asmRefType)) { continue }
                        if ($declRef2.Scope.Name -cne $shipName) { continue }
                        $key = Get-MemberKey $operand.DeclaringType 'F' $operand.Name 0
                    } else {
                        continue
                    }
                    if ($notCallable.Contains($key)) { $refCount++; [void]$hits.Add($key) }
                }
            }
        }

        if ($hits.Count -eq 0) {
            Write-Output ("`n### {0}: 0 non-public bindings" -f [System.IO.Path]::GetFileName($dll))
            continue
        }

        $anyHit = $true
        $sorted = $hits | Sort-Object
        Write-Output ("`n### {0}: {1} refs to {2} non-public member(s)" -f [System.IO.Path]::GetFileName($dll), $refCount, $hits.Count)
        $shown = $sorted
        if ($MaxExamples -gt 0) { $shown = $sorted | Select-Object -First $MaxExamples }
        foreach ($h in $shown) { Write-Output "    $h" }
        if ($MaxExamples -gt 0 -and $sorted.Count -gt $MaxExamples) {
            Write-Output ("    ... {0} more (pass -MaxExamples 0 for all)" -f ($sorted.Count - $MaxExamples))
        }
    } finally {
        $modAsm.Dispose()
    }
}

if ($anyHit) { Write-Output "`nVerdict: the mod binds to non-public game members - see section 4 of SKILL.md before shipping." }
else { Write-Output "`nVerdict: every game reference resolves to a public member of $shipName." }

if ($anyHit -and -not $NoExitCode) { exit 1 }
exit 0
