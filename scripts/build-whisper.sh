#!/bin/bash
# Construit whisper-cli depuis les sources officielles, pour macOS Apple Silicon ou Windows x64 : whisper.cpp ne
# publie aucun binaire macOS, et aucun de cette version pour Windows. GGML_NATIVE=OFF : il doit tourner sur toutes
# les machines, pas seulement sur celle qui construit.
#
# macOS : binaire autonome, bibliothèques liées en statique, code Metal embarqué, aucune dépendance hors du système.
#
# Windows : un dossier, construit depuis macOS par mingw-w64. whisper-cli.exe y charge ses bibliothèques, dont une
# variante du calcul par génération de processeur (ggml-cpu-*.dll), choisie au lancement, comme dans les binaires
# que publie llama.cpp : un programme unique ne tournerait pas sur les processeurs sans AVX2. Le calcul se fait
# sur le processeur seul. Aucune dépendance hors de Windows et du dossier.
#
# Prérequis : Xcode, git et cmake ; pour Windows, mingw-w64 en plus.
# Usage : scripts/build-whisper.sh [macos-arm64|windows-x64]   (macOS par défaut ; résultat dans
# dist/whisper-cli-<version>)

set -euo pipefail

VERSION=1.9.5
COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
MACOS_MIN=13.3
TARGET=${1:-macos-arm64}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# hors du dossier personnel : le binaire garde les chemins de sa compilation, jamais de nom de compte
work="/Users/Shared/pipecut-tools-build/whisper-$VERSION"
cmake_args=(-DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DWHISPER_SDL2=OFF
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF)
case "$TARGET" in
macos-arm64)
  cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  ;;
windows-x64)
  # ses propres sources : la compilation se fait dans leur dossier, une cible à la fois
  work="$work-$TARGET"
  host=x86_64-w64-mingw32
  # -static : les bibliothèques du compilateur (libgcc, libstdc++, winpthread) entrent dans chaque binaire, sans
  # DLL à livrer en plus. --exclude-libs : une bibliothèque de ggml exporte toutes ses fonctions, mais pas celles
  # du compilateur, que la suivante recevrait alors deux fois
  static="-static -Wl,--exclude-libs,libgcc_eh.a:libwinpthread.a:libpthread.a"
  cmake_args+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER="$host-gcc" -DCMAKE_CXX_COMPILER="$host-g++" -DCMAKE_RC_COMPILER="$host-windres"
    -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_SHARED_LINKER_FLAGS="$static" -DCMAKE_MODULE_LINKER_FLAGS="$static"
    -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON)
  # les bibliothèques de Windows dont un binaire peut dépendre (api-ms-win-crt-* : sa bibliothèque C, depuis
  # Windows 10)
  system_dlls='KERNEL32|ADVAPI32|api-ms-win-crt-[a-z0-9-]+'
  ;;
*)
  echo "Usage : $0 [macos-arm64|windows-x64]" >&2
  exit 1
  ;;
esac
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

cmake -S "$src" -B "$src/build" "${cmake_args[@]}"
cmake --build "$src/build" --config Release -j --target whisper-cli

if [ "$TARGET" = macos-arm64 ]; then
  package="$out/whisper-cli"
  cp "$src/build/bin/whisper-cli" "$package"
  strip -x "$package"
  codesign --force --sign - "$package"
  "$package" --version
  # seules les bibliothèques du système : tout le reste doit être lié en statique
  if otool -L "$package" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
    echo "Erreur : whisper-cli dépend d'une bibliothèque hors du système." >&2
    exit 1
  fi
  sums=SHA256SUMS
else
  # le dossier livré : le programme et les bibliothèques qu'il charge, rien d'une construction précédente. Un
  # programme de Windows ne se lance pas ici : il s'essaie sous Windows
  package="$out/whisper-cli-$TARGET"
  rm -rf "${package:?}"
  mkdir -p "$package"
  cp "$src/build/bin/whisper-cli.exe" "$src"/build/bin/*.dll "$package/"
  for bin in "$package"/*; do
    "$host-strip" "$bin"
    # seules les bibliothèques de Windows et celles du dossier
    if "$host-objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' | grep -viE "^($system_dlls)\.dll$" |
      grep -vixFf <(ls "$package"); then
      echo "Erreur : $(basename "$bin") dépend d'une bibliothèque hors du système." >&2
      exit 1
    fi
  done
  sums="SHA256SUMS-$TARGET"
fi
# grep -c lit tout : sorti au premier nom trouvé, il couperait strings, et le contrôle passerait à tort
if find "$package" -type f -exec strings -a {} + | grep -ci "$(id -un)" >/dev/null; then
  echo "Erreur : whisper-cli contient le nom du compte qui l'a construit." >&2
  exit 1
fi

rm -f "$out/whisper-cli-$TARGET.zip"
ditto -c -k --norsrc --noextattr --noqtn "$package" "$out/whisper-cli-$TARGET.zip"
(cd "$out" && shasum -a 256 "whisper-cli-$TARGET.zip" | tee "$sums")
