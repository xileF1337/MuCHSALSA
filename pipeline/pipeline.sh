#!/bin/bash
# This is an adapted version of the LazyB pipeline from
# https://github.com/TGatter/LazyB

##############################################################################
##                              Error handling                              ##
##############################################################################

set -Eeuo pipefail          # fail on any error

# Abort on errors, displaying error message + code, kill all running jobs.
clean_and_die() {
    error_code="$1"; error_message="$2"
    echo -e "\nERROR: $error_message ($error_code) in script" \
        "'$(basename $0)'" 1>&2
    jobs=$(jobs -pr); [ -z "$jobs" ] || kill $(jobs -pr)
    exit $error_code
}

trap 'clean_and_die $? "terminated unexpectedly at line $LINENO"' ERR
trap 'clean_and_die  1 "interrupted"'           INT
trap 'clean_and_die  1 "caught TERM signal"'    TERM


##############################################################################
##                                 Settings                                 ##
##############################################################################

MINLENGTH=500
ABYSS_MODE=unitigs


##############################################################################
##                                Arguments                                 ##
##############################################################################

# Check number of positional arguments.
if [ $# -lt 7 ] || [ $# -gt 9 ] ; then
    cat <<END_OF_USAGE 1>&2
MuCHSALSA -- Hybrid genome assembly pipeline
Wrong number of arguments. Usage:
    sh pipeline.sh [1:k-mer-size-filter] [2:k-mer-size-assembly] [3:name] \\
         [4:illumina-inputfile-1] [5:illumina-inputfile-2] \\
         [6:nanopore-inputfile] [7:output-folder] [8:cores=4] [9:bloom_mem=8G]
END_OF_USAGE
    exit 1
fi

K_MER_JELLY="$1"
K_MER_ABYSS="$2"
NAME="$3"
ILLUMINA_RAW_1="$4"
ILLUMINA_RAW_2="$5"
NANO="$6"
OUT_="$7"
CORES="${8:-4}"                # number of cores used by Jellyfish/Abyss/MS
BLOOM_MEM="${9:-8G}"                # 50G for H.sapiens, 2G for C.elegans

# Check existence of input files.
check_files() {
    for file in "$@"; do
        [ -s "$file" ] || {
            echo "ERROR: File '$file' is empty or does not exist" 1>&2
            exit 1
        }
    done
}
check_files "$ILLUMINA_RAW_1" "$ILLUMINA_RAW_2" "$NANO"

# Make output path absolute.
case "$OUT_" in
  /*) OUT="$OUT_";;
  *) OUT="$PWD/$OUT_";;
esac


##############################################################################
##                                 Functions                                ##
##############################################################################

# For a list of executables, check whether each one is available in path.
check_exec() {
    for name in "$@"; do
        local type="$(type -t "$name")"
        if [ -z "$type" ]; then
            echo "Could not find '$name', make sure it is available!" 1>&2
            exit 1
        fi
    done
}


##############################################################################
##                                   Main                                   ##
##############################################################################

# Get path to this script.
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

# Check that all required programs are available.
check_exec jellyfish bbduk.sh abyss-pe awk minimap2 \
    "$SCRIPTPATH/unitig_filter.py" "$SCRIPTPATH/scrubber_bfs.py" \
    "$SCRIPTPATH/muchsalsa"

mkdir -p "$OUT"               #create output folder if it doesn't already exist
TMP="$(mktemp -d -p "$OUT")"  #create a temporary folder - deleted in the end
BASE="$(basename "$NANO" .fastq)"

echo ">>>> K-mer Filtering of Illumina Reads"
jellyfish count -m "$K_MER_JELLY" -s 100M -t "$CORES" -C "$ILLUMINA_RAW_1" "$ILLUMINA_RAW_2" -o "$TMP/jelly_count_k${K_MER_JELLY}.jf"
jellyfish histo -t "$CORES" "$TMP/jelly_count_k${K_MER_JELLY}.jf" > "$TMP/jelly_histo_k${K_MER_JELLY}.histo"
TOTAL_NON_UNIQUE_KMERS="$(awk '{if($1 != "1") s += $2} END{print s}' "$TMP/jelly_histo_k${K_MER_JELLY}.histo")"
ABUNDANCE_THRESHOLD="$("$SCRIPTPATH/setAbundanceThresholdFromHisto.py" "$TMP/jelly_histo_k${K_MER_JELLY}.histo" $TOTAL_NON_UNIQUE_KMERS)"
echo "abundance threshold for k-mer filtering: " "$ABUNDANCE_THRESHOLD" > "$OUT/report.txt"
jellyfish dump -L "$ABUNDANCE_THRESHOLD" "$TMP/jelly_count_k${K_MER_JELLY}.jf" > "$TMP/filtered_kmers_${K_MER_JELLY}_${ABUNDANCE_THRESHOLD}.fa"
bbduk.sh in1="$ILLUMINA_RAW_1" in2="$ILLUMINA_RAW_2" out1="$TMP/illu_filtered.1.fastq" out2="$TMP/illu_filtered.2.fastq" ref="$TMP/filtered_kmers_${K_MER_JELLY}_${ABUNDANCE_THRESHOLD}.fa" k="$K_MER_JELLY" hdist=0

echo ">>>> Illumina Assembly"
mkdir -p "$OUT/ABYSS"   #create folder "ABYSS" for ABYSS results
# abyss-pe -C "$OUT/ABYSS" np="$CORES" name="$NAME" k="$K_MER_ABYSS" in="$TMP/illu_filtered.1.fastq $TMP/illu_filtered.2.fastq" "${ABYSS_MODE}" 2>&1 | tee "$OUT/ABYSS/abyss.log"
abyss-pe -C "$OUT/ABYSS" j="$CORES" B="$BLOOM_MEM" name="$NAME" k="$K_MER_ABYSS" in="$TMP/illu_filtered.1.fastq $TMP/illu_filtered.2.fastq" "${ABYSS_MODE}" 2>&1 | tee "$OUT/ABYSS/abyss.log"
awk -v min="$MINLENGTH" 'BEGIN {RS = ">" ; ORS = ""} $2 >= min {print ">"$0}' "$OUT/ABYSS/${NAME}-${ABYSS_MODE}.fa"  > "$OUT/ABYSS/${NAME}-${ABYSS_MODE}.l${MINLENGTH}.fa"

echo ">>>> Unitig Filter"
minimap2 -t "$CORES" -k15 -DP --dual=yes --no-long-join -w5 -m100 -g10000 -r2000 --max-chain-skip 25 --split-prefix foo "$NANO" "$OUT/ABYSS/${NAME}-${ABYSS_MODE}.l${MINLENGTH}.fa" > "$OUT/01_unitigs.to_$BASE.paf"
"$SCRIPTPATH/unitig_filter.py" "$OUT/01_unitigs.to_$BASE.paf" "$OUT/ABYSS/${NAME}-${ABYSS_MODE}.l${MINLENGTH}.fa" "$OUT/report.txt" "$TMP/unitigs_corrected.fa"

echo ">>>> Scrubbing"
minimap2 -t "$CORES" -k15 -DP --dual=yes --no-long-join -w5 -m100 -g10000 -r2000 --max-chain-skip 25 --split-prefix foo "$NANO" "$TMP/unitigs_corrected.fa" > "$OUT/01_contigs_corrected.to_$BASE.paf"
"$SCRIPTPATH/scrubber_bfs.py" "$OUT/01_contigs_corrected.to_$BASE.paf" "$NANO" "$OUT/02_$BASE.scrubbed.fa" "$TMP"

echo ">>>> Anchor Mapping"
minimap2 -t "$CORES" -k15 -DP --dual=yes --no-long-join -w5 -m100 -g10000 -r2000 --max-chain-skip 25 --split-prefix foo "$OUT/02_$BASE.scrubbed.fa" "$TMP/unitigs_corrected.fa" > "$OUT/02_contigs_corrected.to_$BASE.scrubbed.paf"

echo ">>>> MuCHSALSA"
"$SCRIPTPATH/muchsalsa" "$OUT/02_contigs_corrected.to_$BASE.scrubbed.paf" "$TMP/unitigs_corrected.fa" "$OUT/02_$BASE.scrubbed.fa" "$TMP" "$CORES"
cp "$TMP/temp_1.target.fa" "$OUT/03.assembly.unpolished.fa"
