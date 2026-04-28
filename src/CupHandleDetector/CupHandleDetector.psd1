@{
    # Script module file associated with this manifest.
    RootModule        = 'CupHandleDetector.psm1'

    # Version number of this module.
    ModuleVersion     = '0.1.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Core')

    # ID used to uniquely identify this module
    GUID              = '7c2a2c47-5eab-4e5f-9d0a-28b2c0a6e0f3'

    # Author of this module
    Author            = 'CupHandleDetector Contributors'

    # Company or vendor of this module
    CompanyName       = 'Community'

    # Copyright statement for this module
    Copyright         = '(c) CupHandleDetector Contributors. All rights reserved.'

    # Description of the functionality provided by this module
    Description       = 'PowerShell-first cup-and-handle detection pipeline: ingest OHLCV, compute indicators, detect stages, confirm breakouts, score, and emit/persist events.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.2'

    # Name of the PowerShell host required by this module
    # PowerShellHostName = ''

    # Minimum version of the PowerShell host required by this module
    # PowerShellHostVersion = ''

    # Minimum version of Microsoft .NET Framework required by this module.
    # DotNetFrameworkVersion = ''

    # Minimum version of the common language runtime (CLR) required by this module.
    # CLRVersion = ''

    # Processor architecture (None, X86, Amd64, Arm, Arm64)
    ProcessorArchitecture = 'None'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    ScriptsToProcess  = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess    = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess  = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    NestedModules     = @(
        # Intentionally empty: root module should dot-source/import internal modules as needed
    )

    # Functions to export from this module
    FunctionsToExport = @(
        'Compute-Indicators',
        'Confirm-Breakout',
        'ConvertTo-OhlcvSeries',
        'Detect-Stages',
        'Emit-CHDAlert',
        'Persist-CHDHistory',
        'Resample-Ohlcv'
    )

    # Cmdlets to export from this module
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = '*'

    # Aliases to export from this module
    AliasesToExport   = @()

    # List of all modules packaged with this module
    ModuleList        = @()

    # List of all files packaged with this module
    FileList          = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess.
    PrivateData       = @{
        PSData = @{
            Tags         = @('cup-and-handle', 'technical-analysis', 'ohlcv', 'breakout', 'powershell')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://example.invalid/CupHandleDetector'
            ReleaseNotes = 'Initial manifest and public export surface.'
        }
    }

    # HelpInfo URI of this module
    # HelpInfoURI = ''

    # Default prefix for commands exported from this module. Override in Import-Module -Prefix if desired.
    # DefaultCommandPrefix = 'CHD'
}
