<#
.SYNOPSIS
    Finds literal or regex strings in a binary (a DLL, a save, a prefab bundle) without Mono.Cecil.

.DESCRIPTION
    Some facts about an artifact are string facts, and Cecil is the wrong tool for them:

      * Did a `[BepInDependency("other.mod.guid")]` string actually get into my DLL?
        Cecil can read the attribute's constructor arguments, but on some builds they print empty -
        a bad probe, not a bad build. Scanning the bytes is decisive and independent of Cecil.
      * What hotkey does another mod really read? Its key names are string literals near its
        `Input.GetKey` calls (SKILL §6: believe the code, never the hover text).
      * Is this save/bundle/asset the one I think it is? A prefab name or plugin GUID in the bytes
        answers it.

    Scans ASCII and (optionally) UTF-16LE. DotNet attribute and metadata strings are UTF-8, so the
    ASCII pass finds them; Unity serialized data is often UTF-16LE, which is why that pass exists.

.PARAMETER Path
    File to scan. Any file, not just assemblies.

.PARAMETER Pattern
    Text to find. Treated as a literal unless -Regex is given (so '.' and '\' need no escaping).

.PARAMETER Regex
    Treat Pattern as a .NET regular expression.

.PARAMETER Context
    Characters of surrounding text to print with each hit. 0 prints just offsets.

.PARAMETER Max
    Maximum hits printed per encoding (offsets of the rest are summarised).

.PARAMETER NoAscii
    Skip the ASCII pass.

.PARAMETER NoUTF16
    Skip the UTF-16LE pass.

.PARAMETER Quiet
    Print counts only, no context lines. Use in a loop over many files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\strings.ps1 -Path .\bin\Release\MyMod.dll -Pattern 'ghostwheel.mods.'

.EXAMPLE
    # which key names does another mod read?
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\strings.ps1 -Path .\plugins\OtherMod\OtherMod.dll -Pattern '^[A-Z][A-Za-z ]+$' -Regex -Context 0

.NOTES
    Read-only: opens the file for read and closes it. Unlike a Cecil probe it cannot lock a build
    output, because it never memory-maps the file.

    Exit code is 0 when at least one hit was found and 1 when none was, so it can be used as an
    assertion: 'this build really contains this GUID'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [switch]$Regex,
    [int]$Context = 40,
    [int]$Max = 40,
    [switch]$NoAscii,
    [switch]$NoUTF16,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }

$file = Get-Item -LiteralPath $Path
$bytes = [IO.File]::ReadAllBytes($file.FullName)

# A literal pattern must be escaped: PowerShell's -match is case-insensitive, and these scans must be
# case-sensitive, so the match itself is done with [regex] and RegexOptions::None.
$regexPattern = if ($Regex) { $Pattern } else { [regex]::Escape($Pattern) }
$options = [Text.RegularExpressions.RegexOptions]::None

# Display goes to the console (Write-Host); the ONLY thing this function returns is a count, so the
# caller can add results without accidentally concatenating report lines onto a number.
function Scan-Encoding([string]$Text, [string]$Label, [int]$BytesPerChar) {
    $matches = [regex]::Matches($Text, $regexPattern, $options)
    if ($matches.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  $Label : (none)" }
        return 0
    }

    if (-not $Quiet) {
        Write-Host "  $Label : $($matches.Count) hit(s)"
        foreach ($match in ($matches | Select-Object -First $Max)) {
            $offset = $match.Index * $BytesPerChar
            if ($Context -le 0) {
                Write-Host ("    @0x{0:X8}  {1}" -f $offset, $match.Value)
                continue
            }
            $start = [Math]::Max(0, $match.Index - $Context)
            $length = [Math]::Min($Text.Length - $start, $match.Length + (2 * $Context))
            $snippet = ($Text.Substring($start, $length) -replace "[\r\n\t]", ' ')
            Write-Host ("    @0x{0:X8}  {1}" -f $offset, $snippet)
        }
        if ($matches.Count -gt $Max) { Write-Host "    ... ($($matches.Count - $Max) more, raise -Max)" }
    }

    return $matches.Count
}

"Strings in $($file.Name) ($([string]::Format('{0:N0}', $file.Length)) bytes)"
"    Pattern  $regexPattern$(if ($Regex) { '  (regex)' } else { '  (literal)' })"
"    Path     $($file.FullName)"
''

$total = 0
if (-not $NoAscii) { $total += Scan-Encoding ([Text.Encoding]::UTF8.GetString($bytes)) 'ASCII/UTF-8' 1 }
if (-not $NoUTF16) { $total += Scan-Encoding ([Text.Encoding]::Unicode.GetString($bytes)) 'UTF-16LE' 2 }

''
if ($total -eq 0) {
    # Say what an absence means, and what it does not (SKILL §8: include the excluded).
    'No match. A clean absence of a literal is real evidence: the string is not in this file.'
    'But confirm you scanned the right file and the right encoding - a miss in a stale copy of the'
    'assembly proves nothing about the built one.'
    exit 1
}

"Total: $total hit(s)"
exit 0
