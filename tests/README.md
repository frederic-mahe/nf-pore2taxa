# Tests

This directory contains the test scaffolding and a first pass of
tests for `nf-pore2taxa`.

See [`SPECIFICATIONS.md`](SPECIFICATIONS.md) for the full list of
testable behaviours — each test asserts a subset of those, identified
by `WF-..`, `SX-..`, `BT-..` or `VL-..` IDs in comments and test names.

## Layout

```
tests/
├── SPECIFICATIONS.md     ← what we test and why
├── README.md             ← this file
├── run_all.sh            ← convenience runner for CI
├── nextflow.config       ← test-only Nextflow overrides
├── fixtures/             ← synthetic input data (small, committed)
│   ├── generate.sh
│   ├── references.fasta
│   ├── fastq_dir/        ← inputs for SINTAX module + workflow tests
│   └── sintax_dir/       ← pre-computed inputs for the R-script tests
├── bin/                  ← bats tests for bin/ scripts
│   ├── assign_with_sintax_helpers.bats
│   ├── build_occurrence_table.bats
│   └── validation.bats
├── modules/              ← nf-test files for individual processes
│   └── sintax.nf.test
└── workflow/             ← nf-test files for the end-to-end workflow
    └── main.nf.test
```

## Dependencies

| Layer            | Required tools                                       |
| ---------------- | ---------------------------------------------------- |
| bats unit tests  | `bats` (>= 1.5), `awk`, `grep`                       |
| R-script tests   | `Rscript` + `tidyverse` + `optparse` (auto-skip if missing) |
| SINTAX module    | `nextflow`, `nf-test`, `cutadapt`, `vsearch >= 2.31.0` |
| Workflow         | all of the above                                     |

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

# nf-test, all suites
nf-test test tests/

# nf-test, single suite
nf-test test tests/modules/sintax.nf.test
nf-test test tests/workflow/main.nf.test
```

## What each layer covers

| Layer                                  | Specs covered (see `SPECIFICATIONS.md`)                  |
| -------------------------------------- | --------------------------------------------------------- |
| `bin/validation.bats`                  | VL-01, VL-02, VL-03, VL-04                                |
| `bin/assign_with_sintax_helpers.bats`  | SX-20, SX-21, SX-22, SX-23, SX-24                         |
| `bin/build_occurrence_table.bats`      | BT-01..BT-04, BT-06, BT-07, BT-10..BT-13, BT-21..BT-23    |
| `modules/sintax.nf.test`               | SX-30, SX-31, SX-32, SX-33, SX-34                         |
| `workflow/main.nf.test`                | WF-03, WF-04, WF-06, BT-10, BT-11, BT-13, BT-20, BT-22, BT-23 |

## Known gaps (next iterations)

The current suite is a starting point. Specs not yet covered:

- `BASECALL` module tests (BC-01..BC-08). These need a `dorado` stub
  on the test PATH — see SPECIFICATIONS.md §2.
- Most CLI validation specs for `assign_with_sintax.sh` (SX-01..SX-11).
  Add as a new `bin/assign_with_sintax_cli.bats`.
- R helper-function unit tests with `testthat` (BT-30..BT-38). Will
  require refactoring `build_occurrence_table.R` to separate library
  functions from the `main` routine, or sourcing it in a fresh R
  environment at test time.
- `SINTAX` with `-resume` (SX-35) and uncompressed/`.bz2`/`.xz` inputs
  (SX-36).

## Regenerating fixtures

```bash
bash tests/fixtures/generate.sh
```

This overwrites everything under `tests/fixtures/` except this
README and the README in fixtures/. Commit the regenerated files so
the suite stays self-contained.
