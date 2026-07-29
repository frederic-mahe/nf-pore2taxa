# Testable specifications for nf-pore2taxa

This document lists the observable behaviours of the pipeline that are
worth pinning down with automated tests. It is a living document: when
a behaviour changes intentionally, update the spec; when a behaviour
changes accidentally, the corresponding test should catch it.

## Ground rules

- **Out of scope.** `dorado`, `cutadapt`, and `vsearch` are third-party
  tools with their own test suites. We do **not** assert their
  internal behaviour (e.g. exact base calls, exact trimmed sequences,
  exact taxonomic assignments). We only assert that our pipeline
  invokes them correctly and processes their outputs correctly.
- **What we lock in.** Structural and invariant properties of outputs
  (file existence, headers, column counts, row counts, barcode
  bookkeeping), plus full byte-level checks on artefacts produced by
  our own code (the occurrence tables written by
  `build_occurrence_table.py`).
- **Determinism.** Where upstream tools are non-deterministic (sintax
  with `--threads > 1`), tests assert ranges/invariants, not exact
  counts.

## 1. Top-level workflow (`main.nf`)

| ID    | Specification                                                                                                                                                |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| WF-01 | When `skip_basecall = true`, the workflow does not instantiate `BASECALL` and reads from `params.fastq_dir`.                                                 |
| WF-02 | When `skip_basecall = false`, `BASECALL` runs and its sentinel `done_basecalling.txt` is the upstream signal for `SINTAX`.                                   |
| WF-03 | The pipeline aborts if `params.sintax_references` does not exist (`checkIfExists: true`).                                                                    |
| WF-04 | The pipeline aborts if `params.fastq_dir` does not exist when `skip_basecall = true`.                                                                        |
| WF-05 | The pipeline aborts if `params.pod5_dir` does not exist when `skip_basecall = false`.                                                                        |
| WF-06 | With a valid fixture, the workflow produces exactly two TSV files at `params.results_table`: the filtered table and a sibling `<name>_optimistic.<ext>` one. |
| WF-07 | The workflow exits 0 on the happy path and non-zero on any process failure.                                                                                  |
| WF-08 | `params.sintax_silva` is accepted as a deprecated alias for `params.sintax_references`: when only the alias is set, it drives the workflow (nf-test) and a deprecation warning naming `sintax_silva` is emitted via `log.warn` (`tests/config/deprecation.bats`). |
| WF-09 | When both are set, `params.sintax_references` takes precedence over the deprecated `params.sintax_silva` alias.                                                |
| WF-10 | The pipeline aborts if the path supplied via the deprecated `params.sintax_silva` alias does not exist (`checkIfExists: true`).                               |
| WF-11 | Startup parameter validation aborts before any process runs, with a single aggregated `Parameter validation failed` report, when a required value is missing (`sintax_references`, `results_table`, `primer_f`, `primer_r`, the mode-appropriate `fastq_dir`/`pod5_dir`) or when `discard_untrimmed`/`publish_mode` hold an invalid value. |
| WF-12 | End-to-end, `params.subsample = n` caps each barcode at `n` reads: with `subsample = 3` a 5-read barcode's column totals 3 (a); a non-integer `subsample` aborts at startup via the aggregated validation report (b). |
| WF-13 | `params.krona = true` renders `krona.html` and `krona_optimistic.html` beside `results_table` (a); the default (`false`) runs no `KRONA` and produces no HTML (b); a non-boolean `krona` aborts at startup via the aggregated validation report (c). |
| WF-14 | Boolean params set on the command line arrive as strings (`'true'`/`'false'`), so `discard_untrimmed` is validated and switched on the string form: `discard_untrimmed = "false"` is honoured as `--keep-untrimmed` (the primer-less `barcode03` survives and is counted), not rejected and not mis-read as truthy. Same coercion as `krona` (WF-13). |
| WF-15 | `results_table` is honoured whatever its extension: `results/table.txt` publishes `table.txt` + `table_optimistic.txt` (and, with `--krona`, both HTMLs). `BUILD_TABLE` declares its outputs by exact name, so a non-`.tsv` name no longer runs the whole pipeline and then fails the last task on a missing output. |
| WF-16 | `skip_basecall` is validated and branched on the string form, like every other boolean (WF-14): `skip_basecall = "false"` is honoured as false — basecalling is *not* skipped, so the `pod5_dir` requirement applies (a); a non-boolean value such as `"yes"` is rejected at startup rather than silently read as truthy (b). |
| WF-17 | `fastq_dir` is required in **both** modes, not only when `skip_basecall = true`: `BASECALL` publishes into it and `SINTAX` publishes each barcode's results beneath it, so leaving it unset used to resolve `publishDir 'null/...'` and silently write a directory named `null` — after basecalling had run. |

## 2. `BASECALL` module + `basecall_pod5_files.sh`

Basecalling is **local-only**: `dorado` is an Oxford Nanopore GPU binary
that is not on bioconda, so it is in neither `environment.yml` nor any
container built from it, and the cluster profiles route partitions by memory
and time. A run that requests basecalling under a scheduler is refused at
startup (CLU-09).

