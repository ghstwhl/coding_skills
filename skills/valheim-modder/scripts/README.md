# Bundled probes

Eight PowerShell scripts that answer questions about Valheim (and about any BepInEx/HarmonyX mod)
**from artifacts instead of memory**: the game assembly, the installed mod DLLs, the built mod DLL.
They exist because every fact in `../SKILL.md` had to be established this way, and because each one
has a trap that has already cost a working session (§"Traps" below).

They fall into three groups:

| Group | Scripts | Answers |
|---|---|---|
| **IL probes** (need Mono.Cecil) | `cecil.ps1`, `dump-api.ps1`, `Test-PatchTargets.ps1`, `nonpublic-refs.ps1` | what does the code do, is anything left of it, does it still resolve, what private surface does the build bind to |
| **Artifact assertions** (no dependencies) | `strings.ps1`, `Test-ReleaseInvariants.ps1` | is this string in this build, do the version files agree |
| **Build scaffolding** | `New-ValheimRefs.ps1`, `Compile-Check.ps1` | the publicized reference layout a csproj compiles against, and a compile when the repo's own build cannot be restored |

Copy this folder into a mod repo as `tools/`, or call the scripts where they are:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cecil.ps1 -Assembly <dll> -Method <name> -Definitions -Callers
```

## Requirements

- Windows PowerShell 5.1 (no modules, no Python, no Node).
- **Mono.Cecil.dll** for the four IL probes. It is discovered automatically:
  `-CecilPath` → `$env:CECIL_PATH` → `<NuGet cache>\jotunnlib\<ver>\build\Mono.Cecil.dll` →
  `Mono.Cecil.dll` next to the script. You almost certainly already have it: it ships inside the
  JötunnLib NuGet package and in `<Valheim>\BepInEx\core`.
- **AssemblyPublicizer** for `New-ValheimRefs.ps1` only (`-PublicizerPath`, or `-BuildPublicizer`).
- A **`dotnet` SDK** for `Compile-Check.ps1` only (it drives `dotnet build` on a generated project).
- `strings.ps1` and `Test-ReleaseInvariants.ps1` need **nothing** beyond PowerShell.

**Not bundled on purpose: the full build pipeline.** A validated `Build.ps1` (restore → validate →
build → package → zip) belongs to its project, because nearly every line of it is project-specific:
the csproj, the staging folder name, the doc-staging workaround, the packaging paths. What *is*
portable is its shape (`../SKILL.md` §15: one command, a terminal `BUILD OK`/`BUILD FAILED`, a
non-zero exit code, and the version/changelog checks as hard failures) plus the checks themselves —
`Test-ReleaseInvariants.ps1` below is exactly those, so a project can call it from its build script
instead of re-implementing them.

---

## `cecil.ps1` — the workhorse

Prints, for one assembly: method **definitions** (with parameter types, so overloads are
distinguishable), **call sites**, **fields** with access modifiers, and the **IL** of one method on
one type.

```powershell
# who calls ConsumeResources? (call sites)
... cecil.ps1 -Assembly <asm> -Method ConsumeResources -Callers

# overloads + parameter types — always do this when a name has overloads,
# because a name-only call-site scan cannot tell them apart
... cecil.ps1 -Assembly <asm> -Method HaveRequirements -Definitions -Callers

# fields and their real access modifiers (the publicized-assembly trap, SKILL §4)
... cecil.ps1 -Assembly <asm> -Method m_placementStatus -Fields

# IL of ONE method on ONE type — the only way to see ordering (read-before-assign, call order).
# Always pass -Type: without it, a name like Awake matches every type that has an Awake.
... cecil.ps1 -Assembly <asm> -Type Container -Method Awake -IL -MaxLines 200
```

`-Assembly` may be the shipping `assembly_valheim.dll` or the publicized reference copy; use the
shipping one for access modifiers, the publicized one for signatures.

## `dump-api.ps1` — what a game update changed

Dumps every type/member of an assembly to a text file, one line each, so two dumps diff cleanly.

```powershell
... dump-api.ps1 -Assembly <old>\assembly_valheim.dll -OutFile $env:TEMP\old.txt
... dump-api.ps1 -Assembly <new>\assembly_valheim.dll -OutFile $env:TEMP\new.txt

