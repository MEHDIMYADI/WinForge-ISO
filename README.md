# WinForge ISO

Build Windows ISOs on GitHub Actions, using the [UUP dump](https://uupdump.net/) API and the `uup-converter-wimlib` scripts. One workflow, every option is a dropdown or a checkbox, and the result ends up as a GitHub Release you can download.

I started from the idea behind [suddenBook/UUP_ISO](https://github.com/suddenBook/UUP_ISO) and changed it so that everything lives in a single configurable workflow instead of one workflow per product.

## What it can build

- **Windows 11**: Retail, Release Preview, Beta and Experimental channels. 24H2, 25H2, 26H1, 26H2 and 27H2.
- **Windows 10 22H2**: amd64, arm64 and x86.
- **Windows Server 2025**: with the newest cumulative update pulled from the Microsoft Update Catalog.
- **Windows 11 LTSC 2024**: you supply the base ISO link, the workflow adds the latest update, .NET and your drivers.

## Options

| Option | What it does |
|---|---|
| Updates | Integrate the latest updates into the image, add them externally, or skip them |
| Cleanup | none, `cleanup`, `resetbase`, or `resetbase-per-lcu` |
| .NET Framework 3.5 | Enable it in the image |
| Image format | `wim`, `esd` (smallest) or `swm` (split, for FAT32 USB sticks) |
| Editions | One or several base editions, plus virtual editions such as Enterprise and Education |
| Store apps | All, level 1 to 4, or none |
| Skip Edge / skip WinRE | Smaller images |
| Update boot files | Refresh bootmgr and EFI files |
| Drivers | `OS`, `WinPE` and `ALL` folders from a zip or 7z (template in `drivers-template.zip`) |
| Archive | 7z in `store`, `normal` or `ultra` mode, split into parts (1900 MB by default) |
| Publish | GitHub Release, or a 3-day workflow artifact |
| Dry run | `plan_only` validates your options and finds the build without building anything |

Every output gets a SHA-256 checksum (ISO and each part), the 7z archive is tested before upload, and the finished ISO is mounted and checked for boot files, editions and the expected image format.

The full list of inputs and their rules is in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Usage

1. Fork or copy this repository into your own account. Keep it private if you are going to publish ISOs.
2. Go to **Actions**, pick **Build Windows ISO** and click **Run workflow**.
3. Choose your options. For a first run, tick `plan_only` to make sure the build you want actually exists.
4. When the real build finishes (usually 1 to 3 hours), download every part from **Releases** into one folder and run:

```
7z x <name>.7z.001
```

Compare the result with the `.sha256` file from the release.

### A few example setups

- Small Persian Windows 11 Pro: language `fa-ir`, cleanup `resetbase`, image format `esd`, store apps `level3`.
- Pro plus Enterprise and Education: edition `PROFESSIONAL`, virtual editions `Enterprise,Education`.
- Server with two editions: product Windows Server 2025, edition `SERVERSTANDARD,SERVERDATACENTER`.
- LTSC: product Windows 11 LTSC 2024 and a direct link in `ltsc_base_iso_url`.

## Repository layout

```
.github/workflows/build-iso.yml       main workflow (plan, build, publish)
.github/workflows/ci.yml              actionlint, syntax check, PSScriptAnalyzer, Pester
scripts/Plan-Build.ps1                validates inputs and resolves the UUP build
scripts/Get-UupSource.ps1             builds the file list and downloads with aria2
scripts/Install-Tools.ps1             converter (pinned commit) and drivers
scripts/Invoke-Convert.ps1            writes ConvertConfig.ini and runs the converter
scripts/Get-BaseIso.ps1               downloads and checks the LTSC base ISO
scripts/Invoke-CatalogServicing.ps1   Server and LTSC servicing, then ISO rebuild
scripts/Test-Iso.ps1                  checks the finished ISO
scripts/Publish-Output.ps1            checksums, split 7z, release notes
scripts/lib/                          shared modules
config/milestones.psd1                build numbers and catalog queries
tests/                                Pester tests
```

More detail: [docs/PIPELINE.md](docs/PIPELINE.md) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Things to know

- The Windows steps (converter, DISM, Update Catalog, ISO rebuild) only run on a GitHub-hosted Windows runner. The validation and config logic is covered by unit tests, but the first full build on your account is the real test. If a step fails, the log group for that step tells you where.
- GitHub release assets are limited to 2 GB each, which is why the part size is capped at 1990 MB.
- A job can run for 6 hours at most, and runner disk space is limited.
- Windows needs a valid license to activate. This project has nothing to do with Microsoft.

## Credits and license

MIT licensed. Credits and notes about the tools this project uses are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Maintained by [MEHDIMYADI](https://github.com/MEHDIMYADI).