The real dorado needs a GPU and a ~1 GB model download, so it can never run
in CI. `tests/stubs/dorado` records the argv it was called with and
fabricates the expected outputs, which covers everything that is *ours*: the
parameters reaching the tool, the model cache, the published artefacts and
the flow onward into discovery. We do not test basecalling itself.

Until v1.11.0 the model, kit and device were hardcoded in the shell script
and not exposed as parameters at all, so a lab with a different sequencing
kit could not basecall.

| ID    | Specification                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BC-01 | `--help` exits 0 and prints the usage block, including `--device` and `--models-dir`.                                                                   |
| BC-02 | A missing `--input-dir` (a) or `--output-dir` (b) is a clear error.                                                                                    |
| BC-03 | An `--input-dir` that does not exist is a clear error.                                                                                                 |
| BC-04 | An unrecognised `--model` is rejected, and the message shows both accepted forms (a). A **full** dorado model name is accepted and passed through untouched, which is how other flowcells and chemistries are targeted — the prefix `dna_r10.4.1_e8.2_400bps_` was hardcoded, so only that chemistry could ever be basecalled (b). |
| BC-05 | An unrecognised `--kit-name` is rejected.                                                                                                              |
| BC-06 | An unknown flag exits non-zero with `Unknown option:` (a); an unrecognised `--device` is rejected (b).                                                  |
| BC-07 | The defaults are `sup@v5.2.0`, `EXP-PBC096` and `cuda:0`, asserted by inspecting the argv the dorado stub received. A short model name is prefixed for the *download* and passed as given to the *basecaller*, which resolves it against `--models-directory`. |
| BC-08 | End-to-end (`main.nf`): basecalling publishes `done_basecalling.txt` and the `fastq_pass` hierarchy into `params.fastq_dir`, and the sentinel carries the run onward — discovery and assignment produce both tables with one column per basecalled barcode (a). This also closes WF-02 and WF-05. An invalid basecalling parameter aborts at startup, before any GPU work (b); those parameters are **not** policed when `skip_basecall = true`, since holding a run to the format of settings it never applies would be gratuitous, and they are then absent from `params.json` (c). |
| BC-09 | `--model`, `--kit-name` and `--device` are each overridable (a), and `cpu` is a valid device, so a machine with no GPU can basecall (b).                |
| BC-10 | A model already present in `--models-dir` is **not** downloaded again (a), and the model directory survives the script's own `clean_up` (b). Previously the model was fetched into the output directory and then deleted, so every run re-downloaded ~1 GB and every run needed network; the pipeline now holds it in a `storeDir` cache outside the work directory. |
| BC-11 | The script confines itself to `--output-dir`. `clean_up` and `compress_fastq` used to walk `.` — the *caller's* directory — moving and deleting directories there; invisible under Nextflow, where the two coincide, and destructive when run by hand from anywhere else (a). A `fastq_pass` already at the top of the output directory is not moved onto itself, which used to abort the script under `set -e` (b) — and that is the pipeline's own layout. |
| BC-12 | The model-prefix logic in `bin/basecall_pod5_files.sh` and in `modules/local/functions.nf` agree. One decides where to *look* for the model and the other where to *download* it, so a mismatch means fetching to one path and looking in another. |

## 3. `SINTAX` module + `assign_with_sintax.sh`

