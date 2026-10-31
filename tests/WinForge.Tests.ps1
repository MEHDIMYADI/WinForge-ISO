#requires -Version 7.0
# Run with: Invoke-Pester ./tests
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'scripts/lib/WinForge.Common.psm1') -Force
    Import-Module (Join-Path $root 'scripts/lib/WinForge.Config.psm1') -Force
    Import-Module (Join-Path $root 'scripts/lib/WinForge.UupDump.psm1') -Force
    Import-Module (Join-Path $root 'scripts/lib/WinForge.Catalog.psm1') -Force
    $script:table = Import-PowerShellDataFile -Path (Join-Path $root 'config/milestones.psd1')
}

Describe 'Resolve-WinForgeConfig' {
    It 'accepts defaults' {
        $c = Resolve-WinForgeConfig -Raw @{}
        $c.Product | Should -Be 'Windows 11'
        $c.Editions | Should -Be @('PROFESSIONAL')
        $c.Cleanup | Should -Be 'none'
    }
    It 'defaults Server to SERVERSTANDARD' {
        (Resolve-WinForgeConfig -Raw @{ Product = 'Windows Server 2025' }).Editions | Should -Be @('SERVERSTANDARD')
    }
    It 'normalizes multiple editions' {
        (Resolve-WinForgeConfig -Raw @{ Edition = 'core, professional;CORE' }).Editions | Should -Be @('CORE', 'PROFESSIONAL')
    }
    It 'rejects Windows 11 x86' { { Resolve-WinForgeConfig -Raw @{ Architecture = 'x86' } } | Should -Throw '*x86*' }
    It 'rejects 27H2 on Retail' { { Resolve-WinForgeConfig -Raw @{ Milestone = '27H2' } } | Should -Throw '*Experimental*' }
    It 'rejects 26H1 amd64 on Retail' { { Resolve-WinForgeConfig -Raw @{ Milestone = '26H1'; Architecture = 'amd64' } } | Should -Throw '*arm64*' }
    It 'accepts 26H1 arm64 on Retail' { { Resolve-WinForgeConfig -Raw @{ Milestone = '26H1'; Architecture = 'arm64' } } | Should -Not -Throw }
    It 'rejects a server edition on client' { { Resolve-WinForgeConfig -Raw @{ Edition = 'SERVERSTANDARD' } } | Should -Throw '*not valid*' }
    It 'rejects cleanup without updates' { { Resolve-WinForgeConfig -Raw @{ Updates = 'none'; Cleanup = 'resetbase' } } | Should -Throw '*requires updates*' }
    It 'allows cleanup=none without updates' { { Resolve-WinForgeConfig -Raw @{ Updates = 'none'; Cleanup = 'none' } } | Should -Not -Throw }
    It 'requires the LTSC base ISO' { { Resolve-WinForgeConfig -Raw @{ Product = 'Windows 11 LTSC 2024' } } | Should -Throw '*base ISO*' }
    It 'accepts LTSC with https URL and implies updates' {
        $c = Resolve-WinForgeConfig -Raw @{ Product = 'Windows 11 LTSC 2024'; LtscBaseIsoUrl = 'https://example.com/a.iso'; Updates = 'none' }
        $c.IsLtsc | Should -BeTrue
        $c.Updates | Should -Be 'integrate'
        $c.Editions.Count | Should -Be 0
    }
    It 'rejects http URLs' { { Resolve-WinForgeConfig -Raw @{ DriversUrl = 'http://x/d.zip' } } | Should -Throw '*https*' }
    It 'rejects server arm64' { { Resolve-WinForgeConfig -Raw @{ Product = 'Windows Server 2025'; Architecture = 'arm64' } } | Should -Throw '*amd64*' }
    It 'rejects virtual editions on Server' { { Resolve-WinForgeConfig -Raw @{ Product = 'Windows Server 2025'; VirtualEditions = 'Enterprise' } } | Should -Throw '*client*' }
    It 'canonicalizes virtual editions' { (Resolve-WinForgeConfig -Raw @{ VirtualEditions = 'enterprise,EDUCATION' }).VirtualEditions | Should -Be @('Enterprise', 'Education') }
    It 'rejects unknown virtual editions' { { Resolve-WinForgeConfig -Raw @{ VirtualEditions = 'Bogus' } } | Should -Throw '*Unknown virtual*' }
    It 'rejects bad language codes' { { Resolve-WinForgeConfig -Raw @{ Language = 'english' } } | Should -Throw '*language*' }
    It 'accepts fa-ir and sr-latn-rs' {
        { Resolve-WinForgeConfig -Raw @{ Language = 'fa-ir' } } | Should -Not -Throw
        { Resolve-WinForgeConfig -Raw @{ Language = 'sr-latn-rs' } } | Should -Not -Throw
    }
    It 'bounds the part size' {
        { Resolve-WinForgeConfig -Raw @{ PartSizeMB = '2500' } } | Should -Throw '*1990*'
        { Resolve-WinForgeConfig -Raw @{ PartSizeMB = '50' } } | Should -Throw '*1990*'
    }
    It 'normalizes Windows 10 channel and milestone' {
        $c = Resolve-WinForgeConfig -Raw @{ Product = 'Windows 10'; Channel = 'Beta'; Milestone = '27H2' }
        $c.Channel | Should -Be 'Retail'; $c.Milestone | Should -Be '22H2'
    }
}

