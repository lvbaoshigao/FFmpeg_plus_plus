# Self-contained contract tests. Mock tools only; never compile the backend.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'build_backend.ps1')
$script:Passed = 0
$script:FixtureNumber = 0
$script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ffmpegpp-msvc-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:FixtureRoot)
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    if ($null -eq $failure) { throw "Expected failure: $MessagePattern" }
    if ($failure.ToString() -notmatch $MessagePattern) { throw "Unexpected failure: $failure" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:Passed++
    Write-Host "PASS $Name"
}
function New-BuildFixture {
    $script:FixtureNumber++
    $source = Join-Path $script:FixtureRoot ("source root $($script:FixtureNumber)")
    $build = Join-Path $source 'build with spaces'
    $tools = Join-Path $source 'current toolchain'
    [void][IO.Directory]::CreateDirectory($tools)
    [void][IO.Directory]::CreateDirectory((Join-Path $build 'CMakeFiles'))
    [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'), '# fixture only')
    [IO.File]::WriteAllText((Join-Path $source 'source-sentinel.txt'), 'keep')
    $compiler = Join-Path $tools 'cl.exe'
    [IO.File]::WriteAllText($compiler, 'mock compiler; never executed')
    $toolchain = [pscustomobject]@{ CompilerPath = $compiler; Fingerprint = 'fixture-fingerprint' }
    $script:CurrentToolchain = $toolchain
    $script:Calls = [Collections.Generic.List[object]]::new()
    $script:FailConfigure = $false
    $script:FailBuild = $false
    return [pscustomobject]@{ Source = $source; Build = $build; Compiler = $compiler; Toolchain = $toolchain }
}
function Write-FixtureCache {
    param($Fixture, [hashtable]$Overrides = @{})
    $entries = [ordered]@{
        CMAKE_GENERATOR = 'NMake Makefiles'
        CMAKE_HOME_DIRECTORY = $Fixture.Source
        CMAKE_CACHEFILE_DIR = $Fixture.Build
        CMAKE_C_COMPILER = $Fixture.Compiler
        CMAKE_CXX_COMPILER = $Fixture.Compiler
    }
    foreach ($entry in $Overrides.GetEnumerator()) { $entries[$entry.Key] = $entry.Value }
    $lines = @($entries.GetEnumerator() | ForEach-Object { $_.Key + ':STRING=' + $_.Value })
    [IO.File]::WriteAllLines((Join-Path $Fixture.Build 'CMakeCache.txt'), [string[]]$lines)
    [IO.File]::WriteAllText((Join-Path $Fixture.Build 'old-object-sentinel.txt'), 'cached')
}
function Get-MsvcToolchainInfo {
    param([string]$SourceDir, [string]$Generator)
    return $script:CurrentToolchain
}
function Resolve-BackendCMake { return 'mock-cmake' }
$script:RealBackendNative = (Get-Item Function:Invoke-BackendNative).ScriptBlock
function Invoke-BackendNative {
    param([string]$FilePath, [string[]]$Arguments)
    $script:Calls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($Arguments) })
    if ($Arguments[0] -eq '-S' -and $script:FailConfigure) { throw 'fixture configure exited 23' }
    if ($Arguments[0] -eq '--build' -and $script:FailBuild) { throw 'fixture build exited 19' }
}
try {
    Test-Case 'fingerprint is deterministic and covers every toolchain field' {
        $fixture = New-BuildFixture
        $fields = @{
            CompilerPath = $fixture.Compiler; CompilerVersion = 'compiler-file-v1'
            VCToolsVersion = 'vc-tools-v1'; WindowsSDKVersion = 'windows-sdk-v1'
            WindowsSDKDirectory = $fixture.Source; Generator = 'NMake Makefiles'; SourceDir = $fixture.Source
        }
        $first = Get-MsvcFingerprint @fields
        Assert-True ($first -cmatch '^[0-9a-f]{64}$') 'Fingerprint is not SHA256 hex'
        Assert-True ($first -ceq (Get-MsvcFingerprint @fields)) 'Identical toolchain keys differ'
        foreach ($name in $fields.Keys) {
            $changed = $fields.Clone(); $changed[$name] = $changed[$name] + '-changed'
            Assert-True ($first -cne (Get-MsvcFingerprint @changed)) "Fingerprint ignored $name"
        }
    }
    Test-Case 'GitHub environment and output records use UTF8 without BOM' {
        $path = Join-Path $script:FixtureRoot 'github output.txt'
        Write-GitHubFileValue $path 'compiler-fingerprint' 'abc123'
        Write-GitHubFileValue $path 'INCLUDE' ('first' + [Environment]::NewLine + 'second')
        $text = [IO.File]::ReadAllText($path)
        Assert-True ($text.Contains('compiler-fingerprint=abc123')) 'Output missing'
        Assert-True ($text.Contains('INCLUDE<<MSVC_')) 'Multiline record missing'
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'BOM written'
    }
    Test-Case 'native setup and backend failures propagate immediately' {
        $pwsh = (Get-Process -Id $PID).Path
        Assert-Throws { Invoke-MsvcNative $pwsh @('-NoLogo', '-NoProfile', '-Command', 'exit 23') } 'exited 23'
        Assert-Throws { & $script:RealBackendNative $pwsh @('-NoLogo', '-NoProfile', '-Command', 'exit 19') } 'exited 19'
    }
    Test-Case 'compatible cache retains objects and spaced paths stay single arguments' {
        $fixture = New-BuildFixture; Write-FixtureCache $fixture
        Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build -Parallel 2
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Build 'old-object-sentinel.txt')) 'Compatible cache deleted'
        Assert-True ($script:Calls.Count -eq 2) 'Expected configure and build once'
        Assert-True ($script:Calls[0].Arguments[0] -eq '-S') 'Missing -S'
        Assert-True ($script:Calls[0].Arguments[1] -eq $fixture.Source) 'Source path split'
        Assert-True ($script:Calls[0].Arguments[2] -eq '-B') 'Missing -B'
        Assert-True ($script:Calls[0].Arguments[3] -eq $fixture.Build) 'Build path split'
        Assert-True ($script:Calls[1].Arguments[0] -eq '--build') 'Unverified standalone build tool used'
    }
    Test-Case 'removed compiler clears only the verified stale build tree' {
        $fixture = New-BuildFixture
        Write-FixtureCache $fixture @{ CMAKE_CXX_COMPILER = (Join-Path $fixture.Source 'removed toolset/cl.exe') }
        $sibling = Join-Path $fixture.Source 'sibling'; [void][IO.Directory]::CreateDirectory($sibling)
        [IO.File]::WriteAllText((Join-Path $sibling 'keep.txt'), 'keep')
        Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Build 'old-object-sentinel.txt'))) 'Stale cache reused'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Source 'source-sentinel.txt')) 'Source deleted'
        Assert-True (Test-Path -LiteralPath (Join-Path $sibling 'keep.txt')) 'Sibling deleted'
    }
    foreach ($boundary in @('CMAKE_GENERATOR', 'CMAKE_HOME_DIRECTORY', 'CMAKE_CACHEFILE_DIR', 'CMAKE_C_COMPILER')) {
        Test-Case "changed $boundary invalidates objects" {
            $fixture = New-BuildFixture
            $replacement = if ($boundary -eq 'CMAKE_GENERATOR') { 'Ninja' } else { Join-Path $fixture.Source 'other' }
            if ($boundary -eq 'CMAKE_C_COMPILER') { [IO.File]::WriteAllText($replacement, 'other compiler') }
            $override = @{}; $override[$boundary] = $replacement; Write-FixtureCache $fixture $override
            Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Build 'old-object-sentinel.txt'))) "Old $boundary reused"
        }
    }
    Test-Case 'SDK or compiler version stamp invalidates an otherwise matching cache' {
        $fixture = New-BuildFixture; Write-FixtureCache $fixture
        [IO.File]::WriteAllText((Join-Path $fixture.Build '.ffmpegpp-toolchain'), 'previous-sdk-fingerprint')
        Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Build 'old-object-sentinel.txt'))) 'Old SDK objects retained'
    }
    Test-Case 'source parent and outside directories are never cleaned' {
        $fixture = New-BuildFixture
        foreach ($unsafe in @($fixture.Source, $script:FixtureRoot, (Join-Path $script:FixtureRoot 'outside'))) {
            Assert-Throws { Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $unsafe } 'unsafe backend build directory'
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Source 'CMakeLists.txt')) 'Source deleted'
        Assert-True ($script:Calls.Count -eq 0) 'Tool ran for unsafe build path'
    }
    Test-Case 'unrecognized directories cannot be recursively removed' {
        $fixture = New-BuildFixture
        Assert-Throws { Reset-BackendBuildDirectory $fixture.Source $fixture.Build } 'unrecognized build directory'
        Assert-True (Test-Path -LiteralPath $fixture.Build) 'Unrecognized directory deleted'
    }
    Test-Case 'configure failure prevents build and fingerprint stamp' {
        $fixture = New-BuildFixture; $script:FailConfigure = $true
        Assert-Throws { Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build } 'configure exited 23'
        Assert-True ($script:Calls.Count -eq 1) 'Build ran after configure failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Build '.ffmpegpp-toolchain'))) 'Failed configure stamped'
    }
    Test-Case 'build failure is propagated' {
        $fixture = New-BuildFixture; $script:FailBuild = $true
        Assert-Throws { Invoke-BackendBuild -SourceDir $fixture.Source -BuildDir $fixture.Build } 'build exited 19'
        Assert-True ($script:Calls.Count -eq 2) 'Build count wrong'
    }
    Write-Host "All $script:Passed Windows build contract tests passed."
} finally {
    $tempRoot = Get-ToolchainPathKey ([IO.Path]::GetTempPath())
    $fixtureKey = Get-ToolchainPathKey $script:FixtureRoot
    if ($fixtureKey.StartsWith($tempRoot + '/', [StringComparison]::Ordinal) -and
        [IO.Path]::GetFileName($script:FixtureRoot).StartsWith('ffmpegpp-msvc-tests-')) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force
    } else { throw "Refusing unexpected test cleanup directory: $script:FixtureRoot" }
}