### 3.1 Script-level CLI behaviour (`assign_with_sintax.sh`)

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SX-01  | `--help` exits 0 and prints usage.                                                                                                                     |
| SX-02  | Missing `--barcode`, `--references`, `--forward-primer`, or `--reverse-primer` each yield a clear stderr error and a non-zero exit code.               |
| SX-03  | Non-integer or non-positive `--threads` yields a clear error.                                                                                          |
| SX-04  | A FASTQ argument that does not exist or is not readable yields a clear error.                                                                          |
| SX-05  | The script takes one or more FASTQ files (positional args) belonging to one barcode; each supported extension (`.fastq`, `.fastq.gz`, `.fastq.bz2`, `.fastq.xz`) is accepted. An invocation with no FASTQ argument yields `Error: no fastq files given ...`. |
| SX-06  | `--references` that does not exist or is not readable yields a clear error.                                                                            |
| SX-07  | A primer containing non-IUPAC characters yields an error.                                                                                              |
| SX-08  | A primer shorter than 10 nt emits a *warning* to stderr but does not abort.                                                                            |
| SX-09  | If `vsearch` is older than the documented minimum (`2.31.0`), the script aborts with a clear error.                                                    |
| SX-10  | Unknown long flags exit non-zero with `Unknown option:` on stderr.                                                                                     |
| SX-11  | Missing `--barcode` yields a clear error (positional args are fastq files, so they are no longer rejected).                                            |
| SX-12  | `--references` is sniffed at startup and must be **sintax-formatted**: its first FASTA header must carry a `tax=` annotation (`>id;tax=d:...,p:...;`). A file whose first line is not a `>` header, or a FASTA header with no `tax=`, aborts before any process runs. Only the first line is read; plain and gzip (`.gz`) references are sniffed; a bzip2 (`.bz2`) reference is skipped with a warning; a missing/unreadable path is left for SX-06. Mirrors nf-metabarcoding's `[S73]`. |
| SX-13  | Primer-presence filtering is toggleable. By **default** (`--discard-untrimmed`, the script default and `params.discard_untrimmed = true`) a read is dropped unless both the forward primer and the reverse-complemented reverse primer are located — so a barcode of primer-less reads yields an empty `.sintax`. With `--keep-untrimmed` (`params.discard_untrimmed = false`) every read is kept and merely trimmed where a primer is found, so the same barcode yields a non-empty `.sintax`. |
| SX-14  | `--randseed` sets vsearch's random generator seed (default `0`, a pseudo-random seed). A valid non-negative integer is accepted; a negative or non-integer value yields a clear stderr error and a non-zero exit code. |
| SX-15  | `--subsample n` (default `0` = disabled) caps the barcode at `n` reads **before** trimming: the FASTQ files are pooled, then subsampled with `vsearch --fastx_subsample` (seeded by `--randseed`). `n=0` and an omitted flag keep every read (a); `n` smaller than the pool caps the assigned reads at `n` (a, and per-sample-not-per-file for a scattered barcode, f); `n` ≥ the pool keeps all reads with no vsearch fatal (c, the `min(available, n)` guard); a fixed `--randseed` makes the subsample reproducible (d); a primer-less barcode still yields an empty `.sintax` because the cap precedes trimming (e). |
| SX-16  | A negative or non-integer `--subsample` yields a clear stderr error (`--subsample must be a non-negative integer`) and a non-zero exit code. |

### 3.2 Pure-function helpers

These functions in `assign_with_sintax.sh` are deterministic and
trivially unit-testable in a shell test runner (e.g. `bats-core`):

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ~~SX-20~~ | **Removed.** `trim_extension` was used to derive a per-file output name; the per-barcode refactor (v1.4.0) names outputs after the barcode, so the helper is gone. |
| ~~SX-21~~ | **Removed** with `trim_extension` (see SX-20).                                                                                                       |
| SX-22  | `reverse_complement`: complements `ACGT/U/IUPAC ambiguity codes` correctly and reverses the string. `N` and `I` are their own complements.             |
| SX-23  | `reverse_complement`: handles lower-case input and preserves case.                                                                                     |
| SX-24  | `reverse_complement`: empty string input aborts with a clear error.                                                                                    |
| SX-25  | `pool_reads`: concatenates a barcode's FASTQ files (mixed compression: `.gz`/`.bz2`/`.xz`/plain) in **sorted** order into one uniform fastq stream whose record count is the sum across the files. Sorting keeps a seeded subsample reproducible regardless of `groupTuple` order. |

### 3.3 Module-level behaviour (`modules/sintax.nf`)

Tested via `nf-test` against a tiny fastq fixture and reference DB. The
module runs **one task per barcode** (the reference is loaded once per
barcode, not once per file).

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SX-30  | For each input `tuple(barcode, [fastqs])` the module produces one `<barcode>.sintax` and one `<barcode>.log`, published under `fastq_pass/<barcode>/`. |
| SX-31  | Each `*.sintax` row, if present, has exactly **4** tab-separated fields (`query`, `full_taxonomy`, `strand`, `taxonomy`).                              |
| SX-32  | Query identifiers in `*.sintax` carry a `;length=N` annotation appended by `append_read_length` (regex: `;length=[0-9]+$` on column 1).                |
| SX-33  | If a barcode's reads do not survive primer trimming, its `<barcode>.sintax` exists and is empty (0 bytes); it is emitted (non-optional) so it reaches `BUILD_TABLE`. |
| ~~SX-34~~ | **Removed.** The `done_sintax.txt` sentinel is gone; the gather is now a real `.collect()` data dependency on the per-barcode `.sintax` outputs.    |
| SX-35  | The pipeline is idempotent: re-running with `-resume` against an unchanged input tree is a **full** cache hit (no task re-executed). Covered in `tests/config/resume.bats`, which drives two successive `nextflow run` invocations — a shape nf-test cannot express. Paired with DSC-06, which pins the other half: a *changed* tree must not be a cache hit. |
| SX-36  | Each supported extension (`.fastq`, `.fastq.{gz,bz2,xz}`) is accepted (covered at the CLI level by SX-05).                                             |
| SX-40  | A barcode split across **several** fastq files is trimmed file-by-file, concatenated, and assigned with a **single** `vsearch` run, producing one `<barcode>.sintax` whose read count is the sum across the files. |
| SX-41  | End-to-end (`main.nf`): a **flat** `fastq_pass/` (barcode embedded in the filename) with a multi-file barcode produces a correct table, and a sibling `fastq_fail/` is **ignored** (its reads are not counted). |
| SX-44  | With `params.subsample = n > 0`, the module caps each barcode at `n` reads (pool → subsample → trim): a 5-read barcode with `subsample = 3` publishes a `.sintax` with 3 rows; `subsample = 0` leaves all 5. |

