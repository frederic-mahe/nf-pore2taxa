# Plan: per-barcode subsampling + Krona plots

Status: **implemented** (subsampling in `v1.6.0`, Krona in `v1.7.0`;
2026-07-24). Kept for the design rationale and the test strategy. Two
independent features, delivered as two sequential minor releases so history
stays bisectable (the repo's one-feature-per-minor cadence — 1.3.0, 1.4.0,
1.5.0):

- **A — subsampling** → `v1.6.0`: cap each barcode at `n` reads *before*
  trimming, via a per-barcode pooling step (`--subsample n`).
- **B — Krona** → `v1.7.0`: render **both** occurrence tables as
  interactive Krona HTMLs, one dataset per sample (`--krona`).

Every step is **test-first**: add the spec ID + a failing test, then
implement to green, then move on. External tools (`vsearch`,
`ktImportText`) keep their existing contract — we assert *our*
orchestration and outputs, never their internals (SPECIFICATIONS.md
"Ground rules").

---

## Feature A — subsampling (`v1.6.0`)

### Motivation

The pipeline is a "quick & dirty" profiler. On deep runs the dominant cost
is `vsearch --sintax` (reference load + per-read k-mer search), and on
scattered inputs cutadapt is also run over every read. A cap of `n` reads
**per barcode, before trimming** lets a lab get a fast preview and/or
normalise very uneven sampling depths across samples.

### The pooling problem (review outcome)

A sample's reads arrive in one of two layouts:

- **pooled** — a single fastq file per barcode;
- **scattered** — many small fastq files per barcode (and possibly *mixed*
  compression: `.gz`/`.bz2`/`.xz`).

Subsampling must be **per sample (per barcode)**, never per file — thinning
each scattered file independently is meaningless. It is also more
meaningful to subsample **before cutadapt** (rarefy the observed raw reads,
and let the cap bound *all* downstream work, cutadapt included). But raw
scattered reads cannot be stream-concatenated for a pre-trim subsample when
compression formats differ.

**Decision: interpose a per-barcode pooling step** that materialises one
uniform fastq per sample, then subsample that, then trim. This is endorsed,
with two refinements below. Pros/cons that drove it:

| | Pool → subsample → trim (chosen) | Trim per file → concat → subsample trimmed (rejected) |
| --- | --- | --- |
| Semantics | rarefy **raw** observed reads (field-standard) | rarefy **post-filter** reads |
| Compute bound | caps cutadapt **and** vsearch (bigger preview speedup) | caps vsearch only; all reads still trimmed |
| Scattered inputs | handled by the pool step | handled by the implicit concat |
| Mixed compression | solved by the pool step (decompress per file) | never an issue (trimmed fasta is uniform) |
| Cost | one uncompressed pooled fastq materialised in the work dir | none extra |
| Trim stage | **simplifies** to a single cutadapt call on the pooled fastq | stays a per-file loop |

Net: pooling costs one transient uncompressed rewrite of a sample's reads,
but it buys the more meaningful semantics, the larger compute saving the
"quick preview" use-case wants, and a simpler single-shot trim.

**Refinement 1 — pool *inside* the SINTAX driver, not as a separate
Nextflow process.** The `SINTAX` task already receives the whole file list
for one barcode; pooling is a `pool_reads()` function at the top of
`assign_with_sintax.sh`. This keeps the DAG unchanged, avoids staging the
pooled fastq between processes, and leaves it a transient work-dir file.
(A separate `POOL` process would only pay off if the pooled fastq were a
published/reused artifact — it is not. Noted as the alternative.)

**Refinement 2 — pool only when subsampling is on.** When `subsample = 0`
(the default), the existing per-file trim loop runs **unchanged** — no
pooling, no extra I/O, no regression, and the current tests still cover it.
The pool→subsample→single-trim path is exercised only when the feature is
requested. (Alternative — always pool for one uniform code path — is
simpler code but taxes every run; rejected for the default-cost reason.)

