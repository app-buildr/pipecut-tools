#!/bin/bash
# Construit ffmpeg et ffprobe pour macOS Apple Silicon depuis les sources officielles : le projet FFmpeg ne publie
# aucun binaire. Chaque source est figée par son commit, vérifié après le téléchargement. Binaires autonomes :
# bibliothèques liées en statique, aucune dépendance hors du système, ni à Homebrew ni à MacPorts.
#
# Seul ce dont PipeCut se sert est compilé : x264 (encodage), dav1d (lecture de l'AV1), libass et ses dépendances
# (incrustation des sous-titres). Le reste vient de ffmpeg (décodeurs, AAC) et de macOS (HTTPS, VideoToolbox).
#
# Prérequis : Xcode, git, pkg-config, meson et ninja.
# Usage : scripts/build-ffmpeg.sh   (résultat dans dist/ffmpeg-<version>)

set -euo pipefail

VERSION=9.0.2
MACOS_MIN=13.3

# nom, dépôt officiel, tag ou branche, commit attendu
SOURCES=(
  "ffmpeg https://git.ffmpeg.org/ffmpeg.git n9.0.2 946fcce07b6dcd0331c8cc609192aeff5e1924f8"
  "x264 https://code.videolan.org/videolan/x264.git stable b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
  "dav1d https://code.videolan.org/videolan/dav1d.git 1.5.4 54706fc6bc0cdecab7e9593974a4039cc038fca7"
  "freetype https://gitlab.freedesktop.org/freetype/freetype.git VER-2-15-0 37515cf56ba3349656049edbed89ffc6f6466f2d"
  "fribidi https://github.com/fribidi/fribidi.git v1.0.18 15393e4937aa95bcf865d92143735746aeb654fa"
  "harfbuzz https://github.com/harfbuzz/harfbuzz.git 15.1.0 3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372"
  "libass https://github.com/libass/libass.git 0.17.5 4a05d8127f525943ebf45fdc6497c9e665947f0d"
)

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# hors du dossier personnel : les binaires gardent les chemins de leur compilation, jamais de nom de compte
work="/Users/Shared/pipecut-tools-build/ffmpeg-$VERSION"
src="$work/src"
prefix="$work/prefix"
out="$root/dist/ffmpeg-$VERSION"
mkdir -p "$src" "$prefix" "$out"

# aussi pour l'assembleur, qui ne reçoit pas toujours les options ci-dessous
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN
flags="-arch arm64 -mmacosx-version-min=$MACOS_MIN"
export CFLAGS="$flags -I$prefix/include"
export CXXFLAGS="$flags -I$prefix/include"
export LDFLAGS="$flags -L$prefix/lib"
# rien d'autre que ce qui est compilé ici
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
unset PKG_CONFIG_PATH

for entry in "${SOURCES[@]}"; do
  read -r name url ref commit <<<"$entry"
  dir="$src/$name"
  if [ ! -d "$dir/.git" ]; then
    echo "↓ $name $ref"
    git clone --quiet --depth 1 --branch "$ref" "$url" "$dir"
  fi
  actual=$(git -C "$dir" rev-parse HEAD)
  if [ "$actual" != "$commit" ]; then
    echo "Erreur : $name est au commit $actual, attendu : $commit" >&2
    exit 1
  fi
done

meson_build() {
  local name=$1
  shift
  echo "⚙ $name"
  meson setup "$work/build-$name" "$src/$name" --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static --wrap-mode=nodownload "$@"
  ninja -C "$work/build-$name" install
}

if [ ! -f "$prefix/lib/libx264.a" ]; then
  echo "⚙ x264"
  (cd "$src/x264" && ./configure --prefix="$prefix" --enable-static --disable-cli --enable-pic \
    --extra-cflags="$flags" --extra-ldflags="$flags" && make -j"$(sysctl -n hw.ncpu)" && make install)
fi
[ -f "$prefix/lib/libdav1d.a" ] || meson_build dav1d -Denable_tools=false -Denable_tests=false
[ -f "$prefix/lib/libfreetype.a" ] || meson_build freetype -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
  -Dpng=disabled -Dzlib=disabled -Dtests=disabled
[ -f "$prefix/lib/libfribidi.a" ] || meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
[ -f "$prefix/lib/libharfbuzz.a" ] || meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
  -Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
[ -f "$prefix/lib/libass.a" ] || meson_build libass -Dfontconfig=disabled -Dcoretext=enabled -Dtest=disabled \
  -Dprofile=disabled -Dcompare=disabled -Dfuzz=disabled -Dcheckasm=disabled

echo "⚙ ffmpeg"
(
  cd "$src/ffmpeg"
  ./configure --prefix="$prefix" --arch=arm64 --cc=clang --cxx=clang++ \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-version=pipecut --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --extra-libs="-lc++" \
    --disable-autodetect --disable-debug --disable-doc --disable-ffplay \
    --enable-static --disable-shared --enable-gpl --enable-version3 \
    --enable-zlib --enable-bzlib --enable-iconv --enable-securetransport \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-libx264 --enable-libdav1d --enable-libass
  make -j"$(sysctl -n hw.ncpu)"
)

for tool in ffmpeg ffprobe; do
  cp "$src/ffmpeg/$tool" "$out/$tool"
  strip -x "$out/$tool"
  codesign --force --sign - "$out/$tool"
  # seules les bibliothèques du système : tout le reste doit être lié en statique
  if otool -L "$out/$tool" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
    echo "Erreur : $tool dépend d'une bibliothèque hors du système." >&2
    exit 1
  fi
  if strings -a "$out/$tool" | grep -qi "$(id -un)"; then
    echo "Erreur : $tool contient le nom du compte qui l'a construit." >&2
    exit 1
  fi
  "$out/$tool" -hide_banner -version | head -1
  rm -f "$out/$tool.zip"
  ditto -c -k --norsrc --noextattr --noqtn "$out/$tool" "$out/$tool.zip"
done

# La licence GPL demande de fournir les sources exactes de ce qui est distribué
echo "⚙ archive des sources"
archive="$out/ffmpeg-$VERSION-sources"
rm -rf "$archive" "$archive.tar.xz"
mkdir -p "$archive"
for entry in "${SOURCES[@]}"; do
  read -r name url ref commit <<<"$entry"
  mkdir -p "$archive/$name"
  git -C "$src/$name" archive HEAD | tar -x -C "$archive/$name"
  echo "$name $ref $commit $url" >>"$archive/SOURCES.txt"
done
cp "$0" "$archive/build-ffmpeg.sh"
tar -C "$out" --uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata \
  -cJf "$archive.tar.xz" "$(basename "$archive")"
rm -rf "$archive"

(cd "$out" && shasum -a 256 ffmpeg.zip ffprobe.zip "$(basename "$archive").tar.xz" | tee SHA256SUMS)