### 3.4 Barcode discovery (`bin/discover_barcodes.py`)

Discovery walks the `fastq_pass` tree and groups fastq files by barcode
for the per-barcode fan-out. The barcode is derived from the path
*relative to* `fastq_pass` with the same `BARCODE_PATTERN`
(`barcode[0-9]+|unclassified|mixed`) as `build_occurrence_table.py`.
Covered by `tests/bin/test_discover_barcodes.py`.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| DSC-01 | The barcode token is found whether it is a directory component (`barcode01/reads.fastq.gz`) or embedded in the filename (`FAX_..._barcode01_0.fastq.gz`). |
| DSC-02 | Files of one barcode are grouped together; a multi-file barcode yields multiple rows with the same barcode (later `groupTuple`d into one SINTAX task). |
| DSC-03 | A barcode-like token in a **parent** directory is not picked up (matching is on the path relative to the input dir).                                   |
| DSC-04 | A file with **no** recognisable barcode token aborts the run (D2), listing the offending paths; an input dir with no fastq files, or that is not a directory, also aborts with a clear error. |
| DSC-05 | Discovery is rooted at `fastq_pass`, so a sibling `fastq_fail/` is never seen (also asserted end-to-end by SX-41).                                     |
| DSC-06 | Discovery's Nextflow cache key reflects the **set of fastq files present**, not just the directory path. `main.nf` enumerates the reads and passes the sorted list into `DISCOVER_BARCODES`, so on `-resume`: a fastq added to an **existing** barcode directory is picked up and that barcode's column grows (a); the untouched barcodes stay cached, so the invalidation is targeted rather than a blanket miss (b); a **new** barcode directory is picked up (c); a **removed** fastq is reflected too (d). Before v1.7.1 case (a) was a silent full cache hit that republished the previous table — the run reported SUCCESS with the new reads dropped. |
| DSC-07 | `fastq_extensions()` (`modules/local/functions.nf`, used to build that cache key) and `FASTQ_SUFFIXES` (`discover_barcodes.py`, used to walk the tree) list the **same** extensions. A drift guard, not a behaviour: an extension in one and not the other means a file that is discovered without invalidating the cache, or the reverse. |

## 4. `BUILD_TABLE` module + `build_occurrence_table.py`

This is **the most important target** because all of the logic is
ours. The Python script (standard library only — no R/tidyverse) is a
pure function from a directory of `.sintax` files to two TSV files, so
it can be tested deterministically and at fine granularity. The port is
byte-for-byte compatible with the former R implementation.

### 4.1 CLI / validation

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BT-01  | Missing `--input-dir` aborts with `--input-dir is required`.                                                                                           |
| BT-02  | Missing `--output` aborts with `--output is required`.                                                                                                 |
| BT-03  | `--input-dir` that does not exist aborts with `Path does not exist`.                                                                                   |
| BT-04  | `--input-dir` that points to a file (not a directory) aborts with `not a directory`.                                                                   |
| BT-05  | Output parent directory is created if missing.                                                                                                         |
| BT-06  | An input directory with no `*.sintax` files aborts with `No sintax files found`.                                                                       |
| BT-07  | The optimistic file path is `<stem>_optimistic.<ext>`, derived from `--output` by inserting `_optimistic` before the final extension.                  |

### 4.2 Output table structure (filtered)

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BT-10  | The output is tab-separated and starts with a header row: `taxonomy\ttotal\t<barcode names...>`.                                                       |
| BT-11  | Column `total` equals the row-wise sum of all barcode columns.                                                                                         |
| BT-12  | Rows are sorted by `total` descending, then `taxonomy` ascending.                                                                                      |
| BT-13  | Non-empty barcodes appear before empty barcodes in the column order; empty barcodes are appended at the right, filled with zeros.                      |
| BT-14  | Reads without a sintax assignment (empty/missing column 4) are bucketed under `taxonomy == "unknown"`.                                                 |
| BT-15  | Each `(taxonomy, barcode)` cell is the read count for that pair; missing pairs are filled with `0`.                                                    |
| BT-16  | Barcode names are extracted from the file path with the regex `barcode[0-9]+|unclassified|mixed` — i.e. directory clutter does not pollute names.      |
| BT-17  | Probabilities in `full_taxonomy` (e.g. `d:Fungi(0.99)`) are stripped from the filtered table's `taxonomy` column.                                      |

### 4.3 Output table structure (optimistic)

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BT-20  | The optimistic table has the same structure (columns, sort order, empty-barcode handling) as the filtered one.                                         |
| BT-21  | The optimistic `taxonomy` column is derived from `full_taxonomy` (column 2 of `.sintax`), retaining low-confidence levels that the filtered table drops. |
| BT-22  | Total reads in the optimistic table ≥ total reads in the filtered table when both contain assignments (no reads are lost when keeping low-confidence). |
| BT-23  | The probability annotations are still stripped (no `(0.xx)` substrings remain in the `taxonomy` column).                                               |
| BT-24  | An all-blank filtered column (every read unassigned) neither aborts nor vanishes: those reads are bucketed under `taxonomy == "unknown"` (the column form of BT-14). |
| BT-25  | A barcode with at least one non-empty `.sintax` chunk is never re-added as an empty column; only barcodes whose every chunk is empty appear, once, as zero-filled right-most columns. |

