# Test fixtures

Synthetic data used by the nf-test suite and by the R/bash unit tests.
Regenerate with `./generate.sh` (it overwrites everything in this
directory except this README).

## `references.fasta`
A two-sequence sintax-formatted database. Both taxa share the domain
`Synthetica` but differ at every other rank, so sintax assignments are
easy to spot in test output.

## `fastq_dir/fastq_pass/barcodeXX/reads.fastq.gz`
Synthetic fastq.gz files mimicking the directory layout Nanopore
basecallers produce.

| Barcode     | Content                                            | Expected behaviour                                    |
| ----------- | -------------------------------------------------- | ----------------------------------------------------- |
| `barcode01` | 5 reads = `primer_f` + `ref1` + `rc(primer_r)`     | All 5 reads assigned to taxon `Alpha_one`.            |
| `barcode02` | 5 reads = `primer_f` + `ref2` + `rc(primer_r)`     | All 5 reads assigned to taxon `Beta_two`.             |
| `barcode03` | 5 reads with no primers                            | All reads dropped by cutadapt → empty `.sintax` file. |

## `sintax_dir/fastq_pass/barcodeXX/reads.sintax`
Pre-computed sintax output, captured from a real run against the
fixtures above. Used by the R-script unit tests so they do not have to
invoke vsearch.

| Barcode     | Content                                                  |
| ----------- | -------------------------------------------------------- |
| `barcode01` | 5 reads assigned to `Alpha_one` with confidence 1.00.    |
| `barcode02` | 5 reads assigned to `Beta_two`  with confidence 1.00.    |
| `barcode03` | Empty file (0 bytes).                                    |
| `barcode99` | Empty file (0 bytes) — second empty barcode for column-order checks. |