### Design decisions

- **D-A1 — subsample before cutadapt, via per-barcode pooling** (resolved;
  see above).
- **D-A2 — parameter `subsample`, non-negative integer, default `0` =
  disabled (keep all reads).** Reuses the `randseed` sentinel convention
  and validation regex (`^\d+$`). CLI flag `--subsample n`.
- **D-A3 — tool: `vsearch --fastx_subsample` (no new dependency).** Verified
  (2.31.0): reads stdin; reproducible byte-for-byte with a fixed
  `--randseed`; **fatally aborts** with "Cannot subsample more reads than in
  the original sample" when `sample_size` > available. Reads/writes fastq
  (`--fastqout`) for the pre-trim raw reads.
- **D-A4 — count-first + empty guard (forced by D-A3).** After pooling,
  count the reads and subsample only when `count > n` — i.e. effectively
  take `min(actual, n)`; otherwise pass the pooled fastq through untouched.
  This is mandatory: `vsearch --fastx_subsample` **fatals** when asked for
  more reads than exist. `n` is a *cap*, not a requirement; an
  empty/primer-less barcode still yields an empty `.sintax` (SX-33) with no
  error. (A future vsearch release is expected to add an option to allow
  samples with fewer reads than requested; when it lands, the explicit
  count can be dropped in favour of that flag — but keep the count until the
  pinned vsearch version supports it, since the pin governs reproducibility.)
- **D-A5 — reuse the existing `randseed` for the subsample** (resolved: one
  knob governs all run randomness; a fixed positive seed makes the whole
  run reproducible single-threaded).
- **D-A6 — reproducible pooling order.** Sort the input file list before
  pooling so a fixed seed reproduces the same subsample regardless of the
  order files arrive from `groupTuple`.

### Target driver pipeline (`bin/assign_with_sintax.sh`)

```bash
if (( SUBSAMPLE > 0 )); then
    pool_reads > "${POOLED}"                       # decompress+concat, sorted order
    subsample_or_passthrough "${POOLED}" > "${SUBSAMPLED}"
    trim_primers "${SUBSAMPLED}" "${LOG}" \
        | append_read_length \
        | taxonomic_assignment_with_sintax > "${SINTAX_OUT}"
else
    # unchanged default path (per-file trim loop)
    { for FASTQ in "${FASTQ_FILES[@]}"; do trim_primers "$FASTQ" "$LOG"; done } \
        | append_read_length | taxonomic_assignment_with_sintax > "${SINTAX_OUT}"
fi
```

```bash
pool_reads() {                                     # mixed-compression → one fastq
    local f
    for f in "${FASTQ_FILES_SORTED[@]}"; do
        case "$f" in
            *.gz)  gzip  -cd -- "$f" ;;
            *.bz2) bzip2 -cd -- "$f" ;;
            *.xz)  xz    -cd -- "$f" ;;
            *)     cat       -- "$f" ;;
        esac
    done
}

subsample_or_passthrough() {
    local -r fastq="${1}"
    local -i n_reads=$(( $(wc -l < "${fastq}") / 4 ))   # ONT fastq = 4 lines/record
    if (( n_reads > SUBSAMPLE )); then
        "${VSEARCH}" --fastx_subsample "${fastq}" \
            --sample_size "${SUBSAMPLE}" --randseed "${RANDSEED}" \
            --quiet --notrunclabels --fastqout -
    else
        cat "${fastq}"                                  # n>=available → keep all
    fi
}
```

Consequence to document: with `discard_untrimmed = true`, some of the `n`
subsampled raw reads may carry no primer and be dropped, so **assigned reads
≤ n**. This is the intended "process n raw reads" semantics.

### Component changes

