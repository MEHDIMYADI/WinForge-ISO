# Troubleshooting

**"No matching UUP build found"** — Microsoft may not currently offer that build/ring. Re-run later or adjust `config/milestones.psd1` (candidate base builds).

**`RATE_LIMITED` / `WU_REQUEST_FAILED`** — UUP dump throttles; scripts retry with back-off. Re-run if it persists.

**Converter produced no ISO** — read the *Run converter* log group. Common causes: low disk, an unsupported option combination for that build (for example `resetbase` on old builds), missing store apps.

**Catalog returned no rows** — the Update Catalog rate-limits; the script retries with back-off; otherwise re-run.

**LTSC "not a valid ISO"** — the URL must be a direct download, not an HTML page.

**Disk space** — client builds need about 30–40 GB free on `D:`; the workflow checks before starting.

**First run on your account** — the Windows steps (converter, DISM, Update Catalog, ISO rebuild) can only run on a GitHub Windows runner. If a step fails, open an issue with the log group of that step.
