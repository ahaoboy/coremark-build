# Build a native Windows CoreMark binary with the MSVC toolchain (cl.exe).
#
# CI only has to run:
#
#     ./build-msvc.ps1
#
# The script finds Visual Studio through vswhere and imports the MSVC
# environment itself, so no "set up MSVC" action is required.
#
# Environment overrides (also available as parameters):
#   TARGET        package label (default x86_64-pc-windows-msvc)
#   COREMARK_REF  coremark git ref (default main)
#   ITERATIONS    CoreMark iterations define (default 0 = auto)
#   VCVARS_PATH   explicit path to vcvars64.bat (skips Visual Studio detection)

[CmdletBinding()]
param(
    [string]$Target = $(if ($env:TARGET) { $env:TARGET } else { 'x86_64-pc-windows-msvc' }),
    [string]$CoreMarkRef = $(if ($env:COREMARK_REF) { $env:COREMARK_REF } else { 'main' }),
    [int]$Iterations = $(if ($env:ITERATIONS) { [int]$env:ITERATIONS } else { 0 }),
    [string]$VcVarsPath = $env:VCVARS_PATH
)

$ErrorActionPreference = 'Stop'

$RootDir = $PSScriptRoot

# CoreMark prints this in its report; keep it space free.
$compilerFlags = 'cl-O2-MT'

$CoreMarkDir = Join-Path $RootDir '.coremark'
$DistDir = Join-Path $RootDir 'dist'

# The executable inside the archive is always named "coremark"; the archive and
# checksum file carry the target label.
$BinaryName = 'coremark.exe'
$PackageName = "coremark-$Target"

$Binary = Join-Path $DistDir $BinaryName
$Zip = Join-Path $RootDir "$PackageName.zip"
$ShaFile = Join-Path $RootDir "$PackageName.sha256"

# Scratch space for the helper .bat and cl's response file.
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "coremark-msvc-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    throw 'build-msvc.ps1 must run on Windows'
}

# ------------------------------------------------------------
# Locate and import the MSVC environment
# ------------------------------------------------------------

function Find-VcVars {
    param([string]$Explicit)

    if ($Explicit) {
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -find 'VC/Auxiliary/Build/vcvars64.bat' |
            Where-Object { $_ } |
            Select-Object -First 1

        if ($found -and (Test-Path -LiteralPath $found)) {
            return $found
        }
    }

    $patterns = @(
        (Join-Path ${env:ProgramFiles} '*\*\VC\Auxiliary\Build\vcvars64.bat'),
        (Join-Path ${env:ProgramFiles(x86)} '*\*\VC\Auxiliary\Build\vcvars64.bat')
    )

    foreach ($pattern in $patterns) {
        $candidate = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate.FullName
        }
    }

    throw 'could not locate vcvars64.bat; pass -VcVarsPath or set VCVARS_PATH'
}

