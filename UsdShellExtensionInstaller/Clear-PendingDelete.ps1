#Requires -Version 5.1
<#
.SYNOPSIS
    Cancel the reboot-time deletions scheduled in the install folder.

.DESCRIPTION
    An uninstall deletes the files still in use at the next reboot: Windows
    keeps them in PendingFileRenameOperations (HKLM, Session Manager), a list
    of (source, target) pairs where an empty target means "delete source".
    When an install (or an update, which uninstalls first) writes the same
    files again before that reboot, the reboot would delete the new files and
    break the installation.

    This script removes from that list every deletion whose source is the
    install folder or lies inside it. Scheduled replacements (non-empty
    target) and operations outside the folder are kept, in order.

    Run elevated (the value is under HKLM). Used by the NSIS installer after
    it has written the files, and by install.ps1. Dot-sourced without
    -InstallDir, it only defines its functions (used by the Pester tests).

.PARAMETER InstallDir
    Install folder whose pending deletions are cancelled.

.EXAMPLE
    .\Clear-PendingDelete.ps1 -InstallDir "C:\Program Files\UsdShellExtension"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir
)

Set-StrictMode -Version Latest

function Get-PendingOperationWithoutDelete {
    <#
        Return the operation list (source, target pairs) without the
        deletions (empty target) whose source is Folder or inside it.
        Sources look like "\??\C:\dir\file", optionally prefixed by a flag
        such as "*1"; the comparison ignores case.
    #>
    param(
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Operation,
        [string]$Folder
    )

    # Lower-case folder without trailing backslash, and the same with one to
    # match its content only (not "...\UsdShellExtensionOld").
    $folderPath = $Folder.TrimEnd('\').ToLowerInvariant()
    $folderPrefix = $folderPath + '\'

    $remainingOperations = @()
    for ($index = 0; $index + 1 -lt $Operation.Count; $index += 2) {
        $source = $Operation[$index]
        $target = $Operation[$index + 1]

        # Strip the optional flag prefix ("*1") and the NT prefix ("\??\").
        $sourcePath = ($source -replace '^\*\d+', '' -replace '^\\\?\?\\', '').ToLowerInvariant()
        $isInInstallFolder = ($sourcePath -eq $folderPath) -or $sourcePath.StartsWith($folderPrefix)
        $isDeletion = [string]::IsNullOrEmpty($target)

        if (-not ($isDeletion -and $isInInstallFolder)) {
            $remainingOperations += $source, $target
        }
    }
    # Emitted item by item: callers wrap the call in @() to get an array.
    return $remainingOperations
}

function Clear-PendingDelete {
    <#
        Apply Get-PendingOperationWithoutDelete to the registry value and
        return the number of cancelled deletions. The value is removed when
        no operation is left.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Folder)

    $sessionManagerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $valueName = 'PendingFileRenameOperations'

    $currentValue = Get-ItemProperty -LiteralPath $sessionManagerKey -Name $valueName -ErrorAction SilentlyContinue
    if (-not $currentValue) { return 0 }
    $operations = @($currentValue.$valueName)

    $remainingOperations = @(Get-PendingOperationWithoutDelete $operations $Folder)
    $cancelledCount = ($operations.Count - $remainingOperations.Count) / 2
    if ($cancelledCount -eq 0) { return 0 }

    if ($PSCmdlet.ShouldProcess("$sessionManagerKey\$valueName", "Cancel $cancelledCount pending deletion(s) in $Folder")) {
        if ($remainingOperations.Count -gt 0) {
            Set-ItemProperty -LiteralPath $sessionManagerKey -Name $valueName -Value $remainingOperations -Type MultiString
        } else {
            Remove-ItemProperty -LiteralPath $sessionManagerKey -Name $valueName
        }
    }
    return $cancelledCount
}

# Script entry point: only when an install folder is given (not when the
# tests read the functions).
if ($InstallDir) {
    $cancelledCount = Clear-PendingDelete -Folder $InstallDir
    Write-Output ("Cancelled {0} pending deletion(s) in {1}" -f $cancelledCount, $InstallDir)
}
