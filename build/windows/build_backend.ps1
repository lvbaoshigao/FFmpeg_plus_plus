# Configure and build the backend only with the active, verified MSVC toolchain.
[CmdletBinding()]
param(
    [string]$SourceDir = (Join-Path $PSScriptRoot '../../server_cpp'),
    [string]$BuildDir = (Join-Path $PSScriptRoot '../../server_cpp/build_win'),
    [string]$Generator = 'NMake Makefiles',
    [string]$Configuration = 'Release',
    [ValidateRange(0, 1024)][int]$Parallel = 0,
    [string[]]$CMakeArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup_msvc.ps1') -SourceDir $SourceDir -Generator $Generator

function Read-BackendCMakeCache {
    param([Parameter(Mandatory)][string]$CachePath)
    $entries = @{}
    foreach ($line in [IO.File]::ReadLines($CachePath)) {
        if ($line -match '^([A-Za-z0-9_]+):[^=]*=(.*)$') {
            $entries[$Matches[1]] = $Matches[2]
        }
    }
    return $entries
}

function Get-BackendCacheMismatch {
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$Generator,
        [Parameter(Mandatory)]$Toolchain
    )
    $cache = Read-BackendCMakeCache $CachePath
    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $cache.ContainsKey('CMAKE_GENERATOR') -or $cache['CMAKE_GENERATOR'] -cne $Generator) {
        $reasons.Add('CMake generator changed or is missing')
    }
    if (-not $cache.ContainsKey('CMAKE_HOME_DIRECTORY') -or
        [string]::IsNullOrWhiteSpace($cache['CMAKE_HOME_DIRECTORY']) -or
        (Get-ToolchainPathKey $cache['CMAKE_HOME_DIRECTORY']) -ne (Get-ToolchainPathKey $SourceDir)) {
        $reasons.Add('CMake source directory changed or is missing')
    }
    if ($cache.ContainsKey('CMAKE_CACHEFILE_DIR') -and
        (Get-ToolchainPathKey $cache['CMAKE_CACHEFILE_DIR']) -ne (Get-ToolchainPathKey $BuildDir)) {
        $reasons.Add('CMake build directory changed')
    }
    foreach ($name in @('CMAKE_C_COMPILER', 'CMAKE_CXX_COMPILER')) {
        if (-not $cache.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($cache[$name])) {
            $reasons.Add("$name is missing")
        } elseif (-not (Test-Path -LiteralPath $cache[$name] -PathType Leaf)) {
            $reasons.Add("$name no longer exists")
        } elseif ((Get-ToolchainPathKey $cache[$name]) -ne (Get-ToolchainPathKey $Toolchain.CompilerPath)) {
            $reasons.Add("$name differs from the active compiler")
        }
    }
    if ($cache.ContainsKey('CMAKE_MAKE_PROGRAM') -and
        -not [string]::IsNullOrWhiteSpace($cache['CMAKE_MAKE_PROGRAM']) -and
        -not (Test-Path -LiteralPath $cache['CMAKE_MAKE_PROGRAM'] -PathType Leaf)) {
        $reasons.Add('The cached build tool no longer exists')
    }
    $stamp = Join-Path $BuildDir '.ffmpegpp-toolchain'
    if ((Test-Path -LiteralPath $stamp -PathType Leaf) -and
        [IO.File]::ReadAllText($stamp).Trim() -cne $Toolchain.Fingerprint) {
        $reasons.Add('Compiler version or Windows SDK fingerprint changed')
    }
    return $reasons.ToArray()
}

function Assert-BackendBuildDirectory {
    param([string]$SourceDir, [string]$BuildDir)
    $source = Get-CanonicalBuildPath $SourceDir
    $build = Get-CanonicalBuildPath $BuildDir
    $sourceKey = Get-ToolchainPathKey $source
    $buildKey = Get-ToolchainPathKey $build
    # Cleanup is limited to an out-of-source child under this exact source root.
    if ($buildKey -eq $sourceKey -or -not $buildKey.StartsWith($sourceKey + '/', [StringComparison]::Ordinal)) {
        throw "Refusing unsafe backend build directory: $build"
    }
    if (Test-Path -LiteralPath (Join-Path $build 'CMakeLists.txt') -PathType Leaf) {
        throw "Refusing to remove a directory containing CMake source files: $build"
    }
    $cursor = $build
    while ((Get-ToolchainPathKey $cursor) -ne $sourceKey) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a linked or reparse-point build directory: $cursor"
            }
            if (-not $item.PSIsContainer) { throw "Build path is not a directory: $cursor" }
        }
        $cursor = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($cursor)) { throw 'Build directory validation reached the filesystem root.' }
    }
    return $build
}

function Reset-BackendBuildDirectory {
    param([string]$SourceDir, [string]$BuildDir)
    $verified = Assert-BackendBuildDirectory $SourceDir $BuildDir
    if (-not (Test-Path -LiteralPath (Join-Path $verified 'CMakeCache.txt') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $verified 'CMakeFiles') -PathType Container)) {
        throw "Refusing to clear an unrecognized build directory: $verified"
    }
    Write-Host "Clearing stale CMake build directory: $verified"
    Remove-Item -LiteralPath $verified -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $verified) { throw "Failed to clear the stale build directory: $verified" }
}

function Resolve-BackendCMake {
    return (Get-Command cmake -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Invoke-BackendNative {
    param([string]$FilePath, [string[]]$Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    & $FilePath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ('Command {0} exited {1}' -f $FilePath, $code) }
}

function Invoke-BackendBuild {
    param(
        [string]$SourceDir,
        [string]$BuildDir,
        [string]$Generator = 'NMake Makefiles',
        [string]$Configuration = 'Release',
        [int]$Parallel = 0,
        [string[]]$CMakeArguments = @()
    )
    $source = Get-CanonicalBuildPath $SourceDir
    if (-not (Test-Path -LiteralPath (Join-Path $source 'CMakeLists.txt') -PathType Leaf)) {
        throw "CMake source directory was not found: $source"
    }
    $build = Assert-BackendBuildDirectory $source $BuildDir
    $toolchain = Get-MsvcToolchainInfo $source $Generator
    $cmake = Resolve-BackendCMake
    $cachePath = Join-Path $build 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $reasons = @(Get-BackendCacheMismatch $cachePath $source $build $Generator $toolchain)
        if ($reasons.Count -gt 0) {
            Write-Host ('CMake cache is incompatible: ' + ($reasons -join '; '))
            Reset-BackendBuildDirectory $source $build
        }
    }
    [void][IO.Directory]::CreateDirectory($build)
    $configure = @(
        '-S', $source, '-B', $build, '-G', $Generator,
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-DCMAKE_C_COMPILER=$($toolchain.CompilerPath)",
        "-DCMAKE_CXX_COMPILER=$($toolchain.CompilerPath)"
    ) + $CMakeArguments
    # Keep the configure result check immediately next to the native invocation.
    Invoke-BackendNative -FilePath $cmake -Arguments $configure
    [IO.File]::WriteAllText(
        (Join-Path $build '.ffmpegpp-toolchain'), $toolchain.Fingerprint,
        [Text.UTF8Encoding]::new($false)
    )
    $arguments = @('--build', $build, '--config', $Configuration)
    if ($Parallel -gt 0) { $arguments += @('--parallel', $Parallel.ToString()) }
    Invoke-BackendNative -FilePath $cmake -Arguments $arguments
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BackendBuild -SourceDir $SourceDir -BuildDir $BuildDir -Generator $Generator -Configuration $Configuration -Parallel $Parallel -CMakeArguments $CMakeArguments
}
