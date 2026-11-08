<#
  Hardened Mono.Cecil probe — the ONLY sanctioned way to inspect assemblies in this project.

  WHY THIS EXISTS
  An ad-hoc probe that tests an enum type literal inside a per-instruction loop, e.g.

      if ($i.OpCode.OperandType -eq [Mono.Cecil.OperandType]::InlineMethod) { ... }

  fails with "Unable to find type [Mono.Cecil.OperandType]" when PowerShell's type cache goes stale
  (typically a re-run in a session that already loaded Mono.Cecil). PowerShell treats that as a
  NON-TERMINATING error, so the script does not stop — it emits a multi-line error record for every
  single instruction, tens of thousands of times. That looks exactly like a hang, eats 30-60 minutes,
  floods the terminal, and has cost subagents their entire session and their uncommitted work.

  This script cannot do that. It:
    * fails fast ($ErrorActionPreference = 'Stop') instead of continuing past a type error,
    * resolves every type it needs ONCE, before any loop,
    * accumulates results in a list and prints a bounded summary instead of writing inside hot loops,
    * disposes the module so it never locks a build output.

  USAGE
    # call sites of a method (who calls ConsumeResources?)
    powershell -NoProfile -ExecutionPolicy Bypass -File cecil.ps1 -Assembly <dll> -Method ConsumeResources -Callers

    # definitions (overloads + parameter types — needed to tell overloads apart)
    powershell -NoProfile -ExecutionPolicy Bypass -File cecil.ps1 -Assembly <dll> -Method HaveRequirements -Definitions

    # fields (e.g. confirm Player.m_placementStatus exists and what type it is)
    powershell -NoProfile -ExecutionPolicy Bypass -File cecil.ps1 -Assembly <dll> -Method m_placementStatus -Fields

    # IL of one method on ONE type (the ONLY way to see ordering, e.g. whether a method body reads a
    # field before it is assigned, or calls Instantiate before SetZDO). Always pass -Type when using
    # -IL: without it, a name like Awake matches every type in the assembly that has an Awake.
    powershell -NoProfile -ExecutionPolicy Bypass -File cecil.ps1 -Assembly <dll> -Type Container -Method Awake -IL -MaxLines 200

  ALWAYS pass -Definitions as well as -Callers when a name has overloads: a call-site scan that
  matches on name alone cannot distinguish Player.HaveRequirements(Recipe,...) from
  Player.HaveRequirements(Piece, RequirementMode), and those two behave very differently.

  NOTE ON NAMING: PowerShell variable names are CASE-INSENSITIVE, so a local named $definitions is
  the SAME variable as the [switch]$Definitions parameter, and assigning a List to it throws
  "Cannot convert value ... to type SwitchParameter". Locals here are suffixed -Lines to avoid it.
#>
param(
    [Parameter(Mandatory = $true)][string]$Assembly,
    [Parameter(Mandatory = $true)][string]$Method,
    [switch]$Definitions,
    [switch]$Callers,
    [switch]$Fields,
    [switch]$IL,
    [string]$Type = '',
    [int]$MaxLines = 60,
    [string]$CecilPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Definitions -and -not $Callers -and -not $Fields -and -not $IL) { $Definitions = $true; $Callers = $true }

# Mono.Cecil discovery: this script ships with a skill, so it must not assume one machine's layout.
#   -CecilPath  >  $env:CECIL_PATH  >  JotunnLib under the NuGet cache  >  next to this script.
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

    # Any version of the package, if the pinned one above is not installed.
    $packages = Join-Path $nugetRoot 'jotunnlib'
    if (Test-Path -LiteralPath $packages) {
        $found = Get-ChildItem -Path $packages -Filter 'Mono.Cecil.dll' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw 'Mono.Cecil.dll not found. Pass -CecilPath or set $env:CECIL_PATH. Copies live in the JotunnLib package (NuGet cache \jotunnlib\<version>\build\Mono.Cecil.dll) and in <Valheim>\BepInEx\core.'
}

$cecilPath = Resolve-CecilPath $CecilPath
if (-not (Test-Path -LiteralPath $Assembly)) { throw "Target assembly not found at $Assembly" }

Add-Type -Path $cecilPath

# Resolve the types we need BEFORE any loop. This is the whole point of this script.
$methodRefType = [Mono.Cecil.MethodReference]
if ($null -eq $methodRefType) { throw 'Mono.Cecil.MethodReference did not resolve' }

$asmDef = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Assembly)

$definitionLines = New-Object System.Collections.Generic.List[string]
$callSiteLines = New-Object System.Collections.Generic.List[string]
$fieldLines = New-Object System.Collections.Generic.List[string]
$ilLines = New-Object System.Collections.Generic.List[string]
$scannedMethods = 0
$scannedInstructions = 0

