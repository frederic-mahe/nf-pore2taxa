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

## 2. `BASECALL` module — *light coverage only*

The module simply shells out to `bin/basecall_pod5_files.sh`, which in
turn drives `dorado`. We do not test basecalling itself. Worth
asserting:

| ID    | Specification                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BC-01 | `basecall_pod5_files.sh --help` exits 0 and prints the usage block.                                                                                    |
| BC-02 | The script exits non-zero with a clear error when `--input-dir` is missing.                                                                            |
| BC-03 | The script exits non-zero with a clear error when `--input-dir` does not exist or is unreadable.                                                       |
| BC-04 | The script exits non-zero when `--model` does not match the `(fast|hac|sup)@v<X.Y.Z>` pattern.                                                         |
| BC-05 | The script exits non-zero when `--kit-name` does not match `XXX-XXX000`.                                                                               |
| BC-06 | Unknown long flags exit non-zero with `Unknown option:` on stderr.                                                                                     |
| BC-07 | Default model is `sup@v5.2.0` and default kit is `EXP-PBC096` (assert by injecting a `dorado` stub and inspecting the command it received).            |
| BC-08 | The module's `done_basecalling.txt` sentinel is produced and `publishDir` writes outputs into `params.fastq_dir` via `link` mode (use a dorado stub).  |

> Note: BC-07 and BC-08 require a `dorado` stub on the PATH (a shell
> script that records its argv and emits empty `fastq_pass/*.fastq`
> files). This avoids any GPU/runtime requirement on CI.

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
| SX-35  | The module is idempotent: re-running with `-resume` is a per-barcode Nextflow cache hit.                                                               |
| SX-36  | Each supported extension (`.fastq`, `.fastq.{gz,bz2,xz}`) is accepted (covered at the CLI level by SX-05).                                             |
| SX-40  | A barcode split across **several** fastq files is trimmed file-by-file, concatenated, and assigned with a **single** `vsearch` run, producing one `<barcode>.sintax` whose read count is the sum across the files. |
| SX-41  | End-to-end (`main.nf`): a **flat** `fastq_pass/` (barcode embedded in the filename) with a multi-file barcode produces a correct table, and a sibling `fastq_fail/` is **ignored** (its reads are not counted). |

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
| CFG-01 | `manifest.version` and `params.version` resolve to the same value (kept in sync on every version bump). Tested in `tests/config/version.bats`.          |

## 7. Observations worth noting in the spec (not bugs, but ambiguities)

| ID     | Note                                                                                                                                                   |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ~~OBS-01~~ | **Resolved.** `validate_inputs` in `assign_with_sintax.sh` originally counted only `*.fastq.gz` when deciding whether the input dir was empty, contradicting the script's main loop and the v1.1.0 CHANGELOG. Validation now uses the same `FASTQ_REGEX` constant as the main loop. Covered by SX-05 + the `SX-05-{gz,plain,bz2,xz,empty}` cases in `tests/bin/assign_with_sintax_cli.bats`. |
| OBS-02 | `trim_extension` uses `sed -r` and only strips one of each suffix, right-most. The README does not document multi-suffix behaviour; SX-21 pins it.    |
| OBS-03 | `SINTAX` runs vsearch with `--threads > 1`, which is non-deterministic. SX-3x tests must therefore be structural (counts, columns) rather than exact. |
| OBS-04 | The script silently creates the output parent directory (`build_occurrence_table.py`, `validate_args`). BT-05 pins this behaviour; flag if you want it to fail loudly instead. |
| OBS-05 | `param.results_table` is consumed by `BUILD_TABLE` as `file(params.results_table).name` for the output filename, and `file(params.results_table).parent` for the `publishDir`. Tests should cover both directory and bare-filename forms. |

## 8. Out of scope (will not be tested)

- The numerical correctness of `dorado` basecalls.
- The numerical correctness of `cutadapt` primer trimming or
  `vsearch` sintax assignment. We only check that the pipeline drives
  these tools with the documented options and consumes their outputs
  faithfully.
- GPU-bound BASECALL execution: covered only via a `dorado` stub.
- Cluster execution (`profile = cluster`): smoke-test only, no real
  Slurm submission.
