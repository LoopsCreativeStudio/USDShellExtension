#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for tools\UsdShellExtension.Build.psm1.

.DESCRIPTION
    Pins the behavior of the helpers shared by build.ps1 and install.ps1:
    .env parsing, path assertions, console output and locked-file copy.

    Run from the repository root:

        Invoke-Pester ./tests/powershell
#>

BeforeDiscovery {
    # Locked-file scenarios rely on Windows share modes. -Skip is evaluated at
    # discovery time, so this must not live in BeforeAll.
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\..\tools\UsdShellExtension.Build.psm1"
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module UsdShellExtension.Build -ErrorAction SilentlyContinue
}

Describe "Module exports" {
    It "exports exactly the shared helpers" {
        $exported = (Get-Module UsdShellExtension.Build).ExportedFunctions.Keys | Sort-Object
        $expected = @(
            'Assert-Path', 'Copy-ThirdPartyLicense', 'Copy-WithRetry', 'Find-NonRedistributableFile', 'Invoke-Robocopy', 'Read-DotEnv',
            'Write-Detail', 'Write-Item', 'Write-Removed', 'Write-Sha256File', 'Write-Step',
            'Get-OpenUsdLayout', 'Get-OpenUsdBuildArgument', 'Get-PathWithoutEntry',
            'Get-LicenseComponentName', 'Copy-OpenUsdLicense'
        ) | Sort-Object
        $exported | Should -Be $expected
    }
}

Describe "Read-DotEnv" {
    It "returns an empty table when the file does not exist" {
        $cfg = Read-DotEnv (Join-Path $TestDrive "missing.env")
        $cfg.Count | Should -Be 0
    }

    It "parses KEY=VALUE pairs and trims spaces" {
        $path = Join-Path $TestDrive "basic.env"
        Set-Content $path @(
            "USD_SDK = D:\sdk  ",
            "  CONFIG=Debug"
        )
        $cfg = Read-DotEnv $path
        $cfg['USD_SDK'] | Should -Be 'D:\sdk'
        $cfg['CONFIG']  | Should -Be 'Debug'
    }

    It "skips blank lines and comments" {
        $path = Join-Path $TestDrive "comments.env"
        Set-Content $path @("", "# USD_SDK=commented", "   ", "CONFIG=Release")
        $cfg = Read-DotEnv $path
        $cfg.Count     | Should -Be 1
        $cfg['CONFIG'] | Should -Be 'Release'
    }

    It "splits on the first '=' only" {
        $path = Join-Path $TestDrive "equals.env"
        Set-Content $path "EDITOR=code --wait --arg=1"
        (Read-DotEnv $path)['EDITOR'] | Should -Be 'code --wait --arg=1'
    }

    It "ignores lines without a key" {
        $path = Join-Path $TestDrive "nokey.env"
        Set-Content $path @("=orphan", "no separator", "CONFIG=Release")
        $cfg = Read-DotEnv $path
        $cfg.Keys | Should -Be @('CONFIG')
    }

    It "keeps the last value of a duplicated key" {
        $path = Join-Path $TestDrive "dup.env"
        Set-Content $path @("CONFIG=Release", "CONFIG=Debug")
        (Read-DotEnv $path)['CONFIG'] | Should -Be 'Debug'
    }
}

Describe "Assert-Path" {
    It "does nothing when the path exists" {
        { Assert-Path $TestDrive "test drive" } | Should -Not -Throw
    }

    It "stops the caller when the path is missing, whatever its preference" {
        # A module does not inherit the caller's ErrorActionPreference:
        # the failure must stay terminating even with Continue.
        $ErrorActionPreference = 'Continue'
        { Assert-Path (Join-Path $TestDrive "nope") "USD SDK" } |
            Should -Throw "*Cannot find USD SDK at:*"
    }
}

Describe "Console helpers" {
    It "Write-Step prints a cyan step marker" {
        $out = Write-Step "Building" 6>&1 | ForEach-Object { "$_" }
        $out | Should -Contain "  >> Building"
    }

    It "Write-Detail aligns the key on 14 characters" {
        "$(Write-Detail 'Log' 'C:\build.log' 6>&1)" | Should -Be "    Log :          C:\build.log"
    }

    It "Write-Item and Write-Removed use + and - markers" {
        "$(Write-Item 'a.dll' 6>&1)"    | Should -Be "    + a.dll"
        "$(Write-Removed 'b.dll' 6>&1)" | Should -Be "    - b.dll"
    }
}