try {
    $pending = New-Object System.Collections.Generic.Stack[Mono.Cecil.TypeDefinition]
    foreach ($topType in $asmDef.MainModule.Types) { $pending.Push($topType) }

    while ($pending.Count -gt 0) {
        $typeDef = $pending.Pop()
        foreach ($nested in $typeDef.NestedTypes) { $pending.Push($nested) }

        # Optional type filter, -ceq and NOT -eq: PowerShell's -eq is case-insensitive, so -eq would
        # also match a differently-cased type and silently dump the wrong type's IL.
        if (-not [string]::IsNullOrEmpty($Type) -and
            -not ($typeDef.Name -ceq $Type) -and -not ($typeDef.FullName -ceq $Type)) { continue }

        if ($Fields) {
            foreach ($fieldDef in $typeDef.Fields) {
                if ($fieldDef.Name -eq $Method) {
                    $modifiers = if ($fieldDef.IsStatic) { 'static ' } else { '' }
                    # Visibility matters for the same reason it does for methods: a field that is only
                    # public in the PUBLICIZED reference must be read through AccessTools.Field, not
                    # directly. The project already reflects a vanilla field (Player.m_placementStatus),
                    # so fields are demonstrably not uniformly public.
                    $fieldAccess = if ($fieldDef.IsPublic) { 'public' }
                        elseif ($fieldDef.IsFamilyOrAssembly) { 'protected internal' }
                        elseif ($fieldDef.IsFamily) { 'protected' }
                        elseif ($fieldDef.IsAssembly) { 'internal' }
                        else { 'private' }
                    $fieldLines.Add("$fieldAccess $($typeDef.Name)::$($fieldDef.Name) : $($modifiers)$($fieldDef.FieldType.Name)")
                }
            }
        }

        foreach ($methodDef in $typeDef.Methods) {
            if ($methodDef.Name -eq $Method) {
                $paramTypes = ($methodDef.Parameters | ForEach-Object { $_.ParameterType.Name }) -join ', '
                # Visibility matters: this project may only call members that are PUBLIC in the
                # UNPUBLICIZED assembly directly. Non-public members must go through
                # AccessTools/reflection, because the publicized reference binds them at compile time
                # while the shipping assembly does not expose them - build and tests stay green and the
                # call fails or throws only at runtime.
                $access = if ($methodDef.IsPublic) { 'public' }
                    elseif ($methodDef.IsFamilyOrAssembly) { 'protected internal' }
                    elseif ($methodDef.IsFamily) { 'protected' }
                    elseif ($methodDef.IsAssembly) { 'internal' }
                    else { 'private' }
                $definitionLines.Add("$access $($typeDef.Name)::$($methodDef.Name)($paramTypes) : $($methodDef.ReturnType.Name)")

                # IL dump: the instruction ORDER is the whole point (e.g. does a body instantiate
                # before it assigns the ZDO?), which neither -Definitions nor -Callers can show.
                if ($IL -and $methodDef.HasBody) {
                    $ilLines.Add("---- $($typeDef.FullName)::$($methodDef.Name) ----")
                    foreach ($localVar in $methodDef.Body.Variables) {
                        $ilLines.Add("  .local [$($localVar.Index)] $($localVar.VariableType.Name)")
                    }
                    foreach ($ins in $methodDef.Body.Instructions) {
                        $ilLines.Add('  ' + ('{0:X4}' -f $ins.Offset) + '  ' + $ins.OpCode.Name + ' ' + $ins.Operand)
                    }
                }
            }

            if (-not $Callers) { continue }
            if (-not $methodDef.HasBody) { continue }
            $scannedMethods++

            foreach ($ins in $methodDef.Body.Instructions) {
                $scannedInstructions++
                $operand = $ins.Operand
                if ($operand -is $methodRefType) {
                    if ($operand.Name -eq $Method) {
                        $operandParamTypes = ($operand.Parameters | ForEach-Object { $_.ParameterType.Name }) -join ', '
                        $callSiteLines.Add("$($typeDef.Name)::$($methodDef.Name) -> $($operand.DeclaringType.Name)::$($operand.Name)($operandParamTypes)")
                    }
                }
            }
        }
    }
}
finally {
    # ReadAssembly holds the file stream open; not disposing can lock a build output (MSB3026).
    if ($null -ne $asmDef) { $asmDef.Dispose() }
}

if ($Fields) {
    "==== fields named $Method ===="
    if ($fieldLines.Count -eq 0) { "  (none)" }
    else { $fieldLines | Sort-Object -Unique | Select-Object -First $MaxLines }
}

if ($IL) {
    "==== IL of $Method ===="
    if ($ilLines.Count -eq 0) { "  (none)" }
    else {
        $ilLines | Select-Object -First $MaxLines
        if ($ilLines.Count -gt $MaxLines) { "  ... ($($ilLines.Count - $MaxLines) more lines, raise -MaxLines)" }
    }
}

if ($Definitions) {
    "==== definitions of $Method ===="
    if ($definitionLines.Count -eq 0) { "  (none)" }
    else { $definitionLines | Sort-Object -Unique | Select-Object -First $MaxLines }
}

if ($Callers) {
    "==== call sites of $Method ===="
    if ($callSiteLines.Count -eq 0) { "  (none)" }
    else { $callSiteLines | Sort-Object -Unique | Select-Object -First $MaxLines }
    "==== scanned $scannedMethods methods / $scannedInstructions instructions ===="
}