### 4.4 Pure helper functions (unit-testable via `python3 -m unittest`)

Covered by `tests/bin/test_build_occurrence_table.py`, which imports the
script's functions directly.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BT-30  | `name_optimistic_output("foo.tsv") == "foo_optimistic.tsv"`; `name_optimistic_output("a/b/foo.tsv") == "a/b/foo_optimistic.tsv"`.                      |
| BT-31  | `partition_by_size` splits files into (non-empty, empty) — exact complements on existing files.                                                        |
| BT-32  | `extract_barcode` reduces a path-like string to the barcode token using `BARCODE_PATTERN` (`barcode[0-9]+|unclassified|mixed`).                        |
| BT-33  | `strip_probabilities` removes the `(0.xx)` probability suffixes from every rank.                                                                       |
| BT-34  | `mark_unassigned` replaces empty/`None` taxonomy values with the literal string `"unknown"`.                                                           |
| BT-35  | `count_assignments` produces one count per `(barcode, taxonomy)` pair.                                                                                 |
| BT-36  | `render_table` adds a `total` column equal to the sum across barcodes for each taxonomy.                                                               |
| BT-37  | `render_table` appends one zero-filled column per empty barcode, preserving existing column order.                                                     |
| BT-38  | `main` on an empty input set returns a non-zero exit code with `No sintax files found`.                                                                |

## 5. `bin/lib/validation.sh`

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| VL-01  | `require_arg "X" ""` returns non-zero and prints `Error: X is required.` to stderr.                                                                    |
| VL-02  | `require_arg "X" "something"` returns 0 and prints nothing.                                                                                            |
| VL-03  | `check_readable file <path> <label>` returns 0 for a readable file, non-zero with `not found` for a missing file, non-zero with `is not readable` for an unreadable one. |
| VL-04  | `check_readable dir <path> <label>` mirrors the file behaviour for directories.                                                                        |

## 6. Config invariants (`nextflow.config`)

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| CFG-01 | `manifest.version` and `CITATION.cff`'s `version` resolve to the same value (bump both on every release, per the CHANGELOG). Tested in `tests/config/version.bats`. Until v1.7.1 this compared `manifest.version` with `params.version`, which nothing read — a dead invariant; the param is gone, and (b) asserts it stays gone. |
| CFG-02 | `publish_mode` accepts `link` (default), `copy`, `copyNoFollow`, `symlink` and `rellink`, and rejects anything else. `move` is deliberately **not** accepted: `BASECALL`'s downstream handoff reads the freshly written `fastq_pass` back out of the task work directory, which moving the files away empties. `cleanup` defaults to **false**. |
| CFG-03 | `cleanup = true` combined with a link publish mode (`symlink`/`rellink`) aborts at startup, before any process runs. The two together published links *into* the work directory and then deleted it, leaving every output — both tables, every `.sintax`, both Krona HTMLs — a dangling link under a run that reported SUCCESS. `copy` + `cleanup` is allowed (real files survive), and a non-boolean `cleanup` is rejected like any other boolean (WF-16). |
| CFG-04 | **Resource ceiling.** `process.resourceLimits` clamps every per-process request — including a retry's `* task.attempt` escalation — to `params.max_cpus` / `params.max_memory`. The defaults are the running machine's own capacity, obtained from the same helper the local executor uses for its "requirement exceeds available" check, so a request can never exceed what the executor will allow: (a) the default ceiling equals the host's core count; (b) `resourceLimits` is wired to the two params; (c) the `cluster` profile sets both **explicitly** and never auto-detects, because under a scheduler the detected value describes the *submit* host and would silently shrink every submitted job; (d) an explicit `--max_cpus`/`--max_memory` wins, reported by the startup notice; (e) a non-positive `max_cpus` and (f) an unparseable `max_memory` abort at startup rather than at first task submission; (g) end-to-end, the **production** resource config (SINTAX asking 20 cpus / 16 GB) runs to completion under a 2-cpu / 3 GB ceiling, with `--threads 2` reaching vsearch — i.e. the request is reduced, not refused. |
| CFG-05 | `manifest` declares a minimum Nextflow version (a) and a default branch (c). The floor must stay **>= 24.04** (b), the release that added `process.resourceLimits`: an older Nextflow ignores the unknown directive silently, so CFG-04's clamping would stop working with no diagnostic. |
| CFG-06 | **Startup run summary.** Every result-affecting parameter is logged before any process runs, so the run log is a provenance record: the pipeline and its version (a); all of mode/`fastq_dir`/`sintax_references`/`results_table`/primers/`discard_untrimmed`/`subsample`/`randseed`/`krona`/`publish_mode`/`cleanup` plus the resolved ceiling and effective thread count (b); the two input modes are distinguished and `pod5_dir` is omitted when skipping basecalling (c); ambiguous values are spelled out, e.g. `discard_untrimmed` as "strict amplicon filtering" vs "keep every read" (d), `randseed = 0` as pseudo-random (e). The `randseed` warning fires when a fixed seed meets more than one SINTAX thread, naming `--max_cpus 1` as the remedy (f), and does **not** fire when the run is genuinely single-threaded (g); an overridden ceiling is reflected in both the ceiling and the thread count (h). |

