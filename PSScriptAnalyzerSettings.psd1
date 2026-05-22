@{
    ExcludeRules = @(
        # Write-Host is intentional in these interactive installer/build scripts
        # for colored terminal output. The scripts require #Requires -Version 5.1
        # where Write-Host is fully suppressable and redirectable.
        'PSAvoidUsingWriteHost'
    )
}
