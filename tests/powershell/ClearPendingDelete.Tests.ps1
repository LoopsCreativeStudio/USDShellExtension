#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for UsdShellExtensionInstaller\Clear-PendingDelete.ps1.

.DESCRIPTION
    An uninstall can schedule files still in use for deletion at the next
    reboot (PendingFileRenameOperations). When an install writes the same
    files again before that reboot, those deletions must be cancelled, or the
    reboot removes the freshly installed files. These tests pin the filtering
    of the operation list; the script functions are read from its source
    (PowerShell AST), without touching the registry.

    Run from the repository root:

        Invoke-Pester ./tests/powershell
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot "..\..\UsdShellExtensionInstaller\Clear-PendingDelete.ps1"
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null)
    $scriptFunctions = $scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)
    foreach ($scriptFunction in $scriptFunctions) {
        . ([scriptblock]::Create($scriptFunction.Extent.Text))
    }

    $script:installFolder = 'C:\Program Files\UsdShellExtension'
}

Describe "Get-PendingOperationWithoutDelete" {
    It "cancels a scheduled deletion of a file in the install folder" {
        $operations = @('\??\C:\Program Files\UsdShellExtension\usd_ar.dll', '')
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -BeNullOrEmpty
    }

    It "cancels a deletion written with a flag prefix (*1)" {
        $operations = @('*1\??\C:\Program Files\UsdShellExtension\uninstall.exe', '')
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -BeNullOrEmpty
    }

    It "cancels the deletion of the install folder itself and of its sub folders" {
        $operations = @(
            '\??\C:\Program Files\UsdShellExtension\usd\hd', ''
            '\??\C:\Program Files\UsdShellExtension', ''
        )
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -BeNullOrEmpty
    }

    It "ignores the case of the path" {
        $operations = @('\??\c:\program files\usdshellextension\USD_TF.DLL', '')
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -BeNullOrEmpty
    }

    It "keeps a scheduled replacement (rename) into the install folder" {
        $operations = @(
            '\??\C:\Program Files\UsdShellExtension\nsA1B2.tmp'
            '!\??\C:\Program Files\UsdShellExtension\UsdShellExtension.dll'
        )
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -Be $operations
    }

    It "keeps deletions outside the install folder, including a folder with the same prefix" {
        $operations = @(
            '\??\C:\Windows\Temp\other.tmp', ''
            '\??\C:\Program Files\UsdShellExtensionOld\usd_ar.dll', ''
        )
        Get-PendingOperationWithoutDelete $operations $script:installFolder | Should -Be $operations
    }

    It "keeps the other operations in order when removing some" {
        $operations = @(
            '\??\C:\Windows\Temp\a.tmp', ''
            '\??\C:\Program Files\UsdShellExtension\usd_ar.dll', ''
            '\??\C:\Windows\Temp\b.tmp', ''
        )
        Get-PendingOperationWithoutDelete $operations $script:installFolder |
            Should -Be @('\??\C:\Windows\Temp\a.tmp', '', '\??\C:\Windows\Temp\b.tmp', '')
    }

    It "accepts the install folder with a trailing backslash" {
        $operations = @('\??\C:\Program Files\UsdShellExtension\usd_ar.dll', '')
        Get-PendingOperationWithoutDelete $operations 'C:\Program Files\UsdShellExtension\' | Should -BeNullOrEmpty
    }

    It "returns nothing for an empty list" {
        Get-PendingOperationWithoutDelete @() $script:installFolder | Should -BeNullOrEmpty
    }
}