Describe 'New-ConverterIni' {
    It 'maps the defaults' {
        $ini = New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{})
        $ini | Should -Match '(?m)^AutoStart=1\r?$'
        $ini | Should -Match '(?m)^AddUpdates=1\r?$'
        $ini | Should -Match '(?m)^Cleanup=0\r?$'
        $ini | Should -Match '(?m)^ResetBase=0\r?$'
        $ini | Should -Match '(?m)^NetFx3=0\r?$'
        $ini | Should -Match '(?m)^StartVirtual=0\r?$'
        $ini | Should -Match '(?m)^AppsLevel=0\r?$'
    }
    It 'maps esd, per-LCU resetbase, apps level and drivers' {
        $c = Resolve-WinForgeConfig -Raw @{ ImageFormat = 'esd'; Cleanup = 'resetbase-per-lcu'; StoreApps = 'level2'; SkipEdge = 'true'; SkipWinRE = 'true' }
        $ini = New-ConverterIni -Config $c -HasDrivers $true
        $ini | Should -Match '(?m)^AutoStart=2\r?$'
        $ini | Should -Match '(?m)^wim2esd=1\r?$'
        $ini | Should -Match '(?m)^ResetBase=2\r?$'
        $ini | Should -Match '(?m)^AppsLevel=2\r?$'
        $ini | Should -Match '(?m)^SkipEdge=1\r?$'
        $ini | Should -Match '(?m)^SkipWinRE=1\r?$'
        $ini | Should -Match '(?m)^AddDrivers=1\r?$'
    }
    It 'maps resetbase' {
        $ini = New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{ Cleanup = 'resetbase' })
        $ini | Should -Match '(?m)^Cleanup=1\r?$'
        $ini | Should -Match '(?m)^ResetBase=1\r?$'
    }
    It 'maps swm and no store apps' {
        $ini = New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{ ImageFormat = 'swm'; StoreApps = 'none' })
        $ini | Should -Match '(?m)^wim2swm=1\r?$'
        $ini | Should -Match '(?m)^SkipApps=1\r?$'
    }
    It 'enables virtual editions' {
        $ini = New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{ VirtualEditions = 'Enterprise,Education' })
        $ini | Should -Match '(?m)^StartVirtual=1\r?$'
        $ini | Should -Match '(?m)^vAutoStart=1\r?$'
        $ini | Should -Match '(?m)^vAutoEditions=Enterprise,Education\r?$'
    }
    It 'leaves cleanup and format to servicing for Server' {
        $c = Resolve-WinForgeConfig -Raw @{ Product = 'Windows Server 2025'; ImageFormat = 'esd' }
        $ini = New-ConverterIni -Config $c
        $ini | Should -Match '(?m)^Cleanup=0\r?$'
        $ini | Should -Match '(?m)^wim2esd=0\r?$'
        $ini | Should -Match '(?m)^AutoStart=1\r?$'
    }
    It 'enables .NET 3.5 when asked' { (New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{ NetFx3 = 'true' })) | Should -Match '(?m)^NetFx3=1\r?$' }
    It 'uses CRLF line endings' { (New-ConverterIni -Config (Resolve-WinForgeConfig -Raw @{})) | Should -Match "`r`n" }
}

