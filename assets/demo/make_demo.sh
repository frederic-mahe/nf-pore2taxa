#!/bin/bash
#
# Regenerate the bundled demo dataset.
#
# Run by hand when the demo design changes; the files it writes are
# committed, so `-profile demo` needs no generation step and works from a
# fresh clone.
#
# This is deliberately separate from tests/fixtures/. The fixtures encode
# awkward cases the test suite needs (a primer-less barcode that must yield
# an empty .sintax, a flat layout, a fastq_fail to ignore) and are free to
# change whenever a test needs them to. The demo is a user-facing artefact:
# it should look like a small, healthy run and stay stable.
#
# Layout produced:
#   reference.fasta                  sintax-formatted reference (2 taxa)
#   fastq_pass/barcode01/reads.fastq.gz   5 reads matching ref1
#   fastq_pass/barcode02/reads.fastq.gz   5 reads matching ref2
#   fastq_pass/barcode03/reads.fastq.gz   3 reads matching ref1, 2 ref2
#
# The reads are synthetic and not biologically meaningful. The point is that
# the tools, the wiring and the environment work end to end and produce a
# table with the shape a real run produces.

set -euo pipefail

cd "$(dirname "$0")"

# The primers the README uses in its examples, so a reader can follow the
# demo invocation and the documented one interchangeably.
PRIMER_F="GTACACACCGCCCGTCG"

# Reverse-complement of the reverse primer CGCCTSCSCTTANTDATATGC, with one
# IUPAC realisation (H->A, N->A, S->C); cutadapt's 0.2 error rate tolerates
# the remaining ambiguity-vs-actual mismatches.
RC_PRIMER_R="GCATATAATAAGCGCAGGCG"

# Two short, distinct, GC-balanced synthetic references. Identical to the
# test fixtures' pair on purpose: two datasets that disagree about what
# "Alpha" means would be needlessly confusing when reading both.
REF1="GACAGGTACAAGAAGGAGTATGCATCAATGTGGTCGTGTGGAACAAACGCCACTGGAGACTGGGTTAACCATTCGCTCCAGCGTCATGAAAGTCACTGTTAGGGCGACCTTCGATTCGGATGTGACATTTCATTACATTACGCTCAGGACTGCGAACGAA"
REF2="AGATTAAGAATGCTTAACCCGGTACCTAACCCATCTGATTTTTACACACTCTCCTTGGACTGGGAGGTATAAGGAATAGGCGGTAGACGCCTACTTAACTTTCATGGTGATCGTAAAGCGGAGCCTTACCATGCGGCAATTGTGAACTTTTAAATTCGAT"


## ------------------------------------------------- reference (sintax format)

cat > reference.fasta <<EOF
>ref1;tax=d:Synthetica,k:Alphakingdom,p:Alphaphylum,c:Alphaclass,o:Alphaorder,f:Alphafamily,g:Alphagenus,s:Alpha_one
${REF1}
>ref2;tax=d:Synthetica,k:Betakingdom,p:Betaphylum,c:Betaclass,o:Betaorder,f:Betafamily,g:Betagenus,s:Beta_two
${REF2}
EOF


## ------------------------------------------------------------- fastq writer

# One fastq record on stdout. Quality is all 'I' (Phred 40): the pipeline
# never filters on quality, so varying it would imply a knob that is not there.
write_read() {
    local -r id="${1}"
    local -r seq="${2}"
    local qual=""
    local i
    for ((i = 0 ; i < ${#seq} ; i++)) ; do qual+="I" ; done
    printf '@%s\n%s\n+\n%s\n' "${id}" "${seq}" "${qual}"
}


## --------------------------------------------------------- three barcodes

mkdir -p fastq_pass/barcode01 fastq_pass/barcode02 fastq_pass/barcode03

# Two single-taxon samples...
{
    for i in 1 2 3 4 5 ; do
        write_read "demo_read${i}_b01" "${PRIMER_F}${REF1}${RC_PRIMER_R}"
    done
} | gzip > fastq_pass/barcode01/reads.fastq.gz

{
    for i in 1 2 3 4 5 ; do
        write_read "demo_read${i}_b02" "${PRIMER_F}${REF2}${RC_PRIMER_R}"
    done
} | gzip > fastq_pass/barcode02/reads.fastq.gz

# ...and one mixed sample, so the demo table has a barcode with two taxa in
# it and a reader sees the shape a real occurrence table has rather than a
# diagonal.
{
    for i in 1 2 3 ; do
        write_read "demo_read${i}_b03" "${PRIMER_F}${REF1}${RC_PRIMER_R}"
    done
    for i in 4 5 ; do
        write_read "demo_read${i}_b03" "${PRIMER_F}${REF2}${RC_PRIMER_R}"
    done
} | gzip > fastq_pass/barcode03/reads.fastq.gz

echo "demo dataset written to $(pwd)"
find . -type f | sort | sed 's/^/  /'
