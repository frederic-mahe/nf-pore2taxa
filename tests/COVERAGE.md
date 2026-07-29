# Spec coverage

One row per `[Sxx]`-style ID declared in
[`SPECIFICATIONS.md`](SPECIFICATIONS.md), mapped to the test(s) that cite
it. **Status:**

- `done` — at least one test names this ID and passes
- `TODO` — no test yet
- `n/a`  — an observation or ambiguity, not an assertable behaviour

`bash tests/coverage-gate.sh` enforces the triangle: every declared ID
appears here, every ID cited from `tests/` is declared, nothing here is
undeclared, and every row marked `done` really is cited by a test. So this
file cannot quietly drift from either side — which matters, because the
suite grew from 71 to ~150 tests across six releases with this mapping
maintained by hand.

Regenerating from scratch is not supported on purpose: the statuses carry
judgement (what is `n/a` and why) that a generator would erase. Add a row
when you add a spec, in the same commit.


## 1. Top-level workflow (`main.nf`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `WF-01` | When skip_basecall = true, the workflow does not instantiate BASECALL and reads from... | — | TODO |
| `WF-02` | When skip_basecall = false, BASECALL runs and its sentinel done_basecalling.txt is th... | `workflow/basecall.nf.test` | done |
| `WF-03` | The pipeline aborts if params.sintax_references does not exist (checkIfExists: true). | `workflow/main.nf.test` | done |
| `WF-04` | The pipeline aborts if params.fastq_dir does not exist when skip_basecall = true. | `workflow/main.nf.test` | done |
| `WF-05` | The pipeline aborts if params.pod5_dir does not exist when skip_basecall = false. | `workflow/basecall.nf.test` | done |
| `WF-06` | With a valid fixture, the workflow produces exactly two TSV files at params.results_t... | `workflow/main.nf.test` | done |
| `WF-07` | The workflow exits 0 on the happy path and non-zero on any process failure. | — | TODO |
| `WF-08` | params.sintax_silva is accepted as a deprecated alias for params.sintax_references: w... | `config/deprecation.bats`, `workflow/main.nf.test` | done |
| `WF-09` | When both are set, params.sintax_references takes precedence over the deprecated para... | `workflow/main.nf.test` | done |
| `WF-10` | The pipeline aborts if the path supplied via the deprecated params.sintax_silva alias... | `workflow/main.nf.test` | done |
| `WF-11` | Startup parameter validation aborts before any process runs, with a single aggregated... | `workflow/main.nf.test` | done |
| `WF-12` | End-to-end, params.subsample = n caps each barcode at n reads: with subsample = 3 a 5... | `workflow/main.nf.test` | done |
| `WF-13` | params.krona = true renders krona.html and krona_optimistic.html beside results_table... | `workflow/main.nf.test` | done |
| `WF-14` | Boolean params set on the command line arrive as strings ('true'/'false'), so discard... | `workflow/main.nf.test` | done |
| `WF-15` | results_table is honoured whatever its extension: results/table.txt publishes table.t... | `workflow/main.nf.test` | done |
| `WF-16` | skip_basecall is validated and branched on the string form, like every other boolean... | `workflow/main.nf.test` | done |
| `WF-17` | fastq_dir is required in both modes, not only when skip_basecall = true: BASECALL pub... | `workflow/main.nf.test` | done |

