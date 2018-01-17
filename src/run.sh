#!/bin/bash -eu

SOLEIL_SRC="$(cd "$(dirname "$(perl -MCwd -le 'print Cwd::abs_path(shift)' "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SOLEIL_SRC"

if [[ $(uname -n) == *"titan"* ]]; then
    qsub soleil.pbs
else
    LD_LIBRARY_PATH="$LEGION_DIR"/bindings/terra/ ./soleil.exec \
        -i ../testcases/tgv_64x64x64.json \
        -ll:cpu 1 -ll:ocpu 1 -ll:onuma 0 -ll:othr 4
fi
