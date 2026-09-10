# Tests

This directory contains the test scaffolding and a first pass of
tests for `nf-pore2taxa`.

See [`../SPECIFICATIONS.md`](../SPECIFICATIONS.md) for the full list of testable
behaviours — each test asserts a subset of those, identified by `WF-..`,
`SX-..`, `BT-..`, `BC-..`, `CFG-..`, `CLU-..`, `DSC-..`, `FN-..`, `KR-..`,
`PRV-..` or `VL-..` IDs in comments and test names.
[`COVERAGE.md`](COVERAGE.md) maps every ID to the test(s) that cite it, and
`bash tests/coverage-gate.sh` fails if the two ever disagree — so the
per-file table further down is a convenience, not the source of truth.

## Layout

```
tests/
├── COVERAGE.md           ← every spec ID -> its test(s) -> status
├── coverage-gate.sh      ← enforces that the mapping cannot drift
├── check-stub-run.sh     ← whole pipeline under -stub-run, no tools at all
├── README.md             ← this file
├── run_all.sh            ← convenience runner for CI
├── nextflow.config       ← test-only Nextflow overrides
├── fixtures/             ← synthetic input data (small, committed)
│   ├── generate.sh
│   ├── references.fasta
│   ├── fastq_dir/        ← demultiplexed-into-folders inputs (SINTAX + workflow)
│   ├── flat_dir/         ← flat layout (barcode in filename) + fastq_fail to ignore
│   ├── sintax_dir/       ← pre-computed inputs for the table-builder tests
│   └── krona/            ← occurrence tables (filtered + optimistic) for Krona tests
├── stubs/                ← stand-ins for tools that cannot run in CI
│   └── dorado            ← records its argv, fabricates the outputs
├── bin/                  ← bats tests for bin/ scripts + python unittest
│   ├── assign_with_sintax_cli.bats
│   ├── basecall_cli.bats
│   ├── assign_with_sintax_helpers.bats
│   ├── assign_with_sintax_tools.bats ← broken tools, failure reporting, --fastq-list
│   ├── build_krona_cli.bats
│   ├── build_occurrence_table.bats
│   ├── reference_format.bats
│   ├── test_collect_versions.py
│   ├── test_build_krona.py
│   ├── test_build_occurrence_table.py
│   ├── test_discover_barcodes.py
│   └── validation.bats
├── config/               ← bats tests for config invariants + whole-run behaviour
│   ├── cluster_profiles.bats ← slurm / site / container profile resolution
│   ├── demo_profile.bats   ← -profile demo runs with no flags
│   ├── declared_params.bats ← the pipeline declares every param it reads
│   ├── deprecation.bats
│   ├── outdir.bats         ← the consolidated output directory
│   ├── params_strict.bats  ← undeclared parameters are rejected
│   ├── provenance.bats     ← versions.yml / params.json / execution reports
│   ├── publish_modes.bats  ← publish_mode matrix + its cleanup interaction
│   ├── resources.bats      ← resource ceiling / resourceLimits clamping
│   ├── resume.bats         ← two successive runs against a mutating input dir
│   ├── sintax_fastq_list.bats ← the fastq set reaches SINTAX as a list file
│   ├── summary.bats        ← startup run summary + randseed warning
│   └── version.bats
├── modules/              ← nf-test files for processes + shared functions
│   ├── dump_params.nf.test
│   ├── dump_versions.nf.test
│   ├── functions.nf.test
│   └── sintax.nf.test
└── workflow/             ← nf-test files for the end-to-end workflow
    ├── basecall.nf.test  ← the basecalling branch, via the dorado stub
    └── main.nf.test
```

## Dependencies

| Layer                | Required tools                                       |
| -------------------- | ---------------------------------------------------- |
| python unit tests    | `python3` (standard library only)                    |
| bats unit tests      | `bats` (>= 1.5), `python3`, `awk`, `grep`            |
| config invariants    | `nextflow`; skips if absent. CFG-02c/CFG-03c/CFG-04g also need `cutadapt` + `vsearch` (they run to completion, to prove the outputs are readable / the clamped request reached the tool) |
| resume (SX-35/DSC-06)| `nextflow`, `cutadapt`, `vsearch`; skips if absent   |
| provenance (PRV-05..08)| `nextflow`, `cutadapt`, `vsearch`; skips if absent |
| cluster profiles (CLU) | `nextflow` only — config resolution, no scheduler or engine |
| SINTAX module        | `nextflow`, `nf-test`, `cutadapt`, `vsearch >= 2.31.0` |
| Krona (KR-40..42)    | `ktImportText` (KronaTools); skips if absent         |
| Workflow             | all of the above (WF-13/WF-15 need `ktImportText`)   |

## Running

### Everything

```bash
bash tests/run_all.sh
```

### Individual layers

```bash
# bats unit tests (all)
bats tests/bin/

# A single bats file
bats tests/bin/assign_with_sintax_helpers.bats

# python unit + integration tests for the table builder
python3 -m unittest discover -s tests/bin -p 'test_*.py'

# nf-test, all suites
nf-test test tests/

# nf-test, single suite
nf-test test tests/modules/sintax.nf.test
nf-test test tests/workflow/main.nf.test
```

## What each layer covers

