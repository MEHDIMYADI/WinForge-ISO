# Pipeline

1. **plan** (ubuntu): `Plan-Build.ps1` validates inputs (`WinForge.Config`), resolves the exact UUP build (`WinForge.UupDump`, data from `config/milestones.psd1`), computes the release tag and uploads `config.json`.
2. **build** (windows-2022), skipped for `plan_only`:
   1. `Install-Tools.ps1` — converter at a pinned BatUtil commit; optional drivers (zip/7z magic check, `.inf` count, folder check).
   2. Client/Server: `Get-UupSource.ps1` fetches a *fresh* file list (URLs expire) and downloads with aria2; `Invoke-Convert.ps1` writes `ConvertConfig.ini` and runs `convert-UUP.cmd`.
   3. LTSC: `Get-BaseIso.ps1` downloads and signature-checks the base ISO.
   4. Server/LTSC: `Invoke-CatalogServicing.ps1` — Update Catalog CU + .NET, .NET 3.5, drivers, per-index DISM cleanup, export (wim/esd/swm), `cdimage` rebuild.
   5. `Test-Iso.ps1` mounts the ISO and checks boot files, editions and image format.
   6. `Publish-Output.ps1` — SHA-256, multi-part 7z, archive test, release notes.
   7. `gh release create` + uploads with retry, or a workflow artifact.

Bumping the converter: edit `$ConverterCommit` in `scripts/Install-Tools.ps1` after testing a build.
Bumping Windows builds: edit `config/milestones.psd1` only.
