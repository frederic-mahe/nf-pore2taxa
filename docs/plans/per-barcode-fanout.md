# Plan: per-barcode fan-out for `SINTAX`

Status: **proposed** (not yet implemented). Target version: `1.4.0`.
Branch off `tmp-primer-toggle-ci`.

## Motivation

`SINTAX` is currently a single task that hard-links the entire
`fastq_pass/` tree and loops over every fastq file inside one process
(`assign_with_sintax.sh`), running `vsearch --sintax` **once per file**.
Consequences:

- no parallelism across barcodes; one failure fails the whole step;
  no granular `-resume`;
- the reference database is re-loaded (k-mer-indexed) **once per fastq
  file** — wasteful when a barcode is split into many small files.

## Decision: fan-out unit = **barcode** (not file)

Loading the reference is the dominant fixed cost of each `vsearch
--sintax` call. So the unit of work is the **barcode**: trim every fastq
file of a barcode, concatenate, and run vsearch **once** for that
barcode. This both removes the per-file reload waste and gives
cross-barcode parallelism.

DB-load economics:

- before: 1 load × number of *files* (worst case hundreds, serial);
- after:  1 load × number of *barcodes* (typically 12–96, parallel).

Per-barcode is the sweet spot. The only regime where the old monolith
wins is a huge reference with very few barcodes and tiny read counts; if
that ever matters, an opt-in "single vsearch for the whole run" path can
be added later (query IDs carry enough to demux the output by barcode).

## Barcode identity (folder OR filename)

Demultiplexed-into-folders (`fastq_pass/barcode01/…`) and flat layouts
(`fastq_pass/FAX123_pass_barcode01_0.fastq.gz`, barcode embedded in the
filename) both occur, depending on whether basecalling ran. So the
barcode must be derived by **regex over the full path** — the same
`BARCODE_PATTERN` (`barcode[0-9]+|unclassified|mixed`) that
`build_occurrence_table.py` already uses, which matches the token in a
directory component *or* the filename. Discovery and aggregation share
one pattern so they cannot disagree.

## `fastq_pass` vs `fastq_fail`

Discovery is rooted at `<fastq_dir>/fastq_pass`, so a sibling
`fastq_fail/` is **excluded by construction** — same as today (the
`SINTAX` module stages only `${fastq_dir}/fastq_pass`, and the basecall
`clean_up` keeps only `fastq_pass`). This is a *convention* (rooting at
`fastq_pass`), not a name filter: reads placed *inside* `fastq_pass`
would still be processed. The test suite will pin "a sibling
`fastq_fail/` is ignored".

## Target architecture

```
discover + group by barcode          ┌── SINTAX(barcode01, [f1,f2,…]) ─┐  trim each, concat,
  (regex over full path)        ──→   ┼── SINTAX(barcode02, [f1]) ──────┼─ ONE vsearch → 1 .sintax
  emits [barcode, [files…]]          └── SINTAX(…) ───────────────────-┘        │
                                                                          .collect() → BUILD_TABLE → 2 TSVs
```

## Component changes

1. **Discovery + grouping** — see decision D1. Walks `fastq_pass/`,
   derives each file's barcode with `BARCODE_PATTERN`, groups files per
   barcode, yields a `[barcode, [files…]]` channel. The "no fastq files
   found" friendly error (SX-05) moves here.
2. **`assign_with_sintax.sh` → per-barcode; vsearch out of the loop**:
   ```
   for fq in "$@"; do trim_primers "$fq" | append_read_length; done \
       | taxonomic_assignment_with_sintax > "${BARCODE}.sintax"   # one DB load
   ```
   All helper functions and the validation/version/reference-format/
   primer-toggle behaviour are unchanged; only the top-level loop moves.
3. **`SINTAX` process → per-barcode.** Input `tuple val(barcode),
   path(fastqs)`; output `tuple val(barcode), path("${barcode}.sintax"),
   path("${barcode}.log")`, non-optional (empty barcode still emits a
   0-byte `.sintax`). `tag "${barcode}"`. The whole-tree
   `cp --archive --link` is removed (Nextflow stages per-barcode inputs).
4. **Gather → `BUILD_TABLE`.** One `.sintax` per barcode, named by
   barcode, staged **flat** (`barcode01.sintax`, …); `extract_barcode`
   reads the name, so `build_occurrence_table.py` is unchanged. The
   `done_sintax.txt` sentinel + `.parent` hack are replaced by a real
   `.collect()` dependency (proper resume).
5. **Publish-back** to `${params.fastq_dir}/fastq_pass/${barcode}/`
   preserved, via `publishDir` + `params.publish_mode`.

## Test strategy (test-first)

Before refactoring, lock current output with a **golden byte-for-byte**
snapshot of both TSVs. Extend the fixture to cover:

- a **flat** `fastq_pass/` with the **barcode embedded in the filename**;
- a barcode of **many small files** (assert one `.sintax`, one combined
  column, and a single vsearch invocation via the trace);
- a subfolder barcode and an all-empty barcode (SX-33 canary);
- a sibling **`fastq_fail/` that must be ignored**.

Add unit tests for the discovery helper (folder / flat / embedded /
`unclassified` / no-token). Rewrite the `SINTAX` module test for the
`[barcode, [files]]` interface. Update `SPECIFICATIONS.md` (new discovery
spec; per-barcode aggregation makes the multi-chunk-empty BT-25 path
trivially satisfied) and the coverage map.

## Sequencing (each step green before the next)

1. Golden-output test + extended fixtures on the **current** code.
2. Discovery helper + its unit tests (decision D1).
3. Refactor `assign_with_sintax.sh` to per-barcode; update its tests.
4. Rewire `SINTAX` + discovery channel + gather; drop sentinel/tree-link.
5. Adapt `BUILD_TABLE` input (flat staged `.sintax`); Python unchanged.
6. Full suite + a real multi-barcode local run; golden test must pass.

## Open decisions

- **D1 — discovery implementation:** tested Python helper
  (`bin/discover_barcodes.py`, reuses `BARCODE_PATTERN`, unit-testable)
  vs. inline Groovy `groupTuple`. *Recommendation: Python helper.*
- **D2 — file with no barcode token:** abort with a clear error listing
  offending files, vs. group them as `unknown`. *Recommendation: abort.*
- **D3 — old `--input-dir` CLI:** hard-cut to the per-barcode file-list
  interface, vs. keep a backward-compatible shim. *Recommendation:
  hard-cut (internal driver).*
