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
            'Assert-Path', 'Copy-WithRetry', 'Find-NonRedistributableFile', 'Invoke-Robocopy', 'Read-DotEnv',
            'Write-Detail', 'Write-Item', 'Write-Removed', 'Write-Step'
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
    BeforeEach {
        $package = Join-Path $TestDrive ("pkg_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force (Join-Path $package "scripts"), (Join-Path $package "python"), (Join-Path $package "lib\python\pxr") | Out-Null
    }

    It "returns nothing for a clean package" {
        Set-Content (Join-Path $package "lib\python\pxr\__init__.py") "# Copyright 2016 Pixar"
        @(Find-NonRedistributableFile $package).Count | Should -Be 0
    }

    It "finds files under an NVIDIA proprietary license, at any depth" {
        Set-Content (Join-Path $package "scripts\usdcat.bat") @(
            "REM SPDX-FileCopyrightText: Copyright (c) 2021-2025 NVIDIA CORPORATION & AFFILIATES.",
            "REM SPDX-License-Identifier: LicenseRef-NvidiaProprietary"
        )
        $found = @(Find-NonRedistributableFile $package)
        $found.Count | Should -Be 1
        $found[0] | Should -BeLike "*scripts\usdcat.bat"
    }

    It "finds NVIDIA packman metadata files" {
        Set-Content (Join-Path $package "python\.packman.sha1") "abc"
        @(Find-NonRedistributableFile $package) | Should -BeLike "*python\.packman.sha1"
    }

    It "keeps NVIDIA files released under the OpenUSD license" {
        # UsdPhysics: NVIDIA copyright, Pixar / OpenUSD license: redistributable.
        Set-Content (Join-Path $package "lib\python\pxr\physics.py") @("# Copyright (c) 2018, NVIDIA CORPORATION", "# Licensed under the terms set forth in the LICENSE.txt file available at https://openusd.org/license.")
        @(Find-NonRedistributableFile $package).Count | Should -Be 0
    }

    It "scans binary files too" {
        $bytes = [byte[]](0, 1, 2) + [Text.Encoding]::ASCII.GetBytes("LicenseRef-NvidiaProprietary") + [byte[]](0, 255)
        [IO.File]::WriteAllBytes((Join-Path $package "tool.dll"), $bytes)
        @(Find-NonRedistributableFile $package) | Should -BeLike "*tool.dll"
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