## 7. Observations worth noting in the spec (not bugs, but ambiguities)

| ID     | Note                                                                                                                                                   |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ~~OBS-01~~ | **Resolved.** `validate_inputs` in `assign_with_sintax.sh` originally counted only `*.fastq.gz` when deciding whether the input dir was empty, contradicting the script's main loop and the v1.1.0 CHANGELOG. Validation now uses the same `FASTQ_REGEX` constant as the main loop. Covered by SX-05 + the `SX-05-{gz,plain,bz2,xz,empty}` cases in `tests/bin/assign_with_sintax_cli.bats`. |
| ~~OBS-02~~ | **Resolved.** Described `trim_extension`'s multi-suffix behaviour and SX-21, both removed with the per-barcode refactor (v1.4.0, see SX-20).      |
| OBS-03 | `SINTAX` runs vsearch with `--threads > 1`, which is non-deterministic. SX-3x tests must therefore be structural (counts, columns) rather than exact. |
| OBS-04 | The script silently creates the output parent directory (`build_occurrence_table.py`, `validate_args`). BT-05 pins this behaviour; flag if you want it to fail loudly instead. |
| OBS-05 | `param.results_table` is consumed by `BUILD_TABLE` as `file(params.results_table).name` for the output filename, and `file(params.results_table).parent` for the `publishDir`. The *extension* half is now pinned by WF-15; the bare-filename form (no directory component) is still uncovered. |

## 8. `KRONA` module + `build_krona.py` / `build_krona.sh`

The optional `--krona` step turns the occurrence tables into interactive
Krona HTML charts. As with `BUILD_TABLE`, the data munging is ours and
fully unit-tested (stdlib Python, no Krona needed); Krona's `ktImportText`
is a third-party tool we only drive, so the driver/module tests assert the
HTML is produced with the right datasets, not Krona's rendering internals.

### 8.1 CLI / validation (`build_krona.py`)

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| KR-01  | Missing `--input` aborts with `--input is required`.                                                                                                   |
| KR-02  | Missing `--output-dir` aborts with `--output-dir is required`.                                                                                         |
| KR-03  | `--input` that does not exist aborts with `Path does not exist`.                                                                                       |
| KR-04  | The output directory is created if missing, and per-barcode files are written into it.                                                                |

### 8.2 Pure conversion helpers (`build_krona.py`)

Covered by `tests/bin/test_build_krona.py`, which imports the script directly.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| KR-30  | `taxonomy_to_levels("d:X,k:Y,s:Z")` → `["d:X","k:Y","s:Z"]`; `"unknown"` → `["unknown"]` (rank prefixes kept).                                         |
| KR-31  | `parse_header` never treats the `taxonomy` / `total` columns as barcodes.                                                                              |
| KR-32  | Zero-count cells are excluded; each emitted line's count equals the TSV cell exactly.                                                                  |
| KR-33  | `render_krona_text` lines are `count<TAB>level…`, higher rank first; an empty row set renders to the empty string.                                     |
| KR-34  | One `<barcode>.txt` per **non-empty** barcode, in column order; an all-zero barcode is skipped and reported on stderr (no silent truncation).          |
| KR-35  | No `(0.xx)` probability substrings appear in any emitted level (they are already stripped from the tables, BT-23).                                     |

### 8.3 Driver + module (`build_krona.sh`, `modules/krona.nf`)

Needs `ktImportText` (KronaTools) on PATH; skips gracefully if absent.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| KR-40  | `build_krona.sh` on an occurrence table produces a non-empty `krona.html` that carries a Krona marker and the fixture's leaf taxa.                     |
| KR-41  | The HTML holds one dataset per **non-empty** barcode (labelled by barcode name); an all-zero barcode never becomes a dataset.                          |
| KR-42  | Given both tables, the driver names outputs by input: `krona.html` for the filtered table, `krona_optimistic.html` for the `_optimistic` one.          |

## 9. Shared helper functions (`modules/local/functions.nf`)