# filter compiler-generated noise first, or the diff is unreadable
Get-Content $env:TEMP\old.txt | Where-Object { $_ -notmatch '<>c|<>c__DisplayClass|g__|b__\d' } | Set-Content $env:TEMP\old.f.txt
Get-Content $env:TEMP\new.txt | Where-Object { $_ -notmatch '<>c|<>c__DisplayClass|g__|b__\d' } | Set-Content $env:TEMP\new.f.txt
Compare-Object (Get-Content $env:TEMP\old.f.txt) (Get-Content $env:TEMP\new.f.txt) -CaseSensitive
```

A signature *or* access change shows up as a removed+added pair, which is why the dump includes
access modifiers and parameter types. Calibrate on a known-small delta first: if the diff is huge,
you dumped two different assemblies (publicized vs not).

## `Test-PatchTargets.ps1` — will the Harmony patches still apply?

Reads the **built mod DLL** and checks, against the reference assemblies, that every
`[HarmonyPatch]` target type exists, still declares a method with the patched name, and that every
`___field` parameter still exists on that type or a base type. Exit code 0/1, one PASS/FAIL per
patch — so it runs in CI straight after a build.

```powershell
... Test-PatchTargets.ps1                     # defaults: <repo>\.references, Directory.Build.props version
... Test-PatchTargets.ps1 -GameVersion 1.0.21 -ModDll .\bin\Release\MyMod.dll
```

It does **not** prove a patched method's *body* is unchanged, which is what a transpiler depends on.
For that, diff the IL with `dump-api.ps1`/`cecil.ps1`. A mod with zero transpilers cannot be broken
by body churn — which is worth knowing about your own mod (SKILL §3).

It reads **both** attribute layouts: a fully-specified `[HarmonyPatch(typeof(X), "Method")]` on the
class, and the bare class attribute with the targets on the methods (the layout SKILL §3.1
recommends). One blind spot remains: a patch whose target is resolved at runtime
(`[HarmonyPrepare]` / `[HarmonyTargetMethod]` for an optional dependency) carries no static
attribute, so it is simply not checked — a PASS count lower than the mod's own
"Harmony patched N method(s)" line is expected, not a failure.

Run it from outside the repo with `-RepoRoot <repo>`; it looks for
`<repo>\<project>\bin\<Release|Debug>\<project>.dll`, so a copy-local `Jotunn.dll` beside the mod
is never mistaken for it. Two players' mods must match versions on a server, so a version bump means
re-running this against the new reference assemblies.

## `New-ValheimRefs.ps1` — the compile-time references

Builds the layout a csproj compiles against: publicized game assemblies, the Unity `Managed` set, and
`BepInEx\core`.

```powershell
... New-ValheimRefs.ps1 -GameVersion 1.0.21 `
    -PublicizerPath .\tools\.cache\publicizer\AssemblyPublicizer\AssemblyPublicizer.exe `
    -BepInExCorePath 'C:\BepInExCore'
```

Parameters: `-ValheimPath`, `-OutputPath` (default `<repo>\.references`, gitignored),
`-GameVersion`, `-BepInExVersion` (default `5.4.2351`), `-BepInExCorePath`, `-PublicizerPath`,
`-BuildPublicizer`, `-Force`.

Output:

```
<OutputPath>\Valheim\<GameVersion>\        publicized game assemblies
<OutputPath>\Valheim\<GameVersion>\Managed\  UnityEngine*, Unity.TextMeshPro, ...
<OutputPath>\BepInEx\<BepInExVersion>\BepInEx\core\   BepInEx.dll, 0Harmony.dll, ...
```

If your csproj also references **another mod's** DLL (a hard dependency you compile against), stage
it yourself into the same root and point the csproj at it — e.g.
`Copy-Item <plugin>\MultiUserChest.dll <OutputPath>\Mods\`. Keep the compiled-against copy and the
runtime copy the same version, or a publicized-vs-shipping mismatch shows up as a runtime
`MissingMethodException` rather than a build error.

**Pass copies, not the live destinations.** Pointing `-BepInExCorePath` at a folder the script is
about to write into makes `Copy-Item` fail with "cannot overwrite ... with itself".

## `nonpublic-refs.ps1` — what private game surface does this build bind to?

The bulk version of the §4 question. Scans a built DLL's member references, resolves each one against
the **shipping** assembly, and prints every reference that is not callable from another assembly
(member non-public, or its declaring type not public).

```powershell
# my build, in full
... nonpublic-refs.ps1 -Mod .\bin\Release\MyMod.dll -MaxExamples 0

