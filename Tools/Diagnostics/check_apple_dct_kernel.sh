#!/bin/bash
# Run both kernel implementations at normal Debug and Release optimization.
# --sanitize additionally checks bounds, lifetimes, and undefined arithmetic.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apple-dct-kernel.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
sanitizing=false
if [[ "${1:-}" == "--sanitize" ]]; then
    sanitizing=true
elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--sanitize]" >&2
    exit 2
fi
for optimization in 0 3; do
    for implementation in native scalar; do
        flags=("-O$optimization" -I "$repo_root/Sources/RFBRenderingC/include")
        if [[ "$implementation" == scalar ]]; then flags+=(-DRFB_DCT_FORCE_SCALAR); fi
        if $sanitizing; then flags+=(-fsanitize=address,undefined -fno-sanitize-recover=all); fi
        "${CC:-clang}" "${flags[@]}" \
            "$repo_root/Sources/RFBRenderingC/AppleDCTKernel.c" \
            "$repo_root/Tools/Diagnostics/apple_dct_kernel_check.c" \
            -o "$build_dir/check"
        echo "Checking $implementation at -O$optimization"
        "$build_dir/check"
    done
done
