# Third-party notices

WinForge ISO is an independent project. It is not affiliated with or endorsed by Microsoft.

## Code adapted from other projects

- **[suddenBook/UUP_ISO](https://github.com/suddenBook/UUP_ISO)** — MIT License, Copyright (c) 2026 Huixiaqing Liu.
  The approach for resolving Windows 11 builds through UUP dump's `fetchupd.php` with candidate base
  builds, the aria2 file-list generation and the Microsoft Update Catalog flow for Server/LTSC were
  studied and re-implemented here. The MIT notice of that project applies to the adapted ideas and
  snippets:

  > Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
  > associated documentation files, to deal in the software without restriction ... The above copyright
  > notice and this permission notice shall be included in all copies or substantial portions of the Software.

## Tools downloaded at build time (not bundled)

- **[UUP dump](https://uupdump.net/)** — API used for build discovery and file lists.
- **[abbodi1406/BatUtil](https://github.com/abbodi1406/BatUtil)** (`uup-converter-wimlib`) — downloaded at a pinned
  commit during each build. The repository does not publish a license file; review its terms before redistributing builds
  or the converter itself.
- **[aria2](https://aria2.github.io/)**, **[7-Zip](https://www.7-zip.org/)** — preinstalled on GitHub-hosted Windows runners.
- **Microsoft Update Catalog** — source of cumulative and .NET updates for Server and LTSC.

Windows images produced by this tool remain subject to Microsoft's license terms; a valid license is required to activate.