## 2. `BASECALL` module + `basecall_pod5_files.sh`

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `BC-01` | --help exits 0 and prints the usage block, including --device and --models-dir. | `bin/basecall_cli.bats` | done |
| `BC-02` | A missing --input-dir (a) or --output-dir (b) is a clear error. | `bin/basecall_cli.bats` | done |
| `BC-03` | An --input-dir that does not exist is a clear error. | `bin/basecall_cli.bats` | done |
| `BC-04` | An unrecognised --model is rejected, and the message shows both accepted forms (a). A... | `bin/basecall_cli.bats` | done |
| `BC-05` | An unrecognised --kit-name is rejected. | `bin/basecall_cli.bats` | done |
| `BC-06` | An unknown flag exits non-zero with Unknown option: (a); an unrecognised --device is... | `bin/basecall_cli.bats` | done |
| `BC-07` | The defaults are sup@v5.2.0, EXP-PBC096 and cuda:0, asserted by inspecting the argv t... | `bin/basecall_cli.bats` | done |
| `BC-08` | End-to-end (main.nf): basecalling publishes done_basecalling.txt and the fastq_pass h... | `workflow/basecall.nf.test` | done |
| `BC-09` | --model, --kit-name and --device are each overridable (a), and cpu is a valid device,... | `bin/basecall_cli.bats` | done |
| `BC-10` | A model already present in --models-dir is not downloaded again (a), and the model di... | `bin/basecall_cli.bats` | done |
| `BC-11` | The script confines itself to --output-dir. clean_up and compress_fastq used to walk... | `bin/basecall_cli.bats` | done |
| `BC-12` | The model-prefix logic in bin/basecall_pod5_files.sh and in modules/local/functions.n... | `bin/basecall_cli.bats` | done |