Small pure functions included by `main.nf` and the process modules, so
the boolean-parameter handling lives in one place. Tested directly with
nf-test's function harness (`tests/modules/functions.nf.test`).

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| FN-01  | `coerce_bool(v)` returns a real Boolean: the string `'true'` and Boolean `true` → `true`; `'false'`, `false`, and any other value → `false`. This normalises a config boolean and a CLI `--flag`/`--flag false` (which arrives as a string) alike. |
| FN-02  | `valid_bool(v)` is `true` only when `v` is a Boolean or the string `'true'`/`'false'`; any other value (e.g. `'yes'`) is `false`. Startup validation uses it to reject non-boolean values before `coerce_bool` flattens them. **Every** declared boolean param goes through it, from one list in `main.nf` — a new boolean that skips it repeats the `skip_basecall` defect (WF-16). |
| FN-03  | `optimistic_name(name)` inserts `_optimistic` before the final extension: `sintax.tsv` → `sintax_optimistic.tsv` (a); `table.txt` → `table_optimistic.txt` (b); `table` → `table_optimistic` (c); it splits on the **last** dot only, so `run.1.tsv` → `run.1_optimistic.tsv` (d); a leading dot is not an extension, so `.hidden` → `.hidden_optimistic` (e), matching `pathlib`. Must agree with `name_optimistic_output()` in `build_occurrence_table.py` for every shape, because `BUILD_TABLE` declares its outputs by name (WF-15) — a disagreement is a "missing output file" at the end of a run. |
| FN-04  | `fastq_extensions()` returns the four supported suffixes without a leading dot (`fastq`, `fastq.gz`, `fastq.bz2`, `fastq.xz`), for interpolation into the `**.<ext>` globs that build discovery's cache key. Kept in lock-step with the Python side by DSC-07. |
| FN-05  | `valid_memory(v)` is `true` for anything Nextflow can read as a positive memory size, in both forms `max_memory` arrives in: a CLI string (`'32.GB'`, `'125.3 GB'`) and a real `MemoryUnit` (`8.GB`) (a–c). It is `false` for a non-memory string, a malformed size (`'8.5.GB'`), zero — which parses but would clamp every request to nothing — and a negative size (d–g). Used by startup validation so a bad ceiling is caught before the first task submission, where it otherwise surfaces as a bare "Not a valid FileSize value". |
| FN-06  | `effective_threads(configured, ceiling)` is the thread count a process really gets: the lower of its configured request and the resource ceiling (a–d), never less than 1 (f). A request that cannot be read as a number (e.g. `cpus` set to a closure) is assumed to want the whole ceiling (e) — the conservative reading for a warning. The `randseed` warning keys off this rather than the configured value, so `--max_cpus 1` is not warned about. |

## 10. Provenance (`DUMP_VERSIONS`, `DUMP_PARAMS`, execution reports)

Every run must be able to explain itself. One directory beside the
occurrence tables — `pipeline_info/`, the layout `--outdir` will adopt —
holds what software ran, with what settings, and what the execution cost.
Two labs comparing tables can then diff those files instead of guessing.

