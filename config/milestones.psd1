@{
    # Windows 11 milestone resolution table.
    #
    # This is DATA, not code: when Microsoft changes build numbers or Insider rings,
    # edit this file instead of the scripts.
    #
    # UUP dump fetchupd.php ring values:
    #   RETAIL = public release, RP = Release Preview, BETA = Beta,
    #   DEV:0  = Experimental (current Windows core), DEV:-1 = Experimental (Future Platforms)
    #
    # The "build" value is the OS version the fake client reports to Windows Update:
    #   * a build of the PREVIOUS platform returns the retail build of the requested version,
    #   * a build of the SAME platform returns the newest servicing build,
    #   * "NNNNN.latest" lets UUP dump substitute the newest patch level it knows.
    #
    # Retail* keys apply to the Retail and ReleasePreview channels, Exp* keys to Experimental.

    Windows11 = @{
        '27H2' = @{
            Label         = 'Future Platforms'
            RetailBuilds  = @()
            RetailPattern = '^(29|3\d)\d{3}\.'
            ExpRing       = 'DEV:-1'
            ExpBuilds     = @('26300.1', 'latest')
            ExpPattern    = '^(29|3\d)\d{3}\.'
        }
        '26H2' = @{
            Label         = '26H2'
            RetailBuilds  = @('26200.1', '26300.latest', '26300.1')
            RetailPattern = '^26300\.'
            ExpRing       = 'DEV:0'
            ExpBuilds     = @('26300.1', '26300.latest', '26200.1')
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
        '26H1' = @{
            Label         = '26H1'
            RetailBuilds  = @('28000.1', '28000.latest')
            RetailPattern = '^28000\.'
            RetailArch    = 'arm64'
            ExpRing       = 'DEV:0'
            ExpBuilds     = @('28120.1', '28100.1', '28000.latest', '28000.1')
            ExpPattern    = '^28\d{3}\.'
        }
        '25H2' = @{
            Label         = '25H2'
            RetailBuilds  = @('26100.1', '26200.latest', '26200.1')
            RetailPattern = '^26200\.'
            ExpRing       = 'DEV:0'
            ExpBuilds     = @('26300.1', '26300.latest', '26200.1')
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
        '24H2' = @{
            Label         = '24H2'
            RetailBuilds  = @('22631.1', '26100.latest', '26100.1')
            RetailPattern = '^26100\.'
            ExpRing       = 'DEV:0'
            ExpBuilds     = @('26300.1', '26300.latest', '26200.1')
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
    }

    # The Beta channel has a single build series; the milestone input is not used.
    Beta = @{
        Builds  = @('26220.1', '26220.latest', '26320.1', '26200.1')
        Pattern = '^26[2-9]\d{2}\.'
    }

    # Fixed products resolved through the UUP dump build database (listid.php).
    Windows10 = @{
        Search       = 'Feature update to Windows 10, version 22H2'
        TitlePattern = '^Feature update to Windows 10, version 22H2 \('
        BuildPattern = '^19045\.'
    }
    Server2025 = @{
        Search       = 'Windows Server 2025'
        TitlePattern = '^Windows Server 2025 \('
        BuildPattern = '^26100\.'
    }

    # Microsoft Update Catalog searches used for Server 2025 and LTSC 2024 (build 26100).
    Catalog = @{
        Server2025 = @{
            OsQuery  = 'Cumulative Update for Microsoft server operating system, version 24H2 for {ARCH}-based Systems'
            NetQuery = 'Cumulative Update for .NET Framework 3.5 and 4.8.1 for Microsoft server operating system version 24H2 for {ARCH}'
        }
        Ltsc2024 = @{
            OsQuery  = 'Cumulative Update for Windows 11 Version 24H2 for {ARCH}-based Systems'
            NetQuery = 'Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for {ARCH}'
        }
    }
}