Describe "Find-NonRedistributableFile" {
    # Paths built with [IO.Path]::Combine: the CI runs these tests on Linux,
    # where the separator is "/" (a "\" would be part of a file name).
    BeforeEach {
        $package = [IO.Path]::Combine($TestDrive, "pkg_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force ([IO.Path]::Combine($package, "scripts")) | Out-Null
        New-Item -ItemType Directory -Force ([IO.Path]::Combine($package, "python")) | Out-Null
        New-Item -ItemType Directory -Force ([IO.Path]::Combine($package, "lib", "python", "pxr")) | Out-Null
    }

    It "returns nothing for a clean package" {
        Set-Content ([IO.Path]::Combine($package, "lib", "python", "pxr", "__init__.py")) "# Copyright 2016 Pixar"
        @(Find-NonRedistributableFile $package).Count | Should -Be 0
    }

    It "finds files under an NVIDIA proprietary license, at any depth" {
        $script = [IO.Path]::Combine($package, "scripts", "usdcat.bat")
        Set-Content $script @(
            "REM SPDX-FileCopyrightText: Copyright (c) 2021-2025 NVIDIA CORPORATION & AFFILIATES.",
            "REM SPDX-License-Identifier: LicenseRef-NvidiaProprietary"
        )
        $found = @(Find-NonRedistributableFile $package)
        $found.Count | Should -Be 1
        $found[0] | Should -Be $script
    }

    It "finds NVIDIA packman metadata files" {
        $packman = [IO.Path]::Combine($package, "python", ".packman.sha1")
        Set-Content $packman "abc"
        @(Find-NonRedistributableFile $package) | Should -Be $packman
    }

    It "keeps NVIDIA files released under the OpenUSD license" {
        # UsdPhysics: NVIDIA copyright, Pixar / OpenUSD license: redistributable.
        Set-Content ([IO.Path]::Combine($package, "lib", "python", "pxr", "physics.py")) @("# Copyright (c) 2018, NVIDIA CORPORATION", "# Licensed under the terms set forth in the LICENSE.txt file available at https://openusd.org/license.")
        @(Find-NonRedistributableFile $package).Count | Should -Be 0
    }

    It "scans binary files too" {
        $tool = [IO.Path]::Combine($package, "tool.dll")
        $bytes = [byte[]](0, 1, 2) + [Text.Encoding]::ASCII.GetBytes("LicenseRef-NvidiaProprietary") + [byte[]](0, 255)
        [IO.File]::WriteAllBytes($tool, $bytes)
        @(Find-NonRedistributableFile $package) | Should -Be $tool
    }
}

Describe "Copy-ThirdPartyLicense" -Skip:(-not $script:onWindows) {
    BeforeEach {
        # Shaped like the SDK PACKAGE-LICENSES folder.
        $script:licenseSource = Join-Path $TestDrive "PACKAGE-LICENSES"
        $script:licenseDestination = Join-Path $TestDrive "licenses"
        New-Item -ItemType Directory -Force $script:licenseSource, $script:licenseDestination | Out-Null
        Set-Content (Join-Path $script:licenseSource "usd-license.txt") "Tomorrow Open Source Technology License 1.0"
        Set-Content (Join-Path $script:licenseSource "tbb-LICENSE") "Apache License 2.0"
        Set-Content (Join-Path $script:licenseSource "repo_nv-LICENSE.txt") "NVIDIA proprietary, not shipped"
        Set-Content (Join-Path $script:licenseDestination "stale-LICENSE") "from an older SDK"
    }

    AfterEach {
        Remove-Item $script:licenseSource, $script:licenseDestination -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "copies the licenses of the shipped components" {
        Copy-ThirdPartyLicense $script:licenseSource $script:licenseDestination
        Test-Path (Join-Path $script:licenseDestination "usd-license.txt") | Should -BeTrue
        Test-Path (Join-Path $script:licenseDestination "tbb-LICENSE")     | Should -BeTrue
    }

    It "leaves out the license of the NVIDIA repo tooling, which is not shipped" {
        Copy-ThirdPartyLicense $script:licenseSource $script:licenseDestination
        Test-Path (Join-Path $script:licenseDestination "repo_nv-LICENSE.txt") | Should -BeFalse
    }

    It "removes licenses that are no longer in the SDK" {
        Copy-ThirdPartyLicense $script:licenseSource $script:licenseDestination
        Test-Path (Join-Path $script:licenseDestination "stale-LICENSE") | Should -BeFalse
    }

    It "adds the licenses kept in the repository for components the SDK does not cover" {
        $repositoryLicenses = Join-Path $TestDrive "third_party-licenses"
        New-Item -ItemType Directory -Force $repositoryLicenses | Out-Null
        Set-Content (Join-Path $repositoryLicenses "LGPL-3.0.txt") "GNU LESSER GENERAL PUBLIC LICENSE"
        Copy-ThirdPartyLicense $script:licenseSource $script:licenseDestination -AdditionalSource $repositoryLicenses
        Test-Path (Join-Path $script:licenseDestination "LGPL-3.0.txt")    | Should -BeTrue
        Test-Path (Join-Path $script:licenseDestination "usd-license.txt") | Should -BeTrue
    }
}

Describe "Write-Sha256File" {
    BeforeEach {
        $script:setupFile = Join-Path $TestDrive "UsdShellExtension-v1.2.3-setup.exe"
        Set-Content -LiteralPath $script:setupFile -Value "installer bytes" -NoNewline
        $script:expectedHash = (Get-FileHash -LiteralPath $script:setupFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It "writes a .sha256 file next to the file" {
        Write-Sha256File $script:setupFile | Out-Null
        Test-Path "$script:setupFile.sha256" | Should -BeTrue
    }

    It "uses the sha256sum format: lower-case hash, two spaces, file name" {
        Write-Sha256File $script:setupFile | Out-Null
        $checksumLine = (Get-Content -LiteralPath "$script:setupFile.sha256" -Raw).TrimEnd("`r", "`n")
        $checksumLine | Should -BeExactly "$script:expectedHash  UsdShellExtension-v1.2.3-setup.exe"
    }

    It "returns the checksum file path and the hash" {
        $checksum = Write-Sha256File $script:setupFile
        $checksum.Path | Should -Be "$script:setupFile.sha256"
        $checksum.Hash | Should -BeExactly $script:expectedHash
    }

    It "replaces a checksum file left by an earlier build" {
        Set-Content -LiteralPath "$script:setupFile.sha256" -Value "stale  UsdShellExtension-v1.2.3-setup.exe"
        Write-Sha256File $script:setupFile | Out-Null
        Get-Content -LiteralPath "$script:setupFile.sha256" -Raw | Should -Match "^$script:expectedHash  "
    }
}

Describe "Repository third-party licenses" {
    # PySide6 / Qt (pip-packages\) are under LGPL v3, which refers to GPL v3:
    # both texts must ship, and the SDK PACKAGE-LICENSES does not have them.
    It "keeps the official <File> text" -ForEach @(
        @{ File = "LGPL-3.0.txt"; Title = "GNU LESSER GENERAL PUBLIC LICENSE" }
        @{ File = "GPL-3.0.txt";  Title = "GNU GENERAL PUBLIC LICENSE" }
    ) {
        $licensePath = Join-Path $PSScriptRoot "..\..\third_party\licenses\$File"
        $licenseHeader = (Get-Content -LiteralPath $licensePath -TotalCount 2) -join "`n"
        $licenseHeader | Should -Match ([regex]::Escape($Title))
        $licenseHeader | Should -Match 'Version 3, 29 June 2007'
    }

    # PyOpenGL (pip-packages\) is BSD licensed but its wheel has no license
    # file, while the BSD terms require shipping the text with the binaries.
    It "keeps the PyOpenGL BSD license text" {
        $licensePath = Join-Path $PSScriptRoot "..\..\third_party\licenses\pyopengl-license.txt"
        $licenseText = Get-Content -LiteralPath $licensePath -Raw
        $licenseText | Should -Match 'OpenGL-ctypes License'
        $licenseText | Should -Match 'Redistributions in binary form must reproduce'
    }
}

Describe "Invoke-Robocopy" -Skip:(-not $script:onWindows) {
    BeforeEach {
        $src = Join-Path $TestDrive "rc-src"
        $dst = Join-Path $TestDrive "rc-dst"
        # Start from a missing destination so "files copied" (code 1) is real.
        Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Join-Path $src "sub") | Out-Null
        Set-Content (Join-Path $src "a.txt") "a"
        Set-Content (Join-Path $src "sub\b.pdb") "b"
    }

    AfterEach {
        Remove-Item $src, $dst -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "treats 'files copied' (exit code 1) as success and resets LASTEXITCODE" {
        Invoke-Robocopy $src $dst '/E'
        Test-Path (Join-Path $dst "sub\b.pdb") | Should -BeTrue
        # A leaked robocopy code 1 would make the calling script exit with 1.
        $global:LASTEXITCODE | Should -Be 0
    }

    It "treats 'nothing to copy' (exit code 0) as success" {
        Invoke-Robocopy $src $dst '/E'
        { Invoke-Robocopy $src $dst '/E' } | Should -Not -Throw
    }

    It "passes extra options through (exclusions)" {
        Invoke-Robocopy $src $dst '/E' '/XF' '*.pdb'
        Test-Path (Join-Path $dst "a.txt")     | Should -BeTrue
        Test-Path (Join-Path $dst "sub\b.pdb") | Should -BeFalse
    }

    It "throws with the exit code when robocopy fails (code 8 or more)" {
        $missing = Join-Path $TestDrive "does-not-exist"
        { Invoke-Robocopy $missing $dst '/R:0' '/W:0' } |
            Should -Throw "*robocopy failed (exit code 16)*"
    }
}

Describe "Copy-WithRetry" {
    BeforeEach {
        $src = Join-Path $TestDrive "src"
        $dst = Join-Path $TestDrive "dst"
        New-Item -ItemType Directory -Force $src, $dst | Out-Null
        $srcFile = Join-Path $src "lib.dll"
        Set-Content $srcFile "new"
    }

    AfterEach {
        Remove-Item $src, $dst -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "copies into a destination directory under the same name" {
        Copy-WithRetry $srcFile $dst
        Get-Content (Join-Path $dst "lib.dll") | Should -Be "new"
    }

    It "overwrites an unlocked destination file" {
        $dstFile = Join-Path $dst "lib.dll"
        Set-Content $dstFile "old"
        Copy-WithRetry $srcFile $dstFile
        Get-Content $dstFile | Should -Be "new"
    }

    It "replaces a destination held open with delete sharing (loaded DLL case)" -Skip:(-not $script:onWindows) {
        $dstFile = Join-Path $dst "lib.dll"
        Set-Content $dstFile "old"
        # Simulates Explorer holding the DLL: no write sharing, rename allowed.
        $share  = [System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete
        $handle = [System.IO.File]::Open($dstFile, 'Open', 'Read', $share)
        try {
            Copy-WithRetry $srcFile $dstFile -Retries 1 -DelaySec 0
        } finally {
            $handle.Dispose()
        }
        Get-Content $dstFile | Should -Be "new"
        Test-Path ($dstFile + ".new") | Should -BeFalse
    }

    It "gives up after the retries on an exclusive lock and leaves no temp file" -Skip:(-not $script:onWindows) {
        $dstFile = Join-Path $dst "lib.dll"
        Set-Content $dstFile "old"
        $handle = [System.IO.File]::Open($dstFile, 'Open', 'Read', [System.IO.FileShare]::None)
        try {
            { Copy-WithRetry $srcFile $dstFile -Retries 2 -DelaySec 0 6>$null } | Should -Throw
        } finally {
            $handle.Dispose()
        }
        Get-Content $dstFile | Should -Be "old"
        Test-Path ($dstFile + ".new") | Should -BeFalse
    }
}

Describe "Get-OpenUsdLayout" {
    BeforeAll {
        $script:layout = Get-OpenUsdLayout -Root 'D:\OpenUSD' -OpenUsdVersion 'v26.11.1' -PythonVersion '3.12.10'
    }

    It "keeps one source tree per OpenUSD version" {
        $layout.Source | Should -Be 'D:\OpenUSD\src\v26.11.1'
    }

    It "keeps one Python runtime per Python version" {
        $layout.Python | Should -Be 'D:\OpenUSD\python\3.12.10'
    }

    It "names build, dependency and install folders after OpenUSD and the Python minor version" {
        # The Python bindings only load in the Python minor version they were built against.
        $layout.Dependencies | Should -Be 'D:\OpenUSD\deps\v26.11.1-py312'
        $layout.Build        | Should -Be 'D:\OpenUSD\build\v26.11.1-py312'
        $layout.Install      | Should -Be 'D:\OpenUSD\install\v26.11.1-py312'
    }

    It "keeps downloads in one shared folder" {
        $layout.Downloads | Should -Be 'D:\OpenUSD\downloads'
    }

    It "assembles the SDK folders build.ps1 expects inside the install folder" {
        # Same layout as the NVIDIA package: python\, pip-packages\, PACKAGE-LICENSES\.
        $layout.SdkPython      | Should -Be 'D:\OpenUSD\install\v26.11.1-py312\python'
        $layout.PipPackages    | Should -Be 'D:\OpenUSD\install\v26.11.1-py312\pip-packages'
        $layout.Licenses       | Should -Be 'D:\OpenUSD\install\v26.11.1-py312\PACKAGE-LICENSES'
    }
}

Describe "Get-LicenseComponentName" {
    It "drops the version from a dependency folder name and lowers the case" -ForEach @(
        @{ Folder = 'OpenImageIO-3.1.8.0';    Expected = 'openimageio' }
        @{ Folder = 'libtiff-v4.7.1';         Expected = 'libtiff' }
        @{ Folder = 'OpenSubdiv-3_6_1';       Expected = 'opensubdiv' }
        @{ Folder = 'libjpeg-turbo-3.1.4.1';  Expected = 'libjpeg-turbo' }
        @{ Folder = 'oneTBB-2021.12.0';       Expected = 'onetbb' }
        @{ Folder = 'yaml-cpp';               Expected = 'yaml-cpp' }
    ) {
        Get-LicenseComponentName -FolderName $Folder | Should -Be $Expected
    }
}

Describe "Copy-OpenUsdLicense" {
    BeforeAll {
        # Shaped like an OpenUSD source build: sources, dependency sources,
        # nested dependencies in the build folder, and the Python runtime.
        $script:licenseLayout = Get-OpenUsdLayout -Root (Join-Path $TestDrive 'OpenUSD') -OpenUsdVersion 'v26.11.1' -PythonVersion '3.12.10'
        $files = @{
            "$($licenseLayout.Source)\LICENSE.txt"                                                         = 'usd'
            "$($licenseLayout.Source)\NOTICE.txt"                                                          = 'usd notice'
            "$($licenseLayout.Source)\README.md"                                                           = 'not a license'
            "$($licenseLayout.Dependencies)\OpenImageIO-3.1.8.0\LICENSE.md"                                = 'oiio'
            "$($licenseLayout.Dependencies)\OpenImageIO-3.1.8.0\THIRD-PARTY.md"                            = 'oiio third party'
            "$($licenseLayout.Dependencies)\OpenImageIO-3.1.8.0\CMakeLists.txt"                            = 'not a license'
            "$($licenseLayout.Dependencies)\expat-src\COPYING"                                             = 'dependency folder without version'
            "$($licenseLayout.Build)\openexr-3.3.6\_deps\imath-src\LICENSE.md"                             = 'imath'
            "$($licenseLayout.Build)\OpenColorIO-2.4.2\ext\build\yaml-cpp\src\yaml-cpp_install\LICENSE"    = 'yaml'
            "$($licenseLayout.Build)\OpenColorIO-2.4.2\ext\build\libexpat\src\expat_install\COPYING"       = 'expat'
            "$($licenseLayout.Python)\LICENSE.txt"                                                         = 'python'
        }
        foreach ($path in $files.Keys) {
            New-Item -ItemType Directory -Force (Split-Path $path -Parent) | Out-Null
            Set-Content -Path $path -Value $files[$path]
        }
        # A zip archive next to the folders must be ignored.
        Set-Content -Path "$($licenseLayout.Dependencies)\v3.1.8.0.zip" -Value 'zip'

        Copy-OpenUsdLicense -Layout $licenseLayout
        $script:copied = Get-ChildItem $licenseLayout.Licenses | Sort-Object Name | ForEach-Object Name
    }

    It "copies the OpenUSD license and notice" {
        Get-Content (Join-Path $licenseLayout.Licenses 'openusd-LICENSE.txt') | Should -Be 'usd'
        $copied | Should -Contain 'openusd-NOTICE.txt'
    }

    It "copies the license and third-party files of each dependency, prefixed with its name" {
        Get-Content (Join-Path $licenseLayout.Licenses 'openimageio-LICENSE.md') | Should -Be 'oiio'
        $copied | Should -Contain 'openimageio-THIRD-PARTY.md'
    }

    It "copies the licenses of the libraries the dependencies fetch themselves" {
        Get-Content (Join-Path $licenseLayout.Licenses 'imath-LICENSE.md') | Should -Be 'imath'
        Get-Content (Join-Path $licenseLayout.Licenses 'yaml-cpp-LICENSE')  | Should -Be 'yaml'
        Get-Content (Join-Path $licenseLayout.Licenses 'expat-COPYING')     | Should -Be 'expat'
    }

    It "copies the Python license" {
        Get-Content (Join-Path $licenseLayout.Licenses 'python-LICENSE.txt') | Should -Be 'python'
    }

    It "copies nothing else" {
        $copied | Should -Be (@(
            'expat-COPYING', 'expat-src-COPYING', 'imath-LICENSE.md', 'openimageio-LICENSE.md', 'openimageio-THIRD-PARTY.md',
            'openusd-LICENSE.txt', 'openusd-NOTICE.txt', 'python-LICENSE.txt', 'yaml-cpp-LICENSE'
        ) | Sort-Object)
    }

    It "replaces the previous copy" {
        Set-Content -Path (Join-Path $licenseLayout.Licenses 'stale-LICENSE') -Value 'old'
        Copy-OpenUsdLicense -Layout $licenseLayout
        Test-Path (Join-Path $licenseLayout.Licenses 'stale-LICENSE') | Should -BeFalse
    }
}

Describe "Get-OpenUsdBuildArgument" {
    BeforeAll {
        $layout = Get-OpenUsdLayout -Root 'D:\OpenUSD' -OpenUsdVersion 'v26.11.1' -PythonVersion '3.12.10'
        $script:arguments = Get-OpenUsdBuildArgument -Layout $layout
    }

    It "starts with build_usd.py from the source tree, then the install folder" {
        $arguments[0] | Should -Be 'D:\OpenUSD\src\v26.11.1\build_scripts\build_usd.py'
        $arguments[1] | Should -Be 'D:\OpenUSD\install\v26.11.1-py312'
    }

    It "puts dependency sources and build files in their own folders" {
        $arguments | Should -Contain '--src'
        $arguments[$arguments.IndexOf('--src') + 1]   | Should -Be 'D:\OpenUSD\deps\v26.11.1-py312'
        $arguments[$arguments.IndexOf('--build') + 1] | Should -Be 'D:\OpenUSD\build\v26.11.1-py312'
    }

    It "builds a release with every feature the extension uses" {
        $arguments[$arguments.IndexOf('--build-variant') + 1] | Should -Be 'release'
        foreach ($feature in '--onetbb', '--python', '--usd-imaging', '--usdview', '--materialx', '--openimageio', '--opencolorio', '--ptex', '--alembic') {
            $arguments | Should -Contain $feature
        }
    }

    It "does not ask for Hydra alone, which would disable usdImaging and usdview" {
        $arguments | Should -Not -Contain '--imaging'
    }

    It "leaves out what the extension does not ship" {
        foreach ($feature in '--no-embree', '--no-tests', '--no-examples', '--no-tutorials', '--no-docs', '--no-python-docs') {
            $arguments | Should -Contain $feature
        }
    }
}

Describe "Get-PathWithoutEntry" {
    It "drops the entries that match a pattern and keeps the order of the others" {
        $path = 'C:\Windows;C:\Strawberry\c\bin;C:\Program Files\CMake\bin;C:\Python311'
        $result = Get-PathWithoutEntry -Path $path -Pattern '\\Strawberry\\', '\\Python\d+$'
        $result | Should -Be 'C:\Windows;C:\Program Files\CMake\bin'
    }

    It "matches without regard to case" {
        Get-PathWithoutEntry -Path 'C:\A;c:\strawberry\perl\bin' -Pattern '\\Strawberry\\' | Should -Be 'C:\A'
    }

    It "drops empty entries" {
        Get-PathWithoutEntry -Path 'C:\A;;C:\B;' -Pattern 'unused' | Should -Be 'C:\A;C:\B'
    }
}
