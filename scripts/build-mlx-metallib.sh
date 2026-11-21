#!/bin/bash
# scripts/build-mlx-metallib.sh <output.metallib> — compile MLX's Metal kernels for on-device speech.
#
# Replaces speech-swift's build_mlx_metallib.sh, which passes no -std: the Metal compiler shipped with
# Xcode 27 defaults to a language version MLX's kernels don't compile under. Pinned to Metal 4.0, the
# macOS 26 baseline. Rebuilds only when the kernel sources change.

set -euo pipefail
OUT="${1:?usage: build-mlx-metallib.sh <output.metallib>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MLX_DIR="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS="$MLX_DIR/mlx/backend/metal/kernels"
METAL_STD="metal4.0"

[ -d "$KERNELS" ] || { echo "!! MLX kernels not found at $KERNELS — run swift build first" >&2; exit 1; }

HASH="$( { echo "$METAL_STD"; find "$KERNELS" -type f \( -name '*.metal' -o -name '*.h' \) ! -name '*_nax.metal' \
  | LC_ALL=C sort | xargs cat; } | shasum -a 256 | awk '{print $1}')"
if [ -f "$OUT" ] && [ "$(cat "$OUT.sha" 2>/dev/null)" = "$HASH" ]; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Compiling MLX Metal kernels (-std=$METAL_STD)"
export KERNELS MLX_DIR METAL_STD TMP
find "$KERNELS" -type f -name '*.metal' ! -name '*_nax.metal' -print0 | LC_ALL=C sort -z |
  xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} bash -c '
    src="$1"; air="$TMP/$(printf "%s" "${src#"$KERNELS/"}" | shasum -a 256 | cut -c1-16).air"
    xcrun -sdk macosx metal -x metal -std="$METAL_STD" -Wall -Wextra -fno-fast-math \
      -Wno-c++17-extensions -Wno-c++20-extensions -c "$src" -I"$KERNELS" -I"$MLX_DIR" -o "$air" \
      || { echo "!! failed: $src" >&2; exit 255; }
  ' _ {}

mkdir -p "$(dirname "$OUT")"
xcrun -sdk macosx metallib "$TMP"/*.air -o "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
printf '%s' "$HASH" > "$OUT.sha"
echo "==> Wrote $OUT"
