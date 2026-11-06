# Clipr tools

Dépôt public de [Clipr](https://app-buildr.github.io/clipr/) : ce que l'app et ses utilisateurs doivent pouvoir
lire sans compte. Le code de l'app est ailleurs.

- **Releases `v<version>`** : les versions de Clipr et leurs mises à jour.
- **Release `outils`** : `tools.json`, les versions de yt-dlp et Deno proposées aux apps installées.
- **`announcements.json`** : les messages affichés dans l'app.
- **Releases `ffmpeg-<version>` et `whisper-cli-<version>`** : les binaires que leurs projets ne publient pas.

## Binaires

FFmpeg et whisper.cpp ne publient aucun binaire macOS. Ils sont construits ici depuis leurs sources officielles,
sans modification, pour macOS Apple Silicon (13.3 ou plus récent).

| Outil | Script | Sources |
| --- | --- | --- |
| ffmpeg, ffprobe | `scripts/build-ffmpeg.sh` | [FFmpeg](https://github.com/FFmpeg/FFmpeg), [x264](https://code.videolan.org/videolan/x264), [dav1d](https://github.com/videolan/dav1d), [libass](https://github.com/libass/libass), [FreeType](https://github.com/freetype/freetype), [FriBidi](https://github.com/fribidi/fribidi), [HarfBuzz](https://github.com/harfbuzz/harfbuzz) |
| whisper-cli | `scripts/build-whisper.sh` | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |

Chaque script fige les sources par leur commit et refuse un binaire qui dépend d'autre chose que du système.

Pour changer de version : mettre à jour la version et les commits du script, le lancer, publier le contenu de
`dist/` sur une release `<outil>-<version>` en préversion (jamais « latest », réservé aux versions de Clipr), puis
reporter adresses et empreintes dans `scripts/tools.mjs` de Clipr.

## Licences

ffmpeg et ffprobe sont sous GPL v3 (build avec libx264). Leurs sources exactes, bibliothèques comprises, sont dans
l'archive `ffmpeg-<version>-sources.tar.xz` de chaque release. whisper.cpp est sous licence MIT.
