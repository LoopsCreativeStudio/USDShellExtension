#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the configuration lookup of usd-shell.ps1.

.DESCRIPTION
    usd-shell.ps1 runs on its own from the install directory, so it cannot
    import a module. Its helper functions are read from the script source
    (PowerShell AST) and defined here, without running the script itself.

    Run from the repository root:

        Invoke-Pester ./tests/powershell
#>

BeforeAll {
    # Define every _USD_* helper of usd-shell.ps1 in the test scope.
    $scriptPath = Join-Path $PSScriptRoot "..\..\usd-shell.ps1"
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null)
    $helperFunctions = $scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -like '_USD_*'
    }, $false)
    foreach ($helperFunction in $helperFunctions) {
        . ([scriptblock]::Create($helperFunction.Extent.Text))
    }

    # Write an ini file shaped like UsdShellExtension.ini.
    function Initialize-TestIni {
        param([string]$Path, [string]$UsdPath, [string]$PythonPath)
        @(
            "[USD]"
            "PATH=$UsdPath"
            "PYTHONPATH="
            "[PYTHON]"
            "PATH=$PythonPath"
        ) | Set-Content -LiteralPath $Path
        return $Path
    }
}

Describe "_USD_FindIni" {
    BeforeEach {
        $script:emptyIni  = Initialize-TestIni (Join-Path $TestDrive "empty.ini")  "" ""
        $script:filledIni = Initialize-TestIni (Join-Path $TestDrive "filled.ini") "C:\usd" "C:\usd\python\"
        $script:missingIni = Join-Path $TestDrive "missing.ini"
    }

    It "skips an ini whose paths are empty, like the one in the build output" {
        _USD_FindIni @($script:emptyIni, $script:filledIni) | Should -Be $script:filledIni
    }

    It "skips a missing ini" {
        _USD_FindIni @($script:missingIni, $script:filledIni) | Should -Be $script:filledIni
    }

    It "keeps an ini with only [PYTHON] PATH filled" {
        $script:pythonOnlyIni = Initialize-TestIni (Join-Path $TestDrive "python.ini") "" "C:\usd\python\"
        _USD_FindIni @($script:pythonOnlyIni, $script:filledIni) | Should -Be $script:pythonOnlyIni
    }

    It "returns nothing when no ini has a path" {
        _USD_FindIni @($script:missingIni, $script:emptyIni) | Should -BeNullOrEmpty
    }
}