# vcvars64.bat only emits `set` output when run by cmd.exe, so capture it there
# and copy the variables into this process. That keeps cl.exe usable directly
# from PowerShell. The capture runs through a small temporary .bat: nesting the
# vcvars path in a cmd.exe argument from PowerShell does not survive quoting.
function Import-VcEnvironment {
    param([string]$VcVars)

    Write-Host "==> MSVC environment: $VcVars"

    $capture = Join-Path $TempDir 'vcenv.bat'

    Set-Content -LiteralPath $capture -Encoding ASCII -Value @(
        '@echo off'
        "call `"$VcVars`" >nul || exit /b 1"
        'set'
    )

    try {
        $lines = & $env:ComSpec /d /c $capture
        $exitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        throw "failed to load the MSVC environment (exit code $exitCode)"
    }

    foreach ($line in $lines) {
        # Skip the pseudo variables cmd.exe reports as "=C:=C:\...".
        if ($line -match '^([^=][^=]*)=(.*)$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }

    $cl = (Get-Command cl.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1).Source

    if (-not $cl) {
        throw 'cl.exe is not on PATH after loading vcvars64.bat'
    }

    return $cl
}

$vcVars = Find-VcVars -Explicit $VcVarsPath
$clExe = Import-VcEnvironment -VcVars $vcVars

# Only known once vcvars64.bat has been loaded.
$compilerVersion = 'MSVC'
if ($env:VCToolsVersion) {
    $compilerVersion = "MSVC-$($env:VCToolsVersion)"
}

# ------------------------------------------------------------
# Download CoreMark
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath (Join-Path $CoreMarkDir '.git'))) {
    Write-Host "==> Downloading CoreMark ($CoreMarkRef)"

    # Drop a stale/partial checkout so the clone cannot fail on the target dir.
    if (Test-Path -LiteralPath $CoreMarkDir) {
        Remove-Item -LiteralPath $CoreMarkDir -Recurse -Force
    }

    & git clone --depth=1 --branch $CoreMarkRef https://github.com/eembc/coremark.git $CoreMarkDir

    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $CoreMarkDir 'core_main.c'))) {
    throw "CoreMark sources are missing in $CoreMarkDir"
}

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

if (Test-Path -LiteralPath $DistDir) {
    Remove-Item -LiteralPath $DistDir -Recurse -Force
}

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

Write-Host ''
Write-Host '========================================'
Write-Host 'Building CoreMark'
Write-Host '========================================'
Write-Host "Target:  $Target"
Write-Host "Toolset: MSVC $($env:VCToolsVersion)"
Write-Host '========================================'

# cl.exe writes object files into the working directory, so build from the
# scratch directory to keep the checkout clean.
$sources = @(
    'core_main.c'
    'core_list_join.c'
    'core_matrix.c'
    'core_state.c'
    'core_util.c'
    'posix\core_portme.c'
) | ForEach-Object { Join-Path $CoreMarkDir $_ }

# A response file keeps cl's quoting rules in charge instead of a shell's.
# Note two cl specific details:
#   * the quotes around the FLAGS_STR value must be passed as \", because cl
#     unfolds plain quotes in a response file (that yields "cl: undeclared
#     identifier" from the -D value).
#   * every linker option has to sit on the same line as -link.
$rspLines = @(
    '-nologo'
    '-O2'
    '-MT'
    '-GL'
    '-DNDEBUG'
    '-DPERFORMANCE_RUN=1'
    "-DITERATIONS=$Iterations"
    '-DFLAGS_STR=\"' + $compilerFlags + '\"'
    '-DCOMPILER_VERSION=\"' + $compilerVersion + '\"'
    "-I`"$CoreMarkDir`""
    "-I`"$(Join-Path $CoreMarkDir 'posix')`""
)
$rspLines += $sources | ForEach-Object { "`"$_`"" }
$rspLines += @(
    "-Fe`"$Binary`""
    '-link -LTCG -SUBSYSTEM:CONSOLE'
)

$rspPath = Join-Path $TempDir 'cl.rsp'
Set-Content -LiteralPath $rspPath -Value $rspLines -Encoding ASCII

Push-Location $TempDir
try {
    & $clExe "@$rspPath" 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    throw "cl.exe failed with exit code $exitCode"
}

if (-not (Test-Path -LiteralPath $Binary)) {
    throw "cl.exe did not produce $Binary"
}

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------

Write-Host ''
Write-Host '==> Binary'

Get-Item -LiteralPath $Binary |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize |
    Out-String |
    Write-Host

# Read the COFF machine field from the PE header (e_lfanew at 0x3C, 'PE\0\0'
# signature, then the 2-byte machine type).
function Get-PeMachine {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $reader = New-Object System.IO.BinaryReader($stream)

        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()

        $stream.Position = $peOffset

        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "$Path is not a PE image"
        }

        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

# Subsystem is the 2-byte field at offset 0x44 of the optional header (0x40 for
# PE32, where ImageBase is 4 bytes narrower). The optional header starts right
# after the 4 byte PE signature + 20 byte COFF file header.
function Get-PeSubsystem {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)

    try {
        $reader = New-Object System.IO.BinaryReader($stream)

        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()

        $optionalHeader = $peOffset + 24

        $stream.Position = $optionalHeader
        $magic = $reader.ReadUInt16()

        $subsystemOffset = switch ($magic) {
            0x20B { $optionalHeader + 0x44 } # PE32+
            0x10B { $optionalHeader + 0x40 } # PE32
            default { throw "unknown optional header magic 0x{0:X4}" -f $magic }
        }

        $stream.Position = $subsystemOffset

        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

Write-Host '==> PE'

$machine = Get-PeMachine -Path $Binary

$expectedMachine = switch -Regex ($Target) {
    '^x86_64' { 0x8664 }
    '^aarch64' { 0xAA64 }
    '^i686' { 0x014C }
    default { $null }
}

Write-Host ("Machine: 0x{0:X4}" -f $machine)

if ($expectedMachine -and $machine -ne $expectedMachine) {
    throw ("expected machine 0x{0:X4} for {1}, got 0x{2:X4}" -f $expectedMachine, $Target, $machine)
}

# Subsystem 3 = IMAGE_SUBSYSTEM_WINDOWS_CUI, i.e. a console program.
$subsystem = Get-PeSubsystem -Path $Binary

Write-Host "Subsystem: $subsystem"

if ($subsystem -ne 3) {
    throw "expected a console executable (subsystem 3), got $subsystem"
}

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

Write-Host ''
Write-Host '==> Creating package'

foreach ($path in @($Zip, $ShaFile)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

Compress-Archive -Path $Binary -DestinationPath $Zip -Force

$hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $PackageName.zip" | Set-Content -LiteralPath $ShaFile -Encoding ASCII

Write-Host ''
Write-Host '========================================'
Write-Host 'Done'
Write-Host '========================================'
Write-Host ''
Write-Host 'Binary:'
Write-Host "  $Binary"
Write-Host ''
Write-Host 'Package:'
Write-Host "  $Zip"
Write-Host ''
Write-Host 'Checksum:'
Write-Host "  $ShaFile"
Write-Host ''
Write-Host 'Run on Windows:'
Write-Host "  $BinaryName 0x0 0x0 0x66"
