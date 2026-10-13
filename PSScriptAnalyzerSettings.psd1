@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Host is intentional: this is an interactive operator CLI tool.
        'PSAvoidUsingWriteHost',
        # Domain-specific verb "Redact" is clearer than an approved verb here.
        'PSUseApprovedVerbs',
        # "SensitiveKeys" is a plural domain noun used deliberately.
        'PSUseSingularNouns',
        # The file is intentionally UTF-8 without BOM for cross-platform tooling.
        'PSUseBOMForUnicodeEncodedFile',
        # WMI is used for broad Windows Server compatibility.
        'PSAvoidUsingWMICmdlet'
    )
}
