#!/bin/zsh
# Regenerates plain-text slices of the Keysight manual into docs/manual/ (gitignored;
# the manual is Keysight's copyrighted material, so neither the PDF nor the text is committed).
# Printed page numbers equal PDF page numbers. Requires poppler (`brew install poppler`).
set -euo pipefail
cd "$(dirname "$0")/.."
out=docs/manual
mkdir -p $out
pdftotext -layout -f 21  -l 189 KeysightDMM.pdf $out/01_user_guide_p21-189.txt
pdftotext -layout -f 190 -l 431 KeysightDMM.pdf $out/02_scpi_reference_p190-431.txt
pdftotext -layout -f 432 -l 474 KeysightDMM.pdf $out/03_quick_ref_errors_defaults_p432-474.txt
wc -l $out/*.txt