| File | Change |
| --- | --- |
| `nextflow.config` | add `subsample = 0` to `params` with a comment mirroring `randseed`. |
| `main.nf` | `helpMessage()`: document `--subsample`. Validation: `if (!("${params.subsample}" ==~ /\d+/)) errors << "  - 'subsample' must be a non-negative integer (got: '${params.subsample}')."` |
| `modules/sintax.nf` | pass `--subsample "${params.subsample}"` to the driver. |
| `bin/assign_with_sintax.sh` | parse `--subsample` (default `0`), validate `^[0-9]+$`; add `pool_reads` + `subsample_or_passthrough`; sort the file list; branch the final pipe on `SUBSAMPLE > 0`. Extend `usage()`. `pool_reads` needs `gzip`/`bzip2`/`xz` when the corresponding format is present — already implied by supporting those extensions. |
| fixtures | **none needed** — committed `barcode01` (5 primer-bearing reads → one taxon) covers cap / pass-through / reproducibility; `flat_dir/barcode01` (2 files, scattered) covers pooling; `barcode03` (primer-less) covers the ≤n / empty case. |

### Test-first specifications (extend `SPECIFICATIONS.md` §3, IDs `SX-`)

Pure-helper (`tests/bin/assign_with_sintax_helpers.bats`):

| ID | Spec |
| --- | --- |
| SX-25 | `pool_reads` concatenates a barcode's files (mixed compression, sorted order) into one uniform fastq whose record count is the sum across files. |

CLI (`tests/bin/assign_with_sintax_cli.bats`, gated by the existing
`cutadapt`/`vsearch` skip):

| ID | Spec |
| --- | --- |
| SX-15a | `--subsample 3` on the 5-read `barcode01` → exactly **3** rows in `.sintax`. |
| SX-15b | `--subsample 0` (and omitting the flag) keeps all **5**. |
| SX-15c | `--subsample 100` (> available) keeps all **5**, exit 0, no vsearch fatal error (D-A4). |
| SX-15d | `--subsample 3 --randseed 7` twice → **identical** `.sintax` (byte-for-byte) (D-A3/A5). |
| SX-15e | subsample the primer-less `barcode03` → `.sintax` exists and is **empty** (0 assigned though 3 raw were sampled — the ≤n / before-trim semantics; SX-33 unbroken). |
| SX-15f | scattered multi-file `flat_dir/barcode01` with `--subsample 3` → pooled then subsampled → exactly **3** rows (per-sample, not per-file). |
| SX-16a/b | negative / non-integer `--subsample` → clear stderr error, non-zero exit. |

Module (`tests/modules/sintax.nf.test`) + workflow (`tests/workflow/main.nf.test`):

| ID | Spec |
| --- | --- |
| SX-44 | `params.subsample = 3` on a 5-read barcode publishes a `.sintax` with 3 rows; `0` leaves 5. |
| WF-12a | end-to-end with `subsample = 3`: the `barcode01` column total is **3**. |
| WF-12b | startup validation aborts on a non-integer `subsample` (extend WF-11; report names `subsample`). |

### Sequencing (red → green per step)

1. SX-16a/b + SX-15b/e failing → add `--subsample` parse + validation +
   default-0 unchanged path → green.
2. SX-25 → add `pool_reads` (+ sorted list) → green.
3. SX-15a/c/d/f → add `subsample_or_passthrough` + the `SUBSAMPLE>0` branch
   → green.
4. WF-12b → `params.subsample` validation in `main.nf` → green.
5. SX-44 + WF-12a → thread `params.subsample` through `modules/sintax.nf` →
   green.
6. Docs + version: `SPECIFICATIONS.md` §3, `tests/README.md` coverage map,
   `CHANGELOG.md` (`## v1.6.0`), `README.md` (params + a `--subsample` note
   incl. the ≤n consequence), `--help`. Bump `manifest.version` **and**
   `params.version` to `1.6.0` (CFG-01) + `CITATION.cff`. `bash
   tests/run_all.sh` + a real local multi-barcode run.

---

## Feature B — Krona plots (`v1.7.0`)