# calibrate the rule against released mods that are known to work
... nonpublic-refs.ps1 -Mod '<profile>\BepInEx\plugins' -MaxExamples 0 -NoExitCode
```

Why it exists: `cecil.ps1 -Member X` answers "is *this* member public", but the interesting question is
"what is my whole private-API surface" — that is the list a game update can break, and the list that
makes a mod version-locked. Keep the output of a release; after a game update, re-run it and diff
(`dump-api.ps1` tells you what changed, this tells you whether you depend on it).

Measured on Valheim 1.0.21 over one stock profile: 22 of 29 hand-written mod assemblies bind non-public
members (1–199 references each), Jötunn included — and none of them ship the publicizer's
`SecurityPermission` attribute. That is why §4 says *prefer public, and record what you keep* rather
than *it will throw*. Two calibration rules, both learned the hard way:

- **Only count references whose declaring type is scoped to the game assembly.** A mod's own
  `<PrivateImplementationDetails>::ComputeStringHash` has the same type name the game has, and a scan
  without the scope check reports it as a private game dependency (it did, before the check was added).
- **Treat nested/internal declaring types as not callable** even when the member is `public`; the
  member flag alone is an incomplete check, the same way a field probe without fields is.

Exit code is 1 when anything is found (`-NoExitCode` to always pass), so a build can gate on "no *new*
private surface" once a baseline is accepted.

## `Compile-Check.ps1` — compile when the repo's own build cannot be restored

Classic csproj + `packages.config` needs `nuget.exe`/MSBuild and a populated `packages\`; an agent
machine often has neither, and then "can I still compile this?" has no answer. This generates a
throwaway SDK-style project in `%TEMP%` that compiles the repo's `*.cs` against a `.references`
layout and runs `dotnet build`.

```powershell
... Compile-Check.ps1 -RepoRoot C:\repos\MyMod
... Compile-Check.ps1 -RepoRoot C:\repos\MyMod -SourceRoot C:\repos\MyMod\MyMod `
    -ExtraReferences "$env:USERPROFILE\.nuget\packages\jotunnlib\2.30.2\lib\net462\Jotunn.dll"
```

Defaults: newest `<repo>\.references\Valheim\<ver>\assembly_valheim_publicized.dll`, the `Managed`
folder beside it (or the Steam install), newest `<repo>\.references\BepInEx\<ver>\BepInEx\core`. Pass
`-Keep` to inspect the project and its output; on success it prints `COMPILE OK` and the artifact path
for `cecil.ps1` / `nonpublic-refs.ps1`.

What it deliberately is **not**: the release build. No packaging, no version/manifest invariants, no
Harmony-target check, no transpiler-body check. Its whole output is "the sources bind to these
references and the compiler accepts them" — necessary, never sufficient (§9). Also note it compiles
against the **publicized** assembly, so a successful build says nothing about runtime accessibility:
run `nonpublic-refs.ps1` on the artifact to see what you actually depend on.

## `strings.ps1` — is that literal in this file?

Scans any file for a literal (or regex), ASCII/UTF-8 and UTF-16LE, with the surrounding context and
the byte offset. Exit code 0 if found, 1 if not — so it doubles as an assertion.

```powershell
# did my DLL actually embed the soft-dependency GUID?
... strings.ps1 -Path .\bin\Release\MyMod.dll -Pattern 'ghostwheel.mods.othermod'

# what key names does another mod really read? (SKILL §6: believe the code, not the hover text)
... strings.ps1 -Path "<plugin>\OtherMod.dll" -Pattern '^[A-Z][A-Za-z ]{2,20}$' -Regex -Context 60

# what prefab / RPC names does the game itself use?
... strings.ps1 -Path "<managed>\assembly_valheim.dll" -Pattern 'RequestZDO' -Max 5
```

It exists because some facts are *string* facts and Cecil is the wrong tool: attribute constructor
arguments can print empty from a Cecil probe (see the Traps), and a raw byte scan is decisive and
independent of it. It also never locks a build output, because it reads the file and closes it.

## `Test-ReleaseInvariants.ps1` — do the version files agree?

The portable kernel of a project's build script (SKILL §15), without the build: version constant is
`MAJOR.MINOR.PATCH`, every **tracked** `manifest.json` agrees with it, every `Translations/*.json`
parses, and the changelog's newest `# x.y.z` heading matches. PASS/FAIL per check, exit 0/1.

```powershell
... Test-ReleaseInvariants.ps1 -RepoRoot <repo>
... Test-ReleaseInvariants.ps1 -RepoRoot <repo> -VersionFile .\MyMod\ModInfo.cs -VersionPattern 'Version\s*=\s*"(?<v>[\d.]+)"'
```

Design notes worth keeping if you adapt it:

- **Ask git which manifests are hand-maintained.** `Release\<Team>-<Package>\manifest.json` is build
  output and must not be checked (it is usually gitignored). Without git it recurses, skipping
  `bin`, `obj`, `packages`, `Release`.