| Layer                                  | Specs covered (see `../SPECIFICATIONS.md`)                  |
| -------------------------------------- | --------------------------------------------------------- |
| `bin/validation.bats`                  | VL-01, VL-02, VL-03, VL-04                                |
| `bin/basecall_cli.bats`                | BC-01..BC-07, BC-09..BC-12                                |
| `bin/reference_format.bats`            | SX-12                                                     |
| `bin/assign_with_sintax_cli.bats`      | SX-05, SX-11, SX-12, SX-13, SX-14, SX-15, SX-16, SX-40    |
| `bin/assign_with_sintax_helpers.bats`  | SX-22, SX-23, SX-24, SX-25                                |
| `bin/assign_with_sintax_tools.bats`    | SX-17, SX-18, SX-19                                       |
| `bin/test_discover_barcodes.py`        | DSC-01..DSC-05, DSC-07                                    |
| `bin/build_occurrence_table.bats`      | BT-01..BT-04, BT-06, BT-07, BT-10..BT-13, BT-21..BT-24    |
| `bin/test_build_occurrence_table.py`   | BT-01..BT-07, BT-10..BT-17, BT-20..BT-25, BT-30, BT-32..BT-34 |
| `bin/test_build_krona.py`              | KR-01..KR-04, KR-30..KR-35                                |
| `bin/test_collect_versions.py`         | PRV-10..PRV-13                                            |
| `bin/test_known_params.py`             | PRM-02                                                    |
| `bin/build_krona_cli.bats`             | KR-40, KR-41, KR-42                                       |
| `config/version.bats`                  | CFG-01, CFG-05                                            |
| `config/deprecation.bats`              | WF-08 (the `log.warn` half)                               |
| `config/publish_modes.bats`            | CFG-02, CFG-03                                            |
| `config/resources.bats`                | CFG-04                                                    |
| `config/declared_params.bats`          | PRM-03                                                    |
| `config/provenance.bats`               | PRV-05..PRV-08                                            |
| `config/cluster_profiles.bats`         | CLU-01..CLU-09                                            |
| `config/demo_profile.bats`             | DEM-01..DEM-04                                            |
| `check-stub-run.sh`                    | STB-01..STB-04                                            |
| `config/summary.bats`                  | CFG-06                                                    |
| `config/resume.bats`                   | SX-35, DSC-06                                             |
| `config/sintax_fastq_list.bats`        | SX-19                                                     |
| `modules/functions.nf.test`            | FN-01..FN-06                                              |
| `modules/dump_versions.nf.test`        | PRV-01, PRV-02, PRV-03                                    |
| `modules/dump_params.nf.test`          | PRV-04                                                    |
| `modules/sintax.nf.test`               | SX-30, SX-31, SX-32, SX-33, SX-40, SX-44                  |
| `workflow/basecall.nf.test`            | BC-08, WF-02, WF-05                                       |
| `workflow/main.nf.test`                | WF-03, WF-04, WF-06, WF-08..WF-17, CFG-03, SX-41, BT-10, BT-11, BT-13, BT-20, BT-22, BT-23 |

## Known gaps (next iterations)

The current suite is a starting point. Specs not yet covered:

- ~~a tool-free topology check~~ — closed by `check-stub-run.sh`
  (STB-01..04): the whole pipeline under `-stub-run` with cutadapt, vsearch,
  ktImportText and dorado all shadowed by stubs that `exit 1`. Needs only
  Nextflow and python3, so it is the fastest signal that a wiring change
  broke the graph, and the fastest "is my install sane?" for a new lab.
- ~~`BASECALL` module tests~~ — closed in v1.11.0 by `tests/stubs/dorado`,
  which records its argv and fabricates the outputs (BC-01..BC-12). The
  real dorado needs a GPU and a ~1 GB model download, so the stub is the
  only way this branch is testable at all.
- The remaining CLI validation specs for `assign_with_sintax.sh`
  (SX-01..SX-04, SX-06..SX-10). Add as new cases in
  `bin/assign_with_sintax_cli.bats`.
- WF-01 and WF-07 — the remaining workflow-level assertions. WF-02 and
  WF-05 are covered by `workflow/basecall.nf.test`.
- OBS-05's bare-filename `results_table` form (the extension half is now
  covered by WF-15).
- ~~The production resource defaults~~ — now covered by CFG-04g, which
  runs the real resource config (no `tests/nextflow.config`) against a
  deliberately tiny ceiling. The nf-tests still override `cpus`/`memory`,
  so that bats case is the only place the shipped numbers are exercised.

> **Note.** `dorado`'s version capture (PRV-03) is covered *without*
> dorado, a GPU or a model download: `BASECALL` emits it as a text
> fragment, so `modules/dump_versions.nf.test` merges a hand-written one.
> That is the only part of the basecalling path currently under test.

> **Note.** SX-35 and DSC-06 live in `config/resume.bats` rather than
> nf-test: they need two successive `nextflow run` invocations against an
> input directory that changes between them, and nf-test gives each test
> a fresh `outputDir` with no resume hook. The `-resume` defect they pin
> went unnoticed precisely because the suite had no way to express "run
> it twice".

The table-builder helper-function specs (BT-30, BT-32..BT-34) are now
covered directly by `bin/test_build_occurrence_table.py`, which imports
`bin/build_occurrence_table.py` and exercises its pure functions.

## Regenerating fixtures

```bash
bash tests/fixtures/generate.sh
```

This overwrites everything under `tests/fixtures/` except this
README and the README in fixtures/. Commit the regenerated files so
the suite stays self-contained.
