# Configuration reference

All options are inputs of the **Build Windows ISO** workflow (23 of the 25 allowed `workflow_dispatch` inputs).

| Input | Values | Notes |
|---|---|---|
| `product` | Windows 11, Windows 10, Windows Server 2025, Windows 11 LTSC 2024 | |
| `channel` | Retail, ReleasePreview, Beta, Experimental | Windows 11 only |
| `milestone` | 24H2, 25H2, 26H1, 26H2, 27H2 | Windows 11 only. 27H2 is Experimental only. 26H1 Retail/RP is arm64 only |
| `architecture` | amd64, arm64, x86 | Windows 11: no x86. Server/LTSC: amd64 only |
| `language` | e.g. `en-us`, `fa-ir`, `de-de`, `sr-latn-rs` | UUP dump language code |
| `edition` | comma list | Empty = `PROFESSIONAL` / `SERVERSTANDARD`. Client: PROFESSIONAL, PROFESSIONALN, CORE, COREN, CORESINGLELANGUAGE, CORECOUNTRYSPECIFIC. Server: SERVERSTANDARD, SERVERSTANDARDCORE, SERVERDATACENTER, SERVERDATACENTERCORE. Ignored for LTSC |
| `updates` | integrate, none, external | `external` = converter `AddUpdates=2`. Server/LTSC use the catalog when `catalog_update` is on |
| `cleanup` | none, cleanup, resetbase, resetbase-per-lcu | Requires `updates=integrate` (or catalog for Server/LTSC). `resetbase` makes updates permanent |
| `netfx3` | bool | Not available in Windows 11 builds ≥ 27965 |
| `image_format` | wim, esd, swm | `swm` splits for FAT32 media |
| `skip_winre`, `skip_edge`, `update_boot_files`, `stub_apps_full` | bool | Converter options `SkipWinRE`, `SkipEdge`, `UpdtBootFiles`, `StubAppsFull` |
| `store_apps` | all, level1–level4, none | `SkipApps` / `AppsLevel` |
| `virtual_editions` | Enterprise, Education, ProfessionalEducation, ProfessionalWorkstation, IoTEnterprise (+N) | Windows 10/11 only; created by `create_virtual_editions.cmd` |
| `drivers_url` | https URL | zip/7z with `OS/`, `WinPE/`, `ALL/` (see `drivers-template.zip`) |
| `ltsc_base_iso_url` | https URL | LTSC only; must be a direct link to the ISO |
| `catalog_update` | bool | Server/LTSC: newest cumulative + .NET update |
| `part_size_mb` | 100–1990 | |
| `archive_mode` | store, normal, ultra | `store` is recommended: an ISO is already compressed |
| `publish_release` | bool | Off = 3-day workflow artifact |
| `plan_only` | bool | Dry run |

Invalid combinations fail in the first job (about a minute) with an explanatory message.
