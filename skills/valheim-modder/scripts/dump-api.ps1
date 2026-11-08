# Hardened assembly API dumper: dump a whole assembly's types/members, then diff two dumps to prove
# what a game update changed (follows the hardening rules of cecil.ps1 beside it).
# Resolves every Cecil type BEFORE any loop, fails fast, accumulates into a list, disposes the module.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Assembly,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$CecilPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Mono.Cecil discovery: -CecilPath  >  $env:CECIL_PATH  >  JotunnLib under the NuGet cache  >  next to this script.
function Resolve-CecilPath([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "Mono.Cecil not found at '$ExplicitPath'." }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    if ($env:CECIL_PATH -and (Test-Path -LiteralPath $env:CECIL_PATH)) { return (Resolve-Path -LiteralPath $env:CECIL_PATH).Path }

    $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
    $candidates = @(
        (Join-Path $nugetRoot 'jotunnlib\2.30.2\build\Mono.Cecil.dll'),
        (Join-Path $PSScriptRoot 'Mono.Cecil.dll')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    $packages = Join-Path $nugetRoot 'jotunnlib'
    if (Test-Path -LiteralPath $packages) {
        $found = Get-ChildItem -Path $packages -Filter 'Mono.Cecil.dll' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw 'Mono.Cecil.dll not found. Pass -CecilPath or set $env:CECIL_PATH. Copies live in the JotunnLib package (NuGet cache \jotunnlib\<version>\build\Mono.Cecil.dll) and in <Valheim>\BepInEx\core.'
}

$cecilPath = Resolve-CecilPath $CecilPath
if (-not (Test-Path -LiteralPath $Assembly)) { throw "Assembly not found at $Assembly" }

Add-Type -Path $cecilPath

# Resolve Cecil types once, before any loop (PowerShell can lose the type cache mid-session,
# and a failed type lookup inside a loop body is a NON-terminating error => error flood).
$typeDefType = [Mono.Cecil.TypeDefinition]
if ($null -eq $typeDefType) { throw 'Mono.Cecil.TypeDefinition did not resolve' }

$lines = New-Object System.Collections.Generic.List[string]

$asmDef = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Assembly)
try {
    $pending = New-Object System.Collections.Generic.Stack[Mono.Cecil.TypeDefinition]
    foreach ($topType in $asmDef.MainModule.Types) { $pending.Push($topType) }

    while ($pending.Count -gt 0) {
        $typeDef = $pending.Pop()
        foreach ($nested in $typeDef.NestedTypes) { $pending.Push($nested) }

        $base = ''
        if ($null -ne $typeDef.BaseType) { $base = $typeDef.BaseType.FullName }
        $lines.Add("TYPE|$($typeDef.FullName)|base=$base|$($typeDef.Attributes)")

        foreach ($methodDef in $typeDef.Methods) {
            $paramTypes = ($methodDef.Parameters | ForEach-Object { $_.ParameterType.FullName }) -join ','
            $lines.Add("M|$($typeDef.FullName)::$($methodDef.Name)|($paramTypes)|$($methodDef.ReturnType.FullName)|$($methodDef.Attributes)")
        }
        foreach ($fieldDef in $typeDef.Fields) {
            $lines.Add("F|$($typeDef.FullName)::$($fieldDef.Name)|$($fieldDef.FieldType.FullName)|$($fieldDef.Attributes)")
        }
        foreach ($propDef in $typeDef.Properties) {
            $lines.Add("P|$($typeDef.FullName)::$($propDef.Name)|$($propDef.PropertyType.FullName)|$($propDef.Attributes)")
        }
    }
}
finally {
    if ($null -ne $asmDef) { $asmDef.Dispose() }
}

$sorted = $lines | Sort-Object -Unique
Set-Content -LiteralPath $OutFile -Value $sorted -Encoding UTF8
"$([IO.Path]::GetFileName($Assembly)) -> $([IO.Path]::GetFileName($OutFile)) : $($sorted.Count) member lines"
