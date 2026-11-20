# Shared MSVC initialization for local builds and GitHub Actions.
[CmdletBinding()]
param(
    [string]$SourceDir = (Join-Path $PSScriptRoot '../../server_cpp'),
    [string]$Generator = 'NMake Makefiles',
    [string]$VsWherePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalBuildPath {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return [IO.Path]::GetFullPath($full)
}

function Get-ToolchainPathKey {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-CanonicalBuildPath $Path).Replace([char]92, '/').TrimEnd('/').ToLowerInvariant()
}

function Write-GitHubFileValue {
    param([string]$FilePath, [string]$Name, [AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return }
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        throw "Invalid GitHub output name: $Name"
    }
    $newline = [Environment]::NewLine
    if ($Value.Contains([char]10) -or $Value.Contains([char]13)) {
        $delimiter = 'MSVC_' + [Guid]::NewGuid().ToString('N')
        $record = $Name + '<<' + $delimiter + $newline + $Value + $newline + $delimiter + $newline
    } else {
        $record = $Name + '=' + $Value + $newline
    }
    [IO.File]::AppendAllText($FilePath, $record, [Text.UTF8Encoding]::new($false))
}

function Invoke-MsvcNative {
    param([string]$FilePath, [string[]]$Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $FilePath @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        # cmd's successful output contains the runner environment; never dump it.
        throw ('Command {0} exited {1}' -f $FilePath, $code)
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Get-MsvcFingerprint {
    param(
        [Parameter(Mandatory)][string]$CompilerPath,
        [Parameter(Mandatory)][string]$CompilerVersion,
        [Parameter(Mandatory)][string]$VCToolsVersion,
        [Parameter(Mandatory)][string]$WindowsSDKVersion,
        [Parameter(Mandatory)][string]$WindowsSDKDirectory,
        [Parameter(Mandatory)][string]$Generator,
        [Parameter(Mandatory)][string]$SourceDir
    )
    $identity = [ordered]@{
        compiler = Get-ToolchainPathKey $CompilerPath
        compilerVersion = $CompilerVersion.Trim()
        vcToolsVersion = $VCToolsVersion.Trim().TrimEnd([char[]]@([char]92, [char]47))
        windowsSdkVersion = $WindowsSDKVersion.Trim().TrimEnd([char[]]@([char]92, [char]47))
        windowsSdkDirectory = Get-ToolchainPathKey $WindowsSDKDirectory
        generator = $Generator.Trim()
        sourceRoot = Get-ToolchainPathKey $SourceDir
    } | ConvertTo-Json -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-MsvcToolchainInfo {
    param([string]$SourceDir, [string]$Generator)
    $source = Get-CanonicalBuildPath $SourceDir
    if (-not (Test-Path -LiteralPath (Join-Path $source 'CMakeLists.txt') -PathType Leaf)) {
        throw "CMake source directory was not found: $source"
    }
    $command = Get-Command cl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $compiler = Get-CanonicalBuildPath $command.Source
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "The active MSVC compiler does not exist: $compiler"
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion
    foreach ($name in @('VCToolsInstallDir', 'VCToolsVersion', 'WindowsSDKVersion', 'WindowsSdkDir')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            throw "The MSVC environment is incomplete: $name is missing. Run setup_msvc.ps1 first."
        }
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Cannot determine the active compiler file version: $compiler"
    }
    $fields = @{
        CompilerPath = $compiler
        CompilerVersion = $version
        VCToolsVersion = $env:VCToolsVersion
        WindowsSDKVersion = $env:WindowsSDKVersion
        WindowsSDKDirectory = $env:WindowsSdkDir
        Generator = $Generator
        SourceDir = $source
    }
    $fingerprint = Get-MsvcFingerprint @fields
    return [pscustomobject]($fields + @{ Fingerprint = $fingerprint })
}

function Initialize-MsvcEnvironment {
    param([string]$SourceDir, [string]$Generator, [string]$VsWherePath)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'MSVC initialization requires Windows.'
    }
    if ([string]::IsNullOrWhiteSpace($VsWherePath)) {
        $installerRoot = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        if (-not [string]::IsNullOrWhiteSpace($installerRoot)) {
            $VsWherePath = Join-Path $installerRoot 'Microsoft Visual Studio/Installer/vswhere.exe'
        }
        if ([string]::IsNullOrWhiteSpace($VsWherePath) -or -not (Test-Path -LiteralPath $VsWherePath -PathType Leaf)) {
            $VsWherePath = (Get-Command vswhere.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        }
    }
    if (-not (Test-Path -LiteralPath $VsWherePath -PathType Leaf)) {
        throw "vswhere was not found: $VsWherePath"
    }
    $installations = @(Invoke-MsvcNative $VsWherePath @(
        '-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($installations.Count -ne 1) { throw 'No installed Visual Studio C++ toolchain was found via vswhere.' }
    $vcvars = Join-Path ($installations[0].Trim()) 'VC/Auxiliary/Build/vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "vcvars64.bat was not found: $vcvars" }
    $commandLine = 'call "{0}" >nul && set' -f $vcvars
    $lines = @(Invoke-MsvcNative $env:ComSpec @('/d', '/s', '/c', $commandLine))
    $environment = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') { $environment[$Matches[1]] = $Matches[2] }
    }
    # Export only compiler/SDK inputs, never the runner's unrelated credentials.
    $names = @(
        'PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'EXTERNAL_INCLUDE', 'IFCPATH',
        'VCINSTALLDIR', 'VCToolsInstallDir', 'VCToolsVersion', 'VCToolsRedistDir',
        'VSINSTALLDIR', 'VisualStudioVersion', 'DevEnvDir',
        'WindowsSdkDir', 'WindowsSDKVersion', 'WindowsSdkBinPath', 'WindowsSdkVerBinPath',
        'WindowsLibPath', 'UniversalCRTSdkDir', 'UCRTVersion', 'ExtensionSdkDir',
        'FrameworkDir', 'FrameworkDir64', 'FrameworkVersion', 'FrameworkVersion64',
        'NETFXSDKDir', 'VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_TGT_ARCH', 'VSCMD_VER'
    )
    foreach ($name in $names) {
        if ($environment.ContainsKey($name)) {
            [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
            Write-GitHubFileValue $env:GITHUB_ENV $name $environment[$name]
        }
    }
    $toolchain = Get-MsvcToolchainInfo $SourceDir $Generator
    $expected = Join-Path $env:VCToolsInstallDir 'bin/Hostx64/x64/cl.exe'
    if ((Get-ToolchainPathKey $toolchain.CompilerPath) -ne (Get-ToolchainPathKey $expected)) {
        throw "PATH resolved a compiler outside the selected x64 toolset: $($toolchain.CompilerPath)"
    }
    $exports = @{
        FPPX_MSVC_COMPILER = $toolchain.CompilerPath
        FPPX_MSVC_FINGERPRINT = $toolchain.Fingerprint
    }
    foreach ($entry in $exports.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        Write-GitHubFileValue $env:GITHUB_ENV $entry.Key $entry.Value
    }
    Write-GitHubFileValue $env:GITHUB_OUTPUT 'compiler-fingerprint' $toolchain.Fingerprint
    Write-GitHubFileValue $env:GITHUB_OUTPUT 'cache-key' ('windows-msvc-' + $toolchain.Fingerprint)
    Write-GitHubFileValue $env:GITHUB_OUTPUT 'cl-path' $toolchain.CompilerPath
    Write-Host "MSVC: $($toolchain.CompilerPath) [$($toolchain.CompilerVersion)]"
    Write-Host "Toolchain fingerprint: $($toolchain.Fingerprint)"
    return $toolchain
}

if ($MyInvocation.InvocationName -ne '.') {
    Initialize-MsvcEnvironment -SourceDir $SourceDir -Generator $Generator -VsWherePath $VsWherePath | Out-Null
}