- **The git pathspec needs `:(glob)**/manifest.json`.** A bare `manifest.json` pathspec matches the
  repo-root file only, so a second generated manifest is silently never checked - the exact failure
  the tool exists to catch.
- **It validates; it does not build.** Fold the same checks into the real build script so they cannot
  be forgotten, and keep this one for CI and for a one-second check after a version bump.

---

## Traps these scripts exist to avoid

- **A type lookup inside a per-instruction loop floods the terminal.** In PS 5.1 a failed
  `[Mono.Cecil.OperandType]::InlineMethod` (stale type cache after an earlier `Add-Type`) is a
  **non-terminating** error, so an ad-hoc probe emits one multi-line error record per instruction —
  hundreds of thousands — which looks exactly like a hang. It has cost an agent its whole session and
  its uncommitted work. These scripts set `$ErrorActionPreference='Stop'`, resolve every type
  **before** any loop, accumulate into a list and print a bounded summary.
- **`cecil.ps1` without `-Method` prompts interactively** (`Supply values for the following
  parameters: Method:`). Nothing in the output says the shell is now blocked, and the next command
  you send is consumed as the answer. Always pass `-Method` — a name that does not exist is fine and
  prints `(none)`.
- **PowerShell variable names are case-insensitive**, so a local `$definitions` *is* the
  `[switch]$Definitions` parameter and assigning a list to it throws "Cannot convert value ... to
  SwitchParameter". Locals in these scripts are suffixed (`-Lines`).
- **Cecil keeps the file it read open.** Inspecting a *build output* from a long-lived shell leaves
  the DLL locked and the next build fails with MSB3026/MSB3027 "being used by another process". Run
  probes in a child process (`powershell -NoProfile -File ...`) so the handle dies with the child.
- **`String.Split('::')` splits on each character** (it binds `params char[]`): use `-split '::'`.
- **`-eq`/`-like` are case-insensitive** — when measuring overlap between two sources, use `-ceq`.
- **`$module.GetType('SomeType')` silently returns `$null` from PowerShell.** Enumerate instead:
  `$module.GetTypes() | Where-Object { $_.FullName -ceq 'SomeType' }`. A null type in a probe looks
  exactly like "the type was removed from the game".
- **Cecil attribute arguments are unreliable in PowerShell, and failing to read them is not evidence
  of absence.** `$ca.ConstructorArguments[0].Value` can throw "Cannot index into a null array", and a
  `[BepInDependency("guid")]` probe has printed EMPTY ctor args for an attribute that was present in
  the build. Verify strings on the artifact instead (`strings.ps1`); verify structural facts with
  `Test-PatchTargets.ps1`, which reads them the way Harmony does.
- **A path that starts with `.` is not a string literal.** `$r=.references\Valheim\1.0.20\Managed\
  assembly_valheim.dll` makes PowerShell *execute* the path ("No application is associated with...")
  and `$r` stays null, so the next `Test-Path $r` throws. Single-quote it, or use an absolute path.
- **`\"` does not escape a quote inside a PowerShell double-quoted string** (that is C#). Use a
  backtick (`` `" ``) or an outer single-quoted string. This one is invisible until the script parses.
- **Under `Set-StrictMode -Version Latest` a single result has no `.Count`.** `@()` the pipeline
  (`$things = @(Get-ChildItem ... | Where-Object ...)`) or the script dies only on the run where
  exactly one item matched — which is the run you cared about.
- **Editor/linter diagnostics are not a compile check.** "No errors found" has been reported for
  files the compiler then rejected with `CS1503`/`CS7036`. Build (`tools\Build.ps1` or `dotnet
  build`) before believing a green gutter.
- **Never put a destructive cmdlet in a probe.** A diagnostic that included `Remove-Item <dir>`
  without `-Recurse` raised an interactive "Are you sure?" prompt, was auto-answered, and came within
  one file lock of recursively deleting the repository. Probes read; deletion is a separate, explicit
  instruction.
- **A type-constrained parameter silently coerces the assignment.** `[string]$Shipping` and a local
  `$shipping = [Mono.Cecil.AssemblyDefinition]::ReadAssembly(...)` are the *same* variable (names are
  case-insensitive) and the constraint converts the object through `ToString()`, so the assignment
  "works" and the failure surfaces later and elsewhere: `Method invocation failed because
  [System.String] does not contain a method named 'Dispose'`. Same family as the `[switch]` trap above
  — suffix the locals (`$shipAsm`) or rename the parameter.