## 3. `SINTAX` module + `assign_with_sintax.sh`

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `SX-01` | --help exits 0 and prints usage. | — | TODO |
| `SX-02` | Missing --barcode, --references, --forward-primer, or --reverse-primer each yield a c... | — | TODO |
| `SX-03` | Non-integer or non-positive --threads yields a clear error. | — | TODO |
| `SX-04` | A FASTQ argument that does not exist or is not readable yields a clear error. | — | TODO |
| `SX-05` | The script takes one or more FASTQ files (positional args) belonging to one barcode;... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-06` | --references that does not exist or is not readable yields a clear error. | — | TODO |
| `SX-07` | A primer containing non-IUPAC characters yields an error. | — | TODO |
| `SX-08` | A primer shorter than 10 nt emits a *warning* to stderr but does not abort. | — | TODO |
| `SX-09` | If vsearch is older than the documented minimum (2.31.0), the script aborts with a cl... | — | TODO |
| `SX-10` | Unknown long flags exit non-zero with Unknown option: on stderr. | — | TODO |
| `SX-11` | Missing --barcode yields a clear error (positional args are fastq files, so they are... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-12` | --references is sniffed at startup and must be sintax-formatted: its first FASTA head... | `bin/assign_with_sintax_cli.bats`, `bin/reference_format.bats` | done |
| `SX-13` | Primer-presence filtering is toggleable. By default (--discard-untrimmed, the script... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-14` | --randseed sets vsearch's random generator seed (default 0, a pseudo-random seed). A... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-15` | --subsample n (default 0 = disabled) caps the barcode at n reads before trimming: the... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-16` | A negative or non-integer --subsample yields a clear stderr error (--subsample must b... | `bin/assign_with_sintax_cli.bats` | done |
| `SX-22` | reverse_complement: complements ACGT/U/IUPAC ambiguity codes correctly and reverses t... | `bin/assign_with_sintax_helpers.bats` | done |
| `SX-23` | reverse_complement: handles lower-case input and preserves case. | `bin/assign_with_sintax_helpers.bats` | done |
| `SX-24` | reverse_complement: empty string input aborts with a clear error. | `bin/assign_with_sintax_helpers.bats` | done |
| `SX-25` | pool_reads: concatenates a barcode's FASTQ files (mixed compression: .gz/.bz2/.xz/pla... | `bin/assign_with_sintax_helpers.bats` | done |
| `SX-30` | For each input tuple(barcode, [fastqs]) the module produces one <barcode>.sintax and... | `modules/sintax.nf.test` | done |
| `SX-31` | Each *.sintax row, if present, has exactly 4 tab-separated fields (query, full_taxono... | `modules/sintax.nf.test` | done |
| `SX-32` | Query identifiers in *.sintax carry a ;length=N annotation appended by append_read_le... | `modules/sintax.nf.test` | done |
| `SX-33` | If a barcode's reads do not survive primer trimming, its <barcode>.sintax exists and... | `modules/sintax.nf.test` | done |
| `SX-35` | The pipeline is idempotent: re-running with -resume against an unchanged input tree i... | `config/resume.bats` | done |
| `SX-36` | Each supported extension (.fastq, .fastq.{gz,bz2,xz}) is accepted (covered at the CLI... | — | TODO |
| `SX-40` | A barcode split across several fastq files is trimmed file-by-file, concatenated, and... | `bin/assign_with_sintax_cli.bats`, `modules/sintax.nf.test` | done |
| `SX-41` | End-to-end (main.nf): a flat fastq_pass/ (barcode embedded in the filename) with a mu... | `workflow/main.nf.test` | done |
| `SX-44` | With params.subsample = n > 0, the module caps each barcode at n reads (pool → subsam... | `modules/sintax.nf.test` | done |
| `DSC-01` | The barcode token is found whether it is a directory component (barcode01/reads.fastq... | `bin/test_discover_barcodes.py` | done |
| `DSC-02` | Files of one barcode are grouped together; a multi-file barcode yields multiple rows... | `bin/test_discover_barcodes.py` | done |
| `DSC-03` | A barcode-like token in a parent directory is not picked up (matching is on the path... | `bin/test_discover_barcodes.py` | done |
| `DSC-04` | A file with no recognisable barcode token aborts the run (D2), listing the offending... | `bin/test_discover_barcodes.py` | done |
| `DSC-05` | Discovery is rooted at fastq_pass, so a sibling fastq_fail/ is never seen (also asser... | `bin/test_discover_barcodes.py` | done |
| `DSC-06` | Discovery's Nextflow cache key reflects the set of fastq files present, not just the... | `config/resume.bats` | done |
| `DSC-07` | fastq_extensions() (modules/local/functions.nf, used to build that cache key) and FAS... | `bin/test_discover_barcodes.py` | done |

## 4. `BUILD_TABLE` module + `build_occurrence_table.py`

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `BT-01` | Missing --input-dir aborts with --input-dir is required. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-02` | Missing --output aborts with --output is required. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-03` | --input-dir that does not exist aborts with Path does not exist. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-04` | --input-dir that points to a file (not a directory) aborts with not a directory. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-05` | Output parent directory is created if missing. | `bin/test_build_occurrence_table.py` | done |
| `BT-06` | An input directory with no *.sintax files aborts with No sintax files found. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-07` | The optimistic file path is <stem>_optimistic.<ext>, derived from --output by inserti... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-10` | The output is tab-separated and starts with a header row: taxonomy\ttotal\t<barcode n... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py`, `workflow/main.nf.test` | done |
| `BT-11` | Column total equals the row-wise sum of all barcode columns. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py`, `workflow/main.nf.test` | done |
| `BT-12` | Rows are sorted by total descending, then taxonomy ascending. | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-13` | Non-empty barcodes appear before empty barcodes in the column order; empty barcodes a... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py`, `workflow/main.nf.test` | done |
| `BT-14` | Reads without a sintax assignment (empty/missing column 4) are bucketed under taxonom... | `bin/test_build_occurrence_table.py` | done |
| `BT-15` | Each (taxonomy, barcode) cell is the read count for that pair; missing pairs are fill... | `bin/test_build_occurrence_table.py` | done |
| `BT-16` | mixed — i.e. directory clutter does not pollute names. | `bin/test_build_occurrence_table.py` | done |
| `BT-17` | Probabilities in full_taxonomy (e.g. d:Fungi(0.99)) are stripped from the filtered ta... | `bin/test_build_occurrence_table.py` | done |
| `BT-20` | The optimistic table has the same structure (columns, sort order, empty-barcode handl... | `bin/test_build_occurrence_table.py`, `workflow/main.nf.test` | done |
| `BT-21` | The optimistic taxonomy column is derived from full_taxonomy (column 2 of .sintax), r... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-22` | Total reads in the optimistic table ≥ total reads in the filtered table when both con... | `bin/build_occurrence_table.bats`, `workflow/main.nf.test` | done |
| `BT-23` | The probability annotations are still stripped (no (0.xx) substrings remain in the ta... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py`, `workflow/main.nf.test` | done |
| `BT-24` | An all-blank filtered column (every read unassigned) neither aborts nor vanishes: tho... | `bin/build_occurrence_table.bats`, `bin/test_build_occurrence_table.py` | done |
| `BT-25` | A barcode with at least one non-empty .sintax chunk is never re-added as an empty col... | `bin/test_build_occurrence_table.py` | done |
| `BT-30` | name_optimistic_output("foo.tsv") == "foo_optimistic.tsv"; name_optimistic_output("a/... | `bin/test_build_occurrence_table.py` | done |
| `BT-31` | partition_by_size splits files into (non-empty, empty) — exact complements on existin... | `bin/test_build_occurrence_table.py` | done |
| `BT-32` | mixed). | `bin/test_build_occurrence_table.py` | done |
| `BT-33` | strip_probabilities removes the (0.xx) probability suffixes from every rank. | `bin/test_build_occurrence_table.py` | done |
| `BT-34` | mark_unassigned replaces empty/None taxonomy values with the literal string "unknown". | `bin/test_build_occurrence_table.py` | done |
| `BT-35` | count_assignments produces one count per (barcode, taxonomy) pair. | `bin/test_build_occurrence_table.py` | done |
| `BT-36` | render_table adds a total column equal to the sum across barcodes for each taxonomy. | `bin/test_build_occurrence_table.py` | done |
| `BT-37` | render_table appends one zero-filled column per empty barcode, preserving existing co... | `bin/test_build_occurrence_table.py` | done |
| `BT-38` | main on an empty input set returns a non-zero exit code with No sintax files found. | `bin/test_build_occurrence_table.py` | done |

## 5. `bin/lib/validation.sh`

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `VL-01` | require_arg "X" "" returns non-zero and prints Error: X is required. to stderr. | `bin/validation.bats` | done |
| `VL-02` | require_arg "X" "something" returns 0 and prints nothing. | `bin/validation.bats` | done |
| `VL-03` | check_readable file <path> <label> returns 0 for a readable file, non-zero with not f... | `bin/validation.bats` | done |
| `VL-04` | check_readable dir <path> <label> mirrors the file behaviour for directories. | `bin/validation.bats` | done |

## 6. Config invariants (`nextflow.config`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `CFG-01` | manifest.version and CITATION.cff's version resolve to the same value (bump both on e... | `config/summary.bats`, `config/version.bats` | done |
| `CFG-02` | publish_mode accepts link (default), copy, copyNoFollow, symlink and rellink, and rej... | `config/publish_modes.bats` | done |
| `CFG-03` | cleanup = true combined with a link publish mode (symlink/rellink) aborts at startup,... | `config/publish_modes.bats`, `workflow/main.nf.test` | done |
| `CFG-04` | Resource ceiling. process.resourceLimits clamps every per-process request — including... | `config/resources.bats`, `config/version.bats` | done |
| `CFG-05` | manifest declares a minimum Nextflow version (a) and a default branch (c). The floor... | `config/version.bats` | done |
| `CFG-06` | Startup run summary. Every result-affecting parameter is logged before any process ru... | `config/resources.bats`, `config/summary.bats` | done |

## 7. Observations worth noting in the spec (not bugs, but ambiguities)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `OBS-03` | SINTAX runs vsearch with --threads > 1, which is non-deterministic. SX-3x tests must... | — | n/a |
| `OBS-04` | The script silently creates the output parent directory (build_occurrence_table.py, v... | — | n/a |
| `OBS-05` | param.results_table is consumed by BUILD_TABLE as file(params.results_table).name for... | — | n/a |

## 8. `KRONA` module + `build_krona.py` / `build_krona.sh`

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `KR-01` | Missing --input aborts with --input is required. | `bin/test_build_krona.py` | done |
| `KR-02` | Missing --output-dir aborts with --output-dir is required. | `bin/test_build_krona.py` | done |
| `KR-03` | --input that does not exist aborts with Path does not exist. | `bin/test_build_krona.py` | done |
| `KR-04` | The output directory is created if missing, and per-barcode files are written into it. | `bin/test_build_krona.py` | done |
| `KR-30` | taxonomy_to_levels("d:X,k:Y,s:Z") → ["d:X","k:Y","s:Z"]; "unknown" → ["unknown"] (ran... | `bin/test_build_krona.py` | done |
| `KR-31` | parse_header never treats the taxonomy / total columns as barcodes. | `bin/test_build_krona.py` | done |
| `KR-32` | Zero-count cells are excluded; each emitted line's count equals the TSV cell exactly. | `bin/test_build_krona.py` | done |
| `KR-33` | render_krona_text lines are count<TAB>level…, higher rank first; an empty row set ren... | `bin/test_build_krona.py` | done |
| `KR-34` | One <barcode>.txt per non-empty barcode, in column order; an all-zero barcode is skip... | `bin/test_build_krona.py` | done |
| `KR-35` | No (0.xx) probability substrings appear in any emitted level (they are already stripp... | `bin/test_build_krona.py` | done |
| `KR-40` | build_krona.sh on an occurrence table produces a non-empty krona.html that carries a... | `bin/build_krona_cli.bats` | done |
| `KR-41` | The HTML holds one dataset per non-empty barcode (labelled by barcode name); an all-z... | `bin/build_krona_cli.bats` | done |
| `KR-42` | Given both tables, the driver names outputs by input: krona.html for the filtered tab... | `bin/build_krona_cli.bats` | done |

## 9. Shared helper functions (`modules/local/functions.nf`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `FN-01` | coerce_bool(v) returns a real Boolean: the string 'true' and Boolean true → true; 'fa... | `modules/functions.nf.test` | done |
| `FN-02` | valid_bool(v) is true only when v is a Boolean or the string 'true'/'false'; any othe... | `modules/functions.nf.test` | done |
| `FN-03` | optimistic_name(name) inserts _optimistic before the final extension: sintax.tsv → si... | `modules/functions.nf.test`, `workflow/main.nf.test` | done |
| `FN-04` | fastq_extensions() returns the four supported suffixes without a leading dot (fastq,... | `modules/functions.nf.test` | done |
| `FN-05` | valid_memory(v) is true for anything Nextflow can read as a positive memory size, in... | `modules/functions.nf.test` | done |
| `FN-06` | effective_threads(configured, ceiling) is the thread count a process really gets: the... | `modules/functions.nf.test` | done |

## 10. Provenance (`DUMP_VERSIONS`, `DUMP_PARAMS`, execution reports)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `PRV-01` | software_versions.yml is published to pipeline_info/ and records vsearch, cutadapt, k... | `modules/dump_versions.nf.test` | done |
| `PRV-02` | A tool that cannot be probed is recorded as n/a, never dropped: an absent line reads... | `modules/dump_versions.nf.test` | done |
| `PRV-03` | dorado's version comes from BASECALL itself, as a <name><TAB><raw> fragment merged by... | `modules/dump_versions.nf.test`, `workflow/basecall.nf.test` | done |
| `PRV-04` | params.json is published to pipeline_info/ holding exactly the JSON main.nf rendered... | `modules/dump_params.nf.test`, `modules/dump_versions.nf.test` | done |
| `PRV-05` | The four execution reports (execution_report.html, execution_timeline.html, execution... | `config/provenance.bats` | done |
| `PRV-06` | End-to-end, software_versions.yml records real versions for the tools that ran (a) an... | `config/provenance.bats` | done |
| `PRV-07` | End-to-end, params.json records the effective configuration: the values actually in f... | `config/provenance.bats` | done |
| `PRV-08` | Provenance sits *beside* the analysis outputs, not among them: the results directory... | `config/provenance.bats` | done |
| `PRV-10` | collect_versions.py::extract_version finds the version token in every shape the real... | `bin/test_collect_versions.py` | done |
| `PRV-11` | Unrecognisable output (empty, command not found, Unknown option: version) yields n/a,... | `bin/test_collect_versions.py` | done |
| `PRV-12` | A later duplicate name wins, which is what lets BASECALL's appended dorado fragment c... | `bin/test_collect_versions.py` | done |
| `PRV-13` | to_yaml is sorted and deterministic: the same versions in any order render byte-ident... | `bin/test_collect_versions.py` | done |

## 11. Cluster and container profiles (`conf/`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `CLU-01` | Every shipped profile resolves (standard, slurm, cluster, the five sites, conda, and... | `config/cluster_profiles.bats` | done |
| `CLU-02` | A cluster profile *implies* slurm — each includes conf/slurm.config, so a user never... | `config/cluster_profiles.bats` | done |
| `CLU-03` | Each site sets its own ceiling to its largest node, and resourceLimits is rebuilt fro... | `config/cluster_profiles.bats` | done |
| `CLU-04` | cluster remains an exact alias of slurm: the two resolve identically. It shipped in v... | `config/cluster_profiles.bats` | done |
| `CLU-05` | The sites batch tasks into slurm job arrays (process.array). One task per barcode, up... | `config/cluster_profiles.bats` | done |
| `CLU-06` | Each engine profile enables its engine plus Wave, which builds the image from the sam... | `config/cluster_profiles.bats` | done |
| `CLU-07` | BASECALL is never given a conda directive under any profile, so it is never container... | `config/cluster_profiles.bats` | done |
| `CLU-08` | Every conf/clusters/<name>.config is registered as a profile (dead config otherwise)... | `config/cluster_profiles.bats` | done |
| `CLU-09` | Basecalling under a scheduler is refused at startup, with a message that says what to... | `config/cluster_profiles.bats` | done |

## 9. Shared helper functions (`modules/local/functions.nf`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `FN-07` | effective_outdir(outdir, results_table) resolves the run's single output directory: o... | `modules/functions.nf.test` | done |
| `FN-08` | effective_table_name(table_name, results_table) is results_table's basename when that... | `modules/functions.nf.test` | done |

## 12. Output layout (`outdir`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `OUT-01` | Everything a run produces lands under outdir: both tables, per_barcode/<barcode>.sint... | `config/outdir.bats` | done |
| `OUT-02` | outdir defaults to results when neither it nor results_table is given, so a bare invo... | `config/outdir.bats` | done |
| `OUT-03` | The deprecated results_table still produces exactly what it did: its parent becomes o... | `config/outdir.bats` | done |
| `OUT-04` | When both outdir and results_table are set, outdir wins and the table keeps the name ... | `config/outdir.bats` | done |
| `OUT-05` | publish_beside_reads (deprecated) restores the pre-v1.12.0 location additively — the ... | `config/outdir.bats`, `modules/sintax.nf.test` | done |
| `OUT-06` | table_name must be a filename, not a path: a path would silently escape outdir, which... | `config/outdir.bats` | done |

## 9. Shared helper functions (`modules/local/functions.nf`)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `FN-09` | nearest_param(name, candidates) suggests the declared parameter closest to a mistyped... | `modules/functions.nf.test` | done |
| `FN-10` | known_params() returns the declared parameter surface as a usable list, including the... | `modules/functions.nf.test` | done |

## 13. Parameter surface (strict validation)

| Spec | Behaviour | Test(s) | Status |
|------|-----------|---------|--------|
| `PRM-01` | An undeclared parameter aborts at startup (a), with the nearest declared name suggest... | `bin/test_known_params.py`, `config/params_strict.bats`, `modules/functions.nf.test` | done |
| `PRM-02` | known_params() matches the parameter surface the config declares, in both directions:... | `bin/test_known_params.py`, `modules/functions.nf.test` | done |

## Removed

These IDs were retired with the behaviour they described; they
are struck through in SPECIFICATIONS.md and need no coverage.

| Spec | Status |
|------|--------|
| `OBS-01` | removed |
| `OBS-02` | removed |
| `SX-20` | removed |
| `SX-21` | removed |
| `SX-34` | removed |
