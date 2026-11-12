#!/bin/bash
# Construit ffmpeg et ffprobe depuis les sources officielles, pour macOS Apple Silicon ou Windows x64 : le projet
# FFmpeg ne publie aucun binaire. Chaque source est figée par son commit, vérifié après le téléchargement. Binaires
# autonomes : bibliothèques liées en statique, aucune dépendance hors du système, ni à Homebrew ni à MacPorts.
#
# Seul ce dont PipeCut se sert est compilé : x264 (encodage), dav1d (lecture de l'AV1), libass et ses dépendances
# (incrustation des sous-titres). Le reste vient de ffmpeg (décodeurs, AAC) et du système (HTTPS ; VideoToolbox sous
# macOS). Windows n'a pas de zlib (images PNG, en-têtes compressés) : elle est compilée avec le reste.
#
# Les binaires de Windows se construisent depuis macOS, par mingw-w64.
#
# Prérequis : Xcode, git, pkg-config, meson et ninja ; pour Windows, mingw-w64 et nasm en plus.
# Usage : scripts/build-ffmpeg.sh [macos-arm64|windows-x64]   (macOS par défaut ; résultat dans dist/ffmpeg-<version>)

set -euo pipefail

VERSION=9.0.2
MACOS_MIN=13.3
TARGET=${1:-macos-arm64}

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
# en plus pour Windows, qui n'a pas de zlib
WINDOWS_SOURCES=(
  "zlib https://github.com/madler/zlib.git v1.4 99623ef7097352da7993ba614161fd6a311e046e"
)

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# hors du dossier personnel : les binaires gardent les chemins de leur compilation, jamais de nom de compte
work="/Users/Shared/pipecut-tools-build/ffmpeg-$VERSION"
case "$TARGET" in
macos-arm64)
  suffix=""
  exe=""
  ;;
windows-x64)
  # ses propres sources : x264 et ffmpeg se compilent dans leur dossier, une cible à la fois
  work="$work-$TARGET"
  suffix="-$TARGET"
  exe=".exe"
  host=x86_64-w64-mingw32
  SOURCES+=("${WINDOWS_SOURCES[@]}")
  ;;
*)
  echo "Usage : $0 [macos-arm64|windows-x64]" >&2
  exit 1
  ;;
esac
src="$work/src"
prefix="$work/prefix"
out="$root/dist/ffmpeg-$VERSION"
mkdir -p "$src" "$prefix" "$out"
jobs=$(sysctl -n hw.ncpu)

meson_args=(--prefix="$prefix" --libdir=lib --buildtype=release --default-library=static --wrap-mode=nodownload)
x264_args=(--prefix="$prefix" --enable-static --disable-cli)
if [ "$TARGET" = macos-arm64 ]; then
  # aussi pour l'assembleur, qui ne reçoit pas toujours les options ci-dessous
  export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN
  flags="-arch arm64 -mmacosx-version-min=$MACOS_MIN"
  export CFLAGS="$flags -I$prefix/include"
  export CXXFLAGS="$flags -I$prefix/include"
  export LDFLAGS="$flags -L$prefix/lib"
  x264_args+=(--enable-pic --extra-cflags="$flags" --extra-ldflags="$flags")
  libass_fonts=-Dcoretext=enabled
  ffmpeg_compiler=(--arch=arm64 --cc=clang --cxx=clang++)
  ffmpeg_flags=(--extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --extra-libs="-lc++")
  ffmpeg_system=(--enable-bzlib --enable-iconv --enable-securetransport --enable-videotoolbox --enable-audiotoolbox)
else
  # compilation croisée : le compilateur et ses options passent par un fichier de meson, pas par l'environnement,
  # qui vaudrait pour macOS. -static : les bibliothèques du compilateur (libgcc, libstdc++, winpthread) entrent
  # dans les binaires, sans DLL à livrer avec eux
  unset CFLAGS CXXFLAGS LDFLAGS
  cat >"$work/$TARGET.ini" <<EOF
[binaries]
c = '$host-gcc'
cpp = '$host-g++'
ar = '$host-ar'
strip = '$host-strip'
windres = '$host-windres'
pkg-config = 'pkg-config'
nasm = 'nasm'