Describe 'Get-ReleaseTag' {
    It 'builds a stable tag' {
        $c = Resolve-WinForgeConfig -Raw @{ Language = 'fa-ir' }
        Get-ReleaseTag -Config $c -BuildNumber '26200.1234' -Date '20261031' | Should -Be '20261031-windows11-26200.1234-amd64-fa-ir-professional'
    }
    It 'adds channel and virtual editions' {
        $c = Resolve-WinForgeConfig -Raw @{ Channel = 'Beta'; VirtualEditions = 'Enterprise' }
        Get-ReleaseTag -Config $c -BuildNumber '26220.1' -Date '20261031' | Should -Match 'beta.*enterprise$'
    }
}

Describe 'Select-OsUpdate' {
    It 'skips .NET and prefers feature builds' {
        $u = @(
            [pscustomobject]@{ updateTitle = 'Cumulative Update for .NET Framework'; foundBuild = '26100.1'; arch = 'amd64'; updateId = 'a' },
            [pscustomobject]@{ updateTitle = 'Preview Update for Windows 11'; foundBuild = '26200.5000'; arch = 'amd64'; updateId = 'b' },
            [pscustomobject]@{ updateTitle = 'Windows 11, version 25H2'; foundBuild = '26200.6584'; arch = 'amd64'; updateId = 'c' }
        )
        (Select-OsUpdate -Updates $u -BuildPattern '^26200\.' -Arch 'amd64').Uuid | Should -Be 'c'
    }
    It 'respects architecture' {
        $u = @([pscustomobject]@{ updateTitle = 'Windows 11, version 25H2'; foundBuild = '26200.1'; arch = 'arm64'; updateId = 'x' })
        Select-OsUpdate -Updates $u -BuildPattern '^26200\.' -Arch 'amd64' | Should -BeNullOrEmpty
    }
}

Describe 'Catalog helpers' {
    It 'ranks by month, then build, then KB' {
        $e = @(
            [pscustomobject]@{ GUID = '1'; Title = '2025-09 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5043080)' },
            [pscustomobject]@{ GUID = '2'; Title = '2025-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5044284)' },
            [pscustomobject]@{ GUID = '3'; Title = '2025-10 Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5046617)' }
        )
        (Select-LatestCatalogUpdate -Entries $e -MustMatch 'Cumulative Update' -Exclude @('Preview')).GUID | Should -Be '2'
    }
    It 'returns null when nothing matches' { Select-LatestCatalogUpdate -Entries @() -MustMatch 'x' | Should -BeNullOrEmpty }
    It 'parses catalog HTML' {
        $html = '<a href="javascript:void(0);" onclick=''goToDetails("0a1b2c3d-0000-1111-2222-333344445555");''> 2025-10 Cumulative Update (KB1) </a>'
        $r = @(ConvertFrom-CatalogHtml -Html $html)
        $r.Count | Should -Be 1
        $r[0].GUID | Should -Be '0a1b2c3d-0000-1111-2222-333344445555'
    }
}

Describe 'milestones.psd1' {
    It 'covers every milestone' { foreach ($m in '27H2', '26H2', '26H1', '25H2', '24H2') { $script:table.Windows11.ContainsKey($m) | Should -BeTrue } }
    It 'has valid regex patterns' {
        foreach ($m in $script:table.Windows11.Values) { { [regex]::new($m.RetailPattern) } | Should -Not -Throw; { [regex]::new($m.ExpPattern) } | Should -Not -Throw }
    }
}