### Motivation

Interactive [Krona](https://github.com/marbl/Krona) HTMLs give a zoomable,
per-sample view of the taxonomic profile straight from the occurrence
tables — a natural companion to the flat TSVs the labs read.

### Design decisions

- **D-B1 — source + outputs: convert **both** occurrence TSVs** (resolved
  per review). Produce two HTMLs mirroring the two tables:
  - `krona.html` from the **filtered** table (`params.results_table`);
  - `krona_optimistic.html` from the **optimistic** table.
  Each HTML holds **one dataset per barcode column** (a per-sample dropdown
  — "one krona per sample, grouped in a single html file"). Building from
  the tables we already produce and test byte-for-byte guarantees the plot
  matches the numbers the user sees, and reuses the `.collect()` →
  `BUILD_TABLE` gather.
- **D-B2 — convert the taxonomy structure in the tables** (resolved per
  review). Each TSV `taxonomy` cell (`d:Synthetica,k:...,s:Alpha_one`)
  splits on `,` into ordered Krona hierarchy levels. The `d:`/`p:`/… rank
  prefixes are **kept** (unambiguous, and matches the table); `unknown` → a
  single-level `unknown`. Probabilities are already absent from the TSVs
  (BT-23), so no stripping is needed — asserted.
- **D-B3 — tool: `ktImportText` (KronaTools, verified 2.8.1 installed).**
  Text/quantity mode takes hierarchy strings directly and needs **no NCBI
  taxonomy database** (unlike `ktImportTaxonomy`) — no large download, cheap
  CI. Multiple `file,label` inputs → one HTML with a per-dataset dropdown.
  New dependency: `bioconda::krona=2.8.1` (pulls perl).
- **D-B4 — split of work (mirrors the SINTAX driver pattern).**
  - `bin/build_krona.py` (stdlib only): one occurrence TSV → one Krona text
    file per non-empty barcode. Fully unit-testable on CI **without** krona.
  - `bin/build_krona.sh`: presence-check `ktImportText`; run the converter;
    `ktImportText <file,label> … -o <html>`. Runs once per input TSV.
- **D-B5 — empty barcodes: skip, and log which were skipped.** A wedge needs
  ≥1 count; an all-zero column carries no signal. Omit it and print a
  one-line note (the "no silent truncation" ethos of
  `build_occurrence_table.py`).
- **D-B6 — parameter + output.** `krona` boolean, default `false` (mirrors
  `discard_untrimmed`). When true, publish `krona.html` +
  `krona_optimistic.html` into `file(params.results_table).parent` (beside
  the TSVs) via `publishDir` + `params.publish_mode`.

### Target architecture

```
BUILD_TABLE ── results_table (filtered + optimistic .tsv) ──▶ KRONA (if params.krona)
                                                                for each TSV:
                                                                  build_krona.py → per-barcode .txt
                                                                  ktImportText file,label … -o <name>.html
                                                              → krona.html + krona_optimistic.html
```

`main.nf` — both TSVs are passed through (no filtered-only filter):
```groovy
include { KRONA } from './modules/krona'
...
BUILD_TABLE(...)
if (params.krona) {
    KRONA(BUILD_TABLE.out.results_table)   // emits both TSVs; driver maps each → its .html
}
```

The driver names the HTML per input TSV: a filename containing `_optimistic`
→ `krona_optimistic.html`, otherwise → `krona.html`.

### `bin/build_krona.py` — pure functions (unit-testable, no krona needed)

- `parse_header(line) -> list[str]` — barcode columns (drop `taxonomy`,`total`).
- `taxonomy_to_levels(tax) -> list[str]` — split on `,`; `unknown` → `["unknown"]`.
- `rows_for_barcode(rows, col_index) -> list[tuple[int, list[str]]]` — skip zero cells.
- `render_krona_text(rows) -> str` — lines `count\tlevel1\tlevel2\t…`.
- `write_sample_files(tsv, out_dir) -> list[Path]` — one `<barcode>.txt` per
  non-empty barcode, in column order; logs skipped empties (D-B5); creates
  `out_dir` if missing (mirror BT-05).

### Component changes

| File | Change |
| --- | --- |
| `bin/build_krona.py` | **new** (stdlib only) + `argparse` CLI (`--input`, `--output-dir`) + `validate_args` raising user-facing `ValueError`s (mirror `build_occurrence_table.py`). |
| `bin/build_krona.sh` | **new** driver: presence-check `ktImportText`; run the converter; build `file,label` args; `ktImportText … -o <html>`. Shellcheck-clean. |
| `modules/krona.nf` | **new** `KRONA` process: input both TSVs; output `path "*.html"`; `publishDir { file(params.results_table).parent }` + `params.publish_mode`; `tag "krona"`. |
| `main.nf` | include + conditional `KRONA(BUILD_TABLE.out.results_table)`; document `--krona`; validate `krona in [true,false]`. |
| `nextflow.config` | add `krona = false`; scope conda profile `withName: 'KRONA' { conda = "${projectDir}/environment.yml" }`. |
| `environment.yml` | add `bioconda::krona=2.8.1`; update header comment (ktImportText is perl; text mode needs no taxonomy DB). |
| `.github/workflows/test.yml` | add `krona=2.8.1` to `create-args` of **both** the `bats` and `nf-test` jobs (pins must match `environment.yml`). |
| fixtures | **new** `tests/fixtures/krona/occurrence.tsv` + `..._optimistic.tsv` — tiny hand-written tables (2 non-empty barcodes with multi-rank taxa, an `unknown` row, one all-zero barcode column, and optimistic-total ≥ filtered-total) so the Python tests are hermetic; add to `tests/fixtures/generate.sh`. The module test reuses them. |

### Test-first specifications (new §9 in `SPECIFICATIONS.md`, prefix `KR-`)

Python unit (`tests/bin/test_build_krona.py`, runs on CI with **no** krona):

| ID | Spec |
| --- | --- |
| KR-30 | `taxonomy_to_levels("d:X,k:Y,s:Z")` → `["d:X","k:Y","s:Z"]`; `"unknown"` → `["unknown"]`. |
| KR-31 | `taxonomy`/`total` columns are never treated as barcodes. |
| KR-32 | zero cells excluded; each emitted line's count equals the TSV cell exactly. |
| KR-33 | `render_krona_text` lines are `count<TAB>level…`, higher rank first. |
| KR-34 | one file per **non-empty** barcode; an all-zero barcode is skipped (D-B5) and reported. |
| KR-35 | no `(0.xx)` probability substrings appear in any level (BT-23 upheld). |

Python CLI (in the unittest or a small bats file):

| ID | Spec |
| --- | --- |
| KR-01 | missing `--input` → `--input is required`, non-zero. |
| KR-02 | missing `--output-dir` → `--output-dir is required`, non-zero. |
| KR-03 | non-existent `--input` → `Path does not exist`, non-zero. |
| KR-04 | `--output-dir` created if missing. |

Driver + module (`tests/bin/build_krona_cli.bats`, `tests/modules/krona.nf.test`)
— krona **is installed**, so these run for real (skip-if-absent kept as a
fallback, matching the cutadapt/vsearch convention):

| ID | Spec |
| --- | --- |
| KR-40 | `build_krona.sh` on the filtered fixture → a `krona.html` that exists, is non-empty, contains each non-empty barcode label + a Krona marker. |
| KR-41 | the HTML holds **one dataset per non-empty barcode**; the empty barcode is absent. |
| KR-42 | run on the optimistic fixture → `krona_optimistic.html`; both HTMLs are produced from the two tables and the optimistic one reflects ≥ the filtered signal (mirror BT-22). |

Workflow (`tests/workflow/main.nf.test`):

| ID | Spec |
| --- | --- |
| WF-13a | end-to-end with `krona = true` → both `krona.html` and `krona_optimistic.html` published beside the TSVs. |
| WF-13b | with `krona` false/unset → **no** krona HTML (the process does not run). |
| WF-13c | startup validation aborts on a non-boolean `krona` (extend WF-11). |

> Environment note: the KronaTools 2.8.1 install in this sandbox is broken —
> `lib/KronaTools.pm` is mode `600` owned by `nobody`, so `ktImportText`
> can't load its library. Make that file readable (or reinstall) before the
> KR-40..42 / WF-13a tests can run locally; CI installs a clean copy via
> micromamba.

### Sequencing (red → green per step)

1. Add the `krona/occurrence.tsv` + optimistic fixtures + `generate.sh` entry.
2. KR-30..35 + KR-01..04 → implement `bin/build_krona.py` → green (CI, no krona).
3. KR-40/41/42 → implement `bin/build_krona.sh`; add krona to
   `environment.yml` + CI → green.
4. WF-13c → `params.krona` + validation in `main.nf` → green.
5. WF-13a/b → `modules/krona.nf` + conditional `KRONA(...)` wiring → green.
6. Docs + version: `SPECIFICATIONS.md` §9, `tests/README.md` (layout +
   coverage map + krona in the dependency table), `CHANGELOG.md`
   (`## v1.7.0`), `README.md` (pipeline summary + a "Krona output" section
   + `--krona`), `--help`. Bump `manifest.version`/`params.version` to
   `1.7.0` (CFG-01) + `CITATION.cff`. `bash tests/run_all.sh` + a real local
   run with `--krona` and a browser check of both HTMLs.

---

## Cross-cutting checklist (each release)

- **Version sync (CFG-01):** `nextflow.config` `manifest.version` **and**
  `params.version` bumped together; `CITATION.cff` `version` +
  `date-released`.
- **Docs in lock-step:** `--help` in `main.nf`, the params block in
  `README.md`, `CHANGELOG.md`, `SPECIFICATIONS.md`, and the
  `tests/README.md` coverage map (the help is hand-written — no schema
  plugin).
- **Dependency pins match:** any `environment.yml` change is mirrored in
  `.github/workflows/test.yml` `create-args` (both tool-using jobs).
- **Green gate:** `bash tests/run_all.sh` (python + bats + nf-test) +
  `shellcheck -x` on tracked shell scripts, then one real local run.

## Resolved decisions

All design decisions are locked; the plan is ready to implement test-first.

- **D-A1** — subsample **before trim**, via a per-barcode pooling step.
- **D-A2** — `subsample` param, non-negative integer, default `0` = disabled.
- **D-A3/D-A4** — `vsearch --fastx_subsample`; count-first `min(actual, n)`
  guard (vsearch fatals otherwise; revisit when a future vsearch adds a
  fewer-reads-than-asked flag, behind a pin bump).
- **D-A5** — reuse the existing `randseed`.
- **D-A6** — sort the file list before pooling (reproducible seeded subsample).
- **Refinement 1** — pooling is a **driver function** in
  `assign_with_sintax.sh`, not a separate Nextflow process.
- **Refinement 2** — **conditional** pooling: pool only when `subsample > 0`;
  the `subsample = 0` default keeps the existing per-file trim loop unchanged.
- **D-B1** — Krona for **both** tables → `krona.html` + `krona_optimistic.html`.
- **D-B2** — convert the tables' `taxonomy` structure into Krona levels
  (rank prefixes kept).
- **D-B3** — `ktImportText` (KronaTools **2.8.1**, verified working
  end-to-end), text mode, no taxonomy DB.
- **D-B5** — Krona empty barcodes: **skip + log** (do not render empty
  datasets).

Next step: implement **Feature A (`v1.6.0`)** following the red → green
sequencing above, then **Feature B (`v1.7.0`)**.