As elsewhere, we assert *our* artefacts, not the tools' self-reporting: we
do not check that vsearch states its own version correctly, only that we
capture, extract and record it faithfully.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| PRV-01 | `software_versions.yml` is published to `pipeline_info/` and records `vsearch`, `cutadapt`, `krona`, `python`, plus the pipeline release and the Nextflow that ran it. Keys are sorted, so two runs' files are directly comparable. |
| PRV-02 | A tool that cannot be probed is recorded as `n/a`, never dropped: an absent line reads as "not used", which is a different and more misleading claim than "could not determine". |
| PRV-03 | `dorado`'s version comes from `BASECALL` itself, as a `<name><TAB><raw>` fragment merged by `DUMP_VERSIONS` — dorado is an ONT GPU binary absent from the conda environment, and on a cluster may not exist on the node the probe runs on, so the task that actually ran it is the only honest source. No `dorado` line appears when `skip_basecall = true`. |
| PRV-04 | `params.json` is published to `pipeline_info/` holding exactly the JSON `main.nf` rendered — byte-preserved, including values containing shell metacharacters (the process uses a quoted heredoc; an unquoted one would let the shell expand a path and silently misreport the run's inputs). |
| PRV-05 | The four execution reports (`execution_report.html`, `execution_timeline.html`, `execution_trace.txt`, `pipeline_dag.html`) are written to `pipeline_info/` on **every** run, with no flag required (a); the trace carries requested-vs-observed resource columns (`cpus`, `memory`, `realtime`, `peak_rss`) so a lab can see how the v1.8.0 ceiling affected a step (b); `overwrite = true`, so a re-run refreshes them in place instead of aborting at the *end* of the run because the file exists (c). |
| PRV-06 | End-to-end, `software_versions.yml` records real versions for the tools that ran (a) and no `dorado` entry when basecalling was skipped (b). |
| PRV-07 | End-to-end, `params.json` records the **effective** configuration: the values actually in force (a); booleans as JSON booleans rather than the CLI's truthy `'false'` string (b); and `sintax_references` as the path actually read after the deprecated `sintax_silva` alias is resolved (c). |
| PRV-08 | Provenance sits *beside* the analysis outputs, not among them: the results directory holds only the tables, with all metadata under `pipeline_info/` (a). The provenance tasks do not defeat `-resume`: an unchanged re-run still re-executes nothing, which is why `params.json` deliberately omits the session id and command line (b). |
| PRV-10 | `collect_versions.py::extract_version` finds the version token in every shape the real tools print: `vsearch v2.31.0_linux_x86_64, ...`, a bare `5.2`, `Python 3.12.3`, the KronaTools banner, and dorado's `1.1.1+3c7eef9` git-describe form (the build hash is dropped). |
| PRV-11 | Unrecognisable output (empty, `command not found`, `Unknown option: version`) yields `n/a`, and the line is kept. |
| PRV-12 | A later duplicate name wins, which is what lets `BASECALL`'s appended dorado fragment correct a probe that could not see it. |
| PRV-13 | `to_yaml` is sorted and deterministic: the same versions in any order render byte-identically. |


## 11. Cluster and container profiles (`conf/`)

Scheduler execution is a supported target. The five institutional profiles
are imported from nf-metabarcoding — same author, same users, same sites —
whose `conf/clusters/` files carry only site facts.

Everything here is **config resolution**, testable with nothing but
Nextflow: no scheduler, no container engine, no image build. That is the
point — the bugs these guard against are profiles that resolve *wrongly*,
invisible until a real submission and cheap to catch statically. Real
`sbatch` submission and a real image build stay manual smoke tests at the
adopting site; a fake scheduler would only prove the fake works.

**Basecalling is local-only.** `dorado` is an ONT GPU binary that is not on
bioconda, so it is in neither `environment.yml` nor any image built from it,
and the sites' queue closures route by memory and time — they would send
`BASECALL` to a CPU node. Basecall on a GPU workstation, then run the
cluster half with `--skip_basecall`.

| ID     | Specification                                                                                                                                          |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| CLU-01 | Every shipped profile resolves (`standard`, `slurm`, `cluster`, the five sites, `conda`, and the four engines) (a), and an executor profile composes with an engine profile, e.g. `-profile abims,apptainer` (b). |
| CLU-02 | A cluster profile *implies* slurm — each includes `conf/slurm.config`, so a user never lists `slurm` as well (a). The `slurm` profile carries the submission plumbing: queue, account, extra sbatch options, queue size, the `clusterOptions` closure and `executor.queueSize` (b). |
| CLU-03 | Each site sets its own ceiling to its largest node, and `resourceLimits` is rebuilt from it (a). A site ceiling is **never** the running host's capacity (b): the auto-detected default describes the *submit* host under a scheduler, and inheriting it would silently shrink every submitted job — bare `-profile slurm` did exactly that until this caught it, and `conf/slurm.config` now sets conservative explicit defaults. Walltime is set under slurm and absent locally (c), since the local executor has no walltime enforcer and a job with no `time` inherits the queue default and is killed there. |
| CLU-04 | `cluster` remains an **exact** alias of `slurm`: the two resolve identically. It shipped in v1.0.0 and project configs in the wild use it. |
| CLU-05 | The sites batch tasks into slurm job arrays (`process.array`). One task per barcode, up to 96 a run, is exactly the submission load arrays exist to reduce. |
| CLU-06 | Each engine profile enables its engine plus Wave, which builds the image from the same pinned `environment.yml` that drives `-profile conda` (a). An engine profile must **not** also set `conda.enabled` (b): that switches on Nextflow's native conda integration *as well as* Wave, adding a local `conda env create` on the launch node — which on an HPC login node blocks on a slow solve and can fail, stalling the run before a task is submitted. Wave needs only the per-process `conda` directive, which must be present. The engine's `enabled` and the site's bind mounts survive together through `includeConfig` (c) — the dotted-assignment discipline, since a block-form engine scope silently drops `enabled` on Nextflow 25.10.x and the run falls back to conda with no error. |
| CLU-07 | `BASECALL` is never given a `conda` directive under any profile, so it is never containerised or conda-packaged: dorado is not in the environment, and handing it one without the tool it needs would only hide the problem. |
| CLU-08 | Every `conf/clusters/<name>.config` is registered as a profile (dead config otherwise) and `_template.config` is **not** (it is a starting point, not a site). |
| CLU-09 | Basecalling under a scheduler is refused at startup, with a message that says what to do instead (a) — rather than queueing a job for a node with no GPU and failing after the wait, with the cause far from the reason. Local basecalling is unaffected (b). A site that declares `require_slurm_account` refuses without one, naming both ways to supply it (c); the other sites do not inherit that requirement (d). |


## 12. Out of scope (will not be tested)

- The numerical correctness of `dorado` basecalls.
- The numerical correctness of `cutadapt` primer trimming or
  `vsearch` sintax assignment. We only check that the pipeline drives
  these tools with the documented options and consumes their outputs
  faithfully.
- GPU-bound BASECALL execution: covered only via a `dorado` stub.
- Cluster execution: config resolution is fully tested (CLU-01..CLU-09);
  real `sbatch` submission and a real container image build are manual
  smoke tests at the adopting site. A fake scheduler would only prove the
  fake works.
- GPU basecalling on a cluster: unsupported by design, and refused at
  startup (CLU-09).