[built-in options]
c_args = ['-I$prefix/include']
cpp_args = ['-I$prefix/include']
c_link_args = ['-L$prefix/lib', '-static']
cpp_link_args = ['-L$prefix/lib', '-static']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  meson_args+=(--cross-file="$work/$TARGET.ini")
  x264_args+=(--host="$host" --cross-prefix="$host-")
  libass_fonts=-Ddirectwrite=enabled
  ffmpeg_compiler=(--arch=x86_64 --target-os=mingw32 --cross-prefix="$host-")
  ffmpeg_flags=(--extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib -static" --extra-libs="-lstdc++")
  # les fils d'exécution de Windows, plutôt que ceux de winpthread qui les imitent. Ni bzlib ni iconv, que Windows
  # n'a pas : PipeCut ne s'en sert pas (pistes Matroska compressées en bzip2, sous-titres dans un autre codage
  # qu'UTF-8). Pas de capture par Video for Windows, qui ferait dépendre les binaires d'AVICAP32.dll
  ffmpeg_system=(--enable-schannel --enable-w32threads --disable-pthreads --disable-indev=vfwcap)
  # les bibliothèques de Windows dont un binaire peut dépendre (api-ms-win-crt-* : sa bibliothèque C, depuis
  # Windows 10)
  system_dlls='KERNEL32|USER32|GDI32|ADVAPI32|SHELL32|SHLWAPI|ole32|OLEAUT32|WS2_32|bcrypt|CRYPT32|ncrypt|Secur32|api-ms-win-crt-[a-z0-9-]+'
fi
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
  meson setup "$work/build-$name" "$src/$name" "${meson_args[@]}" "$@"
  ninja -C "$work/build-$name" install
}

if [ ! -f "$prefix/lib/libx264.a" ]; then
  echo "⚙ x264"
  (cd "$src/x264" && ./configure "${x264_args[@]}" && make -j"$jobs" && make install)
fi
if [ "$TARGET" = windows-x64 ] && [ ! -f "$prefix/lib/libz.a" ]; then
  echo "⚙ zlib"
  make -C "$src/zlib" -f win32/Makefile.gcc -j"$jobs" PREFIX="$host-" libz.a
  mkdir -p "$prefix/include" "$prefix/lib"
  cp "$src/zlib/zlib.h" "$src/zlib/zconf.h" "$prefix/include/"
  cp "$src/zlib/libz.a" "$prefix/lib/"
fi
[ -f "$prefix/lib/libdav1d.a" ] || meson_build dav1d -Denable_tools=false -Denable_tests=false
[ -f "$prefix/lib/libfreetype.a" ] || meson_build freetype -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
  -Dpng=disabled -Dzlib=disabled -Dtests=disabled
[ -f "$prefix/lib/libfribidi.a" ] || meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
[ -f "$prefix/lib/libharfbuzz.a" ] || meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
  -Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
# les polices du système : par Core Text sous macOS, par DirectWrite sous Windows
[ -f "$prefix/lib/libass.a" ] || meson_build libass -Dfontconfig=disabled "$libass_fonts" -Dtest=disabled \
  -Dprofile=disabled -Dcompare=disabled -Dfuzz=disabled -Dcheckasm=disabled

echo "⚙ ffmpeg"
(
  cd "$src/ffmpeg"
  ./configure --prefix="$prefix" "${ffmpeg_compiler[@]}" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-version=pipecut "${ffmpeg_flags[@]}" \
    --disable-autodetect --disable-debug --disable-doc --disable-ffplay \
    --enable-static --disable-shared --enable-gpl --enable-version3 \
    --enable-zlib "${ffmpeg_system[@]}" \
    --enable-libx264 --enable-libdav1d --enable-libass
  make -j"$jobs"
)

for tool in ffmpeg ffprobe; do
  bin="$out/$tool$exe"
  cp "$src/ffmpeg/$tool$exe" "$bin"
  # seules les bibliothèques du système : tout le reste doit être lié en statique
  if [ "$TARGET" = macos-arm64 ]; then
    strip -x "$bin"
    codesign --force --sign - "$bin"
    if otool -L "$bin" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
      echo "Erreur : $tool dépend d'une bibliothèque hors du système." >&2
      exit 1
    fi
  else
    "$host-strip" "$bin"
    if "$host-objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' | grep -viE "^($system_dlls)\.dll$"; then
      echo "Erreur : $tool dépend d'une bibliothèque hors du système." >&2
      exit 1
    fi
  fi
  # grep -c lit tout : sorti au premier nom trouvé, il couperait strings, et le contrôle passerait à tort
  if strings -a "$bin" | grep -ci "$(id -un)" >/dev/null; then
    echo "Erreur : $tool contient le nom du compte qui l'a construit." >&2
    exit 1
  fi
  # un programme de Windows ne se lance pas ici : il s'essaie sous Windows
  if [ "$TARGET" = macos-arm64 ]; then
    "$bin" -hide_banner -version | head -1
  fi
  rm -f "$out/$tool$suffix.zip"
  ditto -c -k --norsrc --noextattr --noqtn "$bin" "$out/$tool$suffix.zip"
done

# La licence GPL demande de fournir les sources exactes de ce qui est distribué
echo "⚙ archive des sources"
archive="$out/ffmpeg-$VERSION$suffix-sources"
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

(cd "$out" && shasum -a 256 "ffmpeg$suffix.zip" "ffprobe$suffix.zip" "$(basename "$archive").tar.xz" |
  tee "SHA256SUMS$suffix")
