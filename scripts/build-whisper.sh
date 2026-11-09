#!/bin/bash
# Construit whisper-cli pour macOS Apple Silicon depuis les sources officielles : whisper.cpp ne publie aucun
# binaire macOS. Binaire autonome : bibliothèques liées en statique, code Metal embarqué, aucune dépendance hors
# du système. GGML_NATIVE=OFF : il doit tourner sur tous les Apple Silicon, pas seulement sur le Mac qui construit.
#
# Prérequis : Xcode, git et cmake.
# Usage : scripts/build-whisper.sh   (résultat dans dist/whisper-cli-<version>)

set -euo pipefail

VERSION=1.9.5
COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
MACOS_MIN=13.3

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# hors du dossier personnel : le binaire garde les chemins de sa compilation, jamais de nom de compte
work="/Users/Shared/pipecut-tools-build/whisper-$VERSION"
src="$work/whisper.cpp"
out="$root/dist/whisper-cli-$VERSION"
mkdir -p "$work" "$out"

if [ ! -d "$src/.git" ]; then
  git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/ggml-org/whisper.cpp.git "$src"
fi
actual=$(git -C "$src" rev-parse HEAD)
if [ "$actual" != "$COMMIT" ]; then
  echo "Erreur : whisper.cpp est au commit $actual, attendu : $COMMIT" >&2
  exit 1
fi

cmake -S "$src" -B "$src/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DWHISPER_SDL2=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF
cmake --build "$src/build" --config Release -j --target whisper-cli

cp "$src/build/bin/whisper-cli" "$out/whisper-cli"
strip -x "$out/whisper-cli"
codesign --force --sign - "$out/whisper-cli"
"$out/whisper-cli" --version

# seules les bibliothèques du système : tout le reste doit être lié en statique
if otool -L "$out/whisper-cli" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
  echo "Erreur : whisper-cli dépend d'une bibliothèque hors du système." >&2
  exit 1
fi
if strings -a "$out/whisper-cli" | grep -qi "$(id -un)"; then
  echo "Erreur : whisper-cli contient le nom du compte qui l'a construit." >&2
  exit 1
fi

rm -f "$out/whisper-cli-macos-arm64.zip"
ditto -c -k --norsrc --noextattr --noqtn "$out/whisper-cli" "$out/whisper-cli-macos-arm64.zip"
(cd "$out" && shasum -a 256 whisper-cli-macos-arm64.zip | tee SHA256SUMS)
