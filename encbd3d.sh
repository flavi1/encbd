#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
# Mettre DEBUG=1 dans l'environnement pour afficher chaque commande exécutée
if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
set -euo pipefail

# Capture et affiche explicitement toute erreur d'exécution
trap 'echo -e "\n❌ [ERREUR] Le script s'\''est arrêté à la ligne $LINENO.\nCommande défaillante : $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE=""       # --output : chemin exact du fichier final
OUTPUT_STEM=""       # --output-stem : chemin sans extension ; le final sera <stem>.<layout>.mkv
TITLE_OVERRIDE=""    # --title : titre Matroska du fichier final
NO_SETTINGS_PROMPT=false   # --no-settings-prompt : réglages déjà choisis par l'appelant (encbd.sh)
WORKDIR_ROOT=""      # dossier PARENT où créer le dossier de travail (défaut : à côté de la source)
SILENT="false"
LANG_FILTER=""
CLI_OVERRIDES=()

# Bibliothèque commune : à côté du script (dépôt, AppImage) ou désignée par ENCBD_LIB_DIR.
ENCBD_LIB_DIR="${ENCBD_LIB_DIR:-$SCRIPT_DIR/lib}"
if [[ ! -f "$ENCBD_LIB_DIR/encbd-common.sh" ]]; then
  echo "❌ [ERREUR] Bibliothèque introuvable : $ENCBD_LIB_DIR/encbd-common.sh" >&2
  exit 2
fi
# shellcheck source=lib/encbd-common.sh
source "$ENCBD_LIB_DIR/encbd-common.sh"

load_config() {
  encbd_load_config
  TSMUXER_BIN="$(find_tool "${TSMUXER_BIN:-}" tsMuxeR "$SCRIPT_DIR/tsMuxer/bin/tsMuxer")"
  VSPIPE_BIN="$(find_tool "${VSPIPE_BIN:-}" vspipe "$SCRIPT_DIR/vapoursynth/.libs/vspipe")"
  MVC_SOURCE_PLUGIN="${MVC_SOURCE_PLUGIN:-$SCRIPT_DIR/mvc-source/libvsmvc.so}"
}

set_final_name() {
  if [[ -n "$OUTPUT_FILE" ]]; then
    FINAL_MKV="$OUTPUT_FILE"                               # chemin imposé, utilisé tel quel
  elif [[ -n "$OUTPUT_STEM" ]]; then
    FINAL_MKV="$OUTPUT_STEM.${STEREO_LAYOUT}.mkv"
  else
    # Par défaut, le résultat est déposé au même niveau que la source (fichier .mkv ou dossier BDMV).
    FINAL_MKV="$(dirname "$SOURCE_PATH")/${SOURCE_BASENAME}.${STEREO_LAYOUT}.mkv"
  fi
}

print_settings() {
  if [[ "$ENCODER" == "x264" ]]; then
    echo "Using: layout=$STEREO_LAYOUT size=$SBS_MODE encoder=x264 preset=$X264_PRESET crf=$X264_CRF extra=\"$X264_EXTRA_OPTS\""
  else
    echo "Using: layout=$STEREO_LAYOUT size=$SBS_MODE encoder=vaapi qp=$VAAPI_QP extra=\"$VAAPI_EXTRA_OPTS\""
  fi
}

# stdin : lignes id|codec|lang|desc ; ne garde que les pistes ayant au plus
# AUDIO_MAX_CHANNELS canaux (0 = pas de limite). "5.1" = 6 canaux, "7.1" = 8.
# Une piste dont le nombre de canaux est inconnu est conservée.
filter_channels() {
  if [[ "$AUDIO_MAX_CHANNELS" -le 0 ]]; then cat; return 0; fi
  awk -F'|' -v max="$AUDIO_MAX_CHANNELS" '
    {
      n = -1
      if (match($0, /Channels:[ \t]*[0-9]+(\.[0-9]+)?/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/Channels:[ \t]*/, "", s)
        split(s, p, ".")
        n = p[1] + p[2]
      }
      if (n < 0 || n <= max) print
    }'
}

# stdin : lignes id|codec|lang|desc ; filtre selon --lang (ex: fra,eng)
filter_lang() {
  if [[ -z "$LANG_FILTER" ]]; then cat; return 0; fi
  awk -F'|' -v langs=",${LANG_FILTER}," 'index(langs, "," $3 ",")'
}

pick_encode_settings() {
  if [[ "$SILENT" != "true" && "$NO_SETTINGS_PROMPT" != "true" ]]; then
    local choice
    choice="$(printf '%s\n' sbs tab | "$FZF_BIN" --header="Layout (current: $STEREO_LAYOUT)" --height='~20%' --border --layout=reverse)" || true
    if [[ -n "$choice" ]]; then STEREO_LAYOUT="$choice"; fi

    choice="$(printf '%s\n' full half | "$FZF_BIN" --header="Size (current: $SBS_MODE)" --height='~20%' --border --layout=reverse)" || true
    if [[ -n "$choice" ]]; then SBS_MODE="$choice"; fi

    choice="$(printf '%s\n' x264 vaapi | "$FZF_BIN" --header="Encoder (current: $ENCODER)" --height='~20%' --border --layout=reverse)" || true
    if [[ -n "$choice" ]]; then ENCODER="$choice"; fi

    if [[ "$ENCODER" == "x264" ]]; then
      choice="$(printf '%s\n' ultrafast superfast veryfast faster fast medium slow slower veryslow placebo \
        | "$FZF_BIN" --header="x264 preset (current: $X264_PRESET)" --height='~40%' --border --layout=reverse)" || true
      if [[ -n "$choice" ]]; then X264_PRESET="$choice"; fi
      read -rp "x264 CRF [$X264_CRF]: " choice
      if [[ -n "$choice" ]]; then X264_CRF="$choice"; fi
      read -rp "Extra x264 options ('-' pour vider) [$X264_EXTRA_OPTS]: " choice
      if [[ "$choice" == "-" ]]; then X264_EXTRA_OPTS=""; elif [[ -n "$choice" ]]; then X264_EXTRA_OPTS="$choice"; fi
    else
      read -rp "VAAPI QP [$VAAPI_QP]: " choice
      if [[ -n "$choice" ]]; then VAAPI_QP="$choice"; fi
      read -rp "Extra ffmpeg options ('-' pour vider) [$VAAPI_EXTRA_OPTS]: " choice
      if [[ "$choice" == "-" ]]; then VAAPI_EXTRA_OPTS=""; elif [[ -n "$choice" ]]; then VAAPI_EXTRA_OPTS="$choice"; fi
    fi
  fi

  validate_settings
  set_final_name
  print_settings
}

usage() {
  cat <<EOF
Usage: $0 [options] <BDMV-dir-or-.mkv-file>

Options:
  -s, --silent          Mode non interactif : playlist la plus longue, toutes les
                        pistes audio/sous-titres (filtrables avec --lang), réglages
                        issus de la config et de la ligne de commande
  --lang LIST           Filtre les pistes audio/sous-titres, ex: fra,eng
  --config PATH         Config file to use (default: $CONFIG_FILE)
  --workdir PATH        Dossier où créer le répertoire de travail temporaire
                        (défaut : à côté de la source), supprimé après un succès.
  --output FICHIER      Chemin exact du fichier final (défaut : à côté de la source,
                        <nom>.<layout>.mkv)
  --output-stem CHEMIN  Chemin sans extension : le final sera <CHEMIN>.<layout>.mkv
  --title "TITRE"       Titre Matroska du fichier final (défaut : nom de la source)
  --no-settings-prompt  Ne pose pas les questions de réglages d'encodage (pistes : oui)
  --layout sbs|tab      Side-by-side ou top-and-bottom (--tab = raccourci)
  --sbs full|half       Résolution pleine ou réduite de moitié (par oeil)
  --encoder x264|vaapi  Encoder to use
  --preset NAME         x264 preset (ignored for vaapi)
  --crf N               x264 CRF
  --qp N                VAAPI QP
  --x264-opts "STRING"  Extra x264 options, appended verbatim
  --vaapi-opts "STRING" Extra ffmpeg (h264_vaapi) options, appended verbatim
  --keep-intermediates  Conserve le répertoire de travail après un succès
  --no-inhibit          Ne pas empêcher la mise en veille pendant le traitement
  --max-channels N      Ne garde que les pistes audio à N canaux au plus (2 = stéréo ;
                        5.1 = 6, 7.1/Atmos = 8 ; 0 = pas de limite)
  -h, --help            Show this help
EOF
}

parse_args() {
  SOURCE_PATH=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--silent) SILENT="true"; shift ;;
      --lang) LANG_FILTER="$2"; shift 2 ;;
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --workdir|--outdir) WORKDIR_ROOT="$2"; shift 2 ;;
      --layout) CLI_OVERRIDES+=("STEREO_LAYOUT=$2"); shift 2 ;;
      --tab) CLI_OVERRIDES+=("STEREO_LAYOUT=tab"); shift ;;
      --sbs) CLI_OVERRIDES+=("SBS_MODE=$2"); shift 2 ;;
      --encoder) CLI_OVERRIDES+=("ENCODER=$2"); shift 2 ;;
      --preset) CLI_OVERRIDES+=("X264_PRESET=$2"); shift 2 ;;
      --crf) CLI_OVERRIDES+=("X264_CRF=$2"); shift 2 ;;
      --qp) CLI_OVERRIDES+=("VAAPI_QP=$2"); shift 2 ;;
      --x264-opts) CLI_OVERRIDES+=("X264_EXTRA_OPTS=$2"); shift 2 ;;
      --vaapi-opts) CLI_OVERRIDES+=("VAAPI_EXTRA_OPTS=$2"); shift 2 ;;
      --keep-intermediates) CLI_OVERRIDES+=("KEEP_INTERMEDIATES=true"); shift ;;
      --no-inhibit) CLI_OVERRIDES+=("INHIBIT_SLEEP=false"); shift ;;
      --max-channels) CLI_OVERRIDES+=("AUDIO_MAX_CHANNELS=$2"); shift 2 ;;
      --output) OUTPUT_FILE="$2"; shift 2 ;;
      --output-stem) OUTPUT_STEM="$2"; shift 2 ;;
      --title) TITLE_OVERRIDE="$2"; shift 2 ;;
      --no-settings-prompt) NO_SETTINGS_PROMPT=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "Error: unknown option $1 (see --help)" >&2; exit 1 ;;
      *) SOURCE_PATH="$1"; shift ;;
    esac
  done
  if [[ -z "$SOURCE_PATH" ]]; then usage; exit 1; fi
}

resolve_source() {
  SOURCE_PATH="$(realpath "$SOURCE_PATH")"
  if [[ -d "$SOURCE_PATH" && -d "$SOURCE_PATH/BDMV/PLAYLIST" ]]; then
    SOURCE_TYPE="bdmv"
    SOURCE_BASENAME="$(basename "$SOURCE_PATH")"
  elif [[ -f "$SOURCE_PATH" && "$SOURCE_PATH" == *.mkv ]]; then
    SOURCE_TYPE="mkv"
    SOURCE_BASENAME="$(basename "${SOURCE_PATH%.mkv}")"
  else
    echo "Error: '$SOURCE_PATH' is neither a BDMV directory (with BDMV/PLAYLIST) nor a .mkv file" >&2
    exit 1
  fi

  # Dossier de travail DÉDIÉ (supprimé en fin de traitement) : on ne le crée qu'après les choix.
  WORKDIR="${WORKDIR_ROOT:-$(dirname "$SOURCE_PATH")}/${SOURCE_BASENAME}.encbd3d"

  set_final_name
}

list_playlists() {
  local mpls
  for mpls in "$SOURCE_PATH"/BDMV/PLAYLIST/*.mpls; do
    local info duration ssif
    info="$("$TSMUXER_BIN" "$mpls" 2>&1)"
    duration="$(grep -oP 'Duration:\s*\K[0-9:]+' <<<"$info" | head -1)"
    ssif="no"
    if grep -qi '\.ssif' <<<"$info"; then ssif="yes"; fi
    if [[ -n "$duration" ]]; then printf '%s|%s|%s\n' "$mpls" "$duration" "$ssif"; fi
  done
}

pick_playlist() {
  local candidates
  candidates="$(list_playlists | awk -F'|' '$3=="yes"')"
  if [[ -z "$candidates" ]]; then
    echo "Error: no .mpls with an .ssif reference found under $SOURCE_PATH/BDMV/PLAYLIST" >&2
    exit 1
  fi

  local min_seconds=$((MIN_PLAYLIST_MINUTES * 60))
  local sorted
  sorted="$(while IFS='|' read -r path duration ssif; do
    printf '%s|%s|%s\n' "$(duration_to_seconds "$duration")" "$path" "$duration"
  done <<<"$candidates" | awk -F'|' -v min="$min_seconds" '$1+0 >= min' | sort -t'|' -k1,1 -rn)"

  if [[ -z "$sorted" ]]; then
    echo "Error: no .ssif playlist under $SOURCE_PATH/BDMV/PLAYLIST is >=${MIN_PLAYLIST_MINUTES} minutes long." >&2
    echo "Lower MIN_PLAYLIST_MINUTES in $CONFIG_FILE if the real feature is shorter than that." >&2
    exit 1
  fi

  local count picked
  count="$(wc -l <<<"$sorted")"
  if [[ "$count" -eq 1 || "$SILENT" == "true" ]]; then
    picked="$(head -n1 <<<"$sorted")"    # trié par durée décroissante
    if [[ "$count" -gt 1 ]]; then
      echo "Silent: playlist la plus longue retenue parmi $count candidates."
    fi
  else
    picked="$(awk -F'|' '{printf "%s|%s|%s\n", $2, $3, $1}' <<<"$sorted" \
      | "$FZF_BIN" --delimiter='|' --with-nth=1,2 \
         --header='Select the main-feature playlist' \
         --height='~40%' --border --layout=reverse)"
    picked="$(awk -F'|' '{printf "%s|%s|%s\n", $3, $1, $2}' <<<"$picked")"
  fi

  PLAYLIST_PATH="$(cut -d'|' -f2 <<<"$picked")"
  echo "Selected playlist: $PLAYLIST_PATH ($(cut -d'|' -f3 <<<"$picked"))"
}

run_tsmuxer_scan() {
  TSMUXER_SCAN="$("$TSMUXER_BIN" "$1" 2>&1)"
}

scan_tracks() {
  awk '
    /^Track ID:/ { if (id != "") print id"|"codec"|"lang"|"desc; id=$0; sub(/^Track ID:[ \t]*/,"",id); codec=""; lang=""; desc="" }
    /^Stream ID:/ { codec=$0; sub(/^Stream ID:[ \t]*/,"",codec) }
    /^Stream lang:/ { lang=$0; sub(/^Stream lang:[ \t]*/,"",lang) }
    /^Stream info:/ { desc=$0; sub(/^Stream info:[ \t]*/,"",desc) }
    END { if (id != "") print id"|"codec"|"lang"|"desc }
  ' <<<"$TSMUXER_SCAN"
}

scan_chapter_marks() {
  awk '/^Marks:/ { sub(/^Marks:[ \t]*/,""); print }' <<<"$TSMUXER_SCAN" \
    | tr -s '[:space:]' '\n' | grep -v '^$' || true
}

build_chapters() {
  CHAPTERS_FILE=""
  # Source MKV (rip MakeMKV) : chapitres repris tels quels, au format simple (OGM).
  if [[ "$SOURCE_TYPE" == "mkv" ]]; then
    local mkvextract
    mkvextract="$(command -v "$MKVEXTRACT_BIN" 2>/dev/null || true)"
    if [[ -z "$mkvextract" ]]; then
      msg_warn "mkvextract introuvable : chapitres non repris."
      return 0
    fi
    CHAPTERS_FILE="$WORKDIR/chapters.txt"
    "$mkvextract" "$SOURCE_PATH" chapters -s "$CHAPTERS_FILE" >/dev/null 2>&1 || true
    if [[ ! -s "$CHAPTERS_FILE" ]]; then CHAPTERS_FILE=""; fi
    return 0
  fi

  local marks; marks="$(scan_chapter_marks)"
  if [[ -z "$marks" ]]; then return 0; fi

  CHAPTERS_FILE="$WORKDIR/chapters.txt"
  local n=0
  : > "$CHAPTERS_FILE"
  while IFS= read -r t; do
    n=$((n + 1))
    printf 'CHAPTER%02d=%s\n' "$n" "$t" >> "$CHAPTERS_FILE"
    printf 'CHAPTER%02dNAME=Chapter %02d\n' "$n" "$n" >> "$CHAPTERS_FILE"
  done <<<"$marks"
}

pick_video_track_ids() {
  local tracks="$1"
  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
    AVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/AVC/ {print $1; exit}' <<<"$tracks")"
    MVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/MVC/ {print $1; exit}' <<<"$tracks")"
    if [[ -z "$AVC_TRACK_ID" || -z "$MVC_TRACK_ID" ]]; then
      echo "Error: could not find both an AVC base view and an MVC dependent view in $PLAYLIST_PATH" >&2
      exit 1
    fi
  else
    AVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/(AVC|MVC)/ {print $1; exit}' <<<"$tracks")"
    MVC_TRACK_ID="$AVC_TRACK_ID"
    if [[ -z "$AVC_TRACK_ID" ]]; then
      echo "Error: could not find a combined AVC/MVC video track in $SOURCE_PATH" >&2
      exit 1
    fi
  fi
}

pick_audio_tracks() {
  local tracks="$1" lines=()
  if [[ "$SILENT" == "true" ]]; then
    SELECTED_AUDIO="$(awk -F'|' '$2 ~ /^A_/' <<<"$tracks" | filter_lang | filter_channels)"
    if [[ -z "$SELECTED_AUDIO" ]]; then echo "Warning: aucune piste audio retenue." >&2; fi
    return 0
  fi
  mapfile -t lines < <(awk -F'|' '$2 ~ /^A_/' <<<"$tracks" | filter_channels)
  if [[ "$AUDIO_MAX_CHANNELS" -gt 0 && ${#lines[@]} -eq 0 ]]; then
    echo "Warning: aucune piste audio avec au plus $AUDIO_MAX_CHANNELS canaux." >&2
  fi
  SELECTED_AUDIO="$(pick_many "Select audio track(s)" "${lines[@]}")" || true
}

pick_subtitle_tracks() {
  local tracks="$1" lines=()
  if [[ "$SILENT" == "true" ]]; then
    SELECTED_SUBS="$(awk -F'|' '$2 ~ /^S_/' <<<"$tracks" | filter_lang)"
    return 0
  fi
  mapfile -t lines < <(awk -F'|' '$2 ~ /^S_/' <<<"$tracks")
  SELECTED_SUBS="$(pick_many "Select subtitle track(s)" "${lines[@]}")" || true
}

meta_source_path() {
  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then echo "$PLAYLIST_PATH"; else echo "$SOURCE_PATH"; fi
}

build_demux_meta() {
  META_FILE="$WORKDIR/demux.meta"
  local src; src="$(meta_source_path)"

  {
    echo 'MUXOPT --demux --new-audio-pes --vbr'
    if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
      echo "V_MPEG4/ISO/AVC, \"$src\", track=$AVC_TRACK_ID"
      echo "V_MPEG4/ISO/MVC, \"$src\", track=$MVC_TRACK_ID"
    else
      echo "V_MPEG4/ISO/AVC, \"$src\", track=$AVC_TRACK_ID, subTrack=2"
      echo "V_MPEG4/ISO/MVC, \"$src\", track=$MVC_TRACK_ID, subTrack=1"
    fi

    if [[ -n "${SELECTED_AUDIO:-}" ]]; then
      while IFS='|' read -r id codec lang desc; do
        echo "$codec, \"$src\", track=$id, lang=$lang"
      done <<<"$SELECTED_AUDIO"
    fi

    if [[ -n "${SELECTED_SUBS:-}" ]]; then
      while IFS='|' read -r id codec lang desc; do
        echo "$codec, \"$src\", track=$id, lang=$lang"
      done <<<"$SELECTED_SUBS"
    fi
  } > "$META_FILE"
}

run_demux() {
  local avc_out mvc_out
  avc_out="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${AVC_TRACK_ID}*.264" 2>/dev/null | head -1)"
  mvc_out="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${MVC_TRACK_ID}*.mvc" 2>/dev/null | head -1)"

  if [[ -n "$avc_out" && -n "$mvc_out" && -s "$avc_out" && -s "$mvc_out" ]]; then
    echo "⏩ [INFO] Fichiers vidéo déjà démultiplexés trouvés, on ignore le demux."
    return 0
  fi

  echo "⚙️ [INFO] Démultiplexage avec tsMuxeR..."
  "$TSMUXER_BIN" "$META_FILE" "$WORKDIR"
}

find_demuxed_files() {
  BASE_264="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${AVC_TRACK_ID}*.264" | head -1)"
  DEP_MVC="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${MVC_TRACK_ID}*.mvc" | head -1)"
  if [[ -z "$BASE_264" || -z "$DEP_MVC" ]]; then
    echo "Error: couldn't locate demuxed .264/.mvc files in $WORKDIR - check tsMuxeR's actual output naming" >&2
    exit 1
  fi
}

build_vpy() {
  VPY_FILE="$WORKDIR/script.vpy"
  {
    echo "import vapoursynth as vs"
    echo "core = vs.core"
    echo "core.std.LoadPlugin(r\"$MVC_SOURCE_PLUGIN\")"
    echo "clip = core.mvc.Source(r\"$BASE_264\", dependent=r\"$DEP_MVC\", stack=\"sbs\")"
    # Le plugin produit toujours du SBS full. Pour le TaB ou le mode half,
    # on sépare les deux yeux, on redimensionne chacun, puis on ré-empile.
    if [[ "$STEREO_LAYOUT" != "sbs" || "$SBS_MODE" != "full" ]]; then
      echo "w = clip.width // 2"
      echo "left = core.std.Crop(clip, right=w)"
      echo "right = core.std.Crop(clip, left=w)"
      if [[ "$SBS_MODE" == "half" ]]; then
        if [[ "$STEREO_LAYOUT" == "sbs" ]]; then
          echo "left = core.resize.Bicubic(left, width=w//2, height=left.height)"
          echo "right = core.resize.Bicubic(right, width=w//2, height=right.height)"
        else
          echo "left = core.resize.Bicubic(left, width=w, height=left.height//2)"
          echo "right = core.resize.Bicubic(right, width=w, height=right.height//2)"
        fi
      fi
      if [[ "$STEREO_LAYOUT" == "sbs" ]]; then
        echo "clip = core.std.StackHorizontal([left, right])"
      else
        echo "clip = core.std.StackVertical([left, right])"
      fi
    fi
    echo "clip.set_output()"
  } > "$VPY_FILE"
}

probe_encoded_video() {
  local info; info="$("$VSPIPE_BIN" --info "$VPY_FILE" 2>&1)"
  ENC_WIDTH="$(grep -oP '^Width:\s*\K[0-9]+' <<<"$info")"
  ENC_HEIGHT="$(grep -oP '^Height:\s*\K[0-9]+' <<<"$info")"
  ENC_FPS_NUM="$(grep -oP '^FPS:\s*\K[0-9]+(?=/)' <<<"$info")"
  ENC_FPS_DEN="$(grep -oP '^FPS:\s*[0-9]+/\K[0-9]+' <<<"$info")"
}

run_encode() {
  # Le nom inclut layout et taille : changer de réglage ne réutilise pas un ancien encodage.
  ENCODED_FILE="$WORKDIR/encoded.${STEREO_LAYOUT}.${SBS_MODE}.264"
  local TMP_ENCODED="$WORKDIR/encoded.tmp.264"

  if [[ -s "$ENCODED_FILE" ]]; then
    echo "⏩ [INFO] Fichier encodé déjà présent ($ENCODED_FILE), on ignore l'encodage."
    return 0
  fi

  # x264 --frame-packing : 3 = side by side, 4 = top-bottom
  local frame_packing=3
  if [[ "$STEREO_LAYOUT" == "tab" ]]; then frame_packing=4; fi

  echo "⚙️ [INFO] Encodage vidéo en cours avec $ENCODER ($STEREO_LAYOUT, $SBS_MODE)..."
  if [[ "$ENCODER" == "vaapi" ]]; then
    "$VSPIPE_BIN" -c y4m "$VPY_FILE" - \
      | "$FFMPEG_BIN" -vaapi_device "$VAAPI_DEVICE" -f yuv4mpegpipe -i - \
          -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp "$VAAPI_QP" $VAAPI_EXTRA_OPTS \
          -f h264 -y "$TMP_ENCODED"
  else
    "$VSPIPE_BIN" -c y4m "$VPY_FILE" - \
      | "$X264_BIN" --demuxer y4m --frame-packing "$frame_packing" \
          --preset "$X264_PRESET" --crf "$X264_CRF" $X264_EXTRA_OPTS \
          -o "$TMP_ENCODED" -
  fi

  mv "$TMP_ENCODED" "$ENCODED_FILE"
}

build_mkvmerge_json() {
  MUX_JSON="$WORKDIR/mux_options.json"

  # Matroska StereoMode : 1 = side by side (gauche d'abord), 3 = top-bottom (gauche d'abord)
  local layout_label="SBS" stereo_id=1
  if [[ "$STEREO_LAYOUT" == "tab" ]]; then layout_label="TAB"; stereo_id=3; fi
  local size_label="Full"
  if [[ "$SBS_MODE" == "half" ]]; then size_label="Half"; fi
  local sbs_label="$size_label $layout_label"
  local encoder_label="x264 CRF $X264_CRF preset $X264_PRESET"
  if [[ "$ENCODER" == "vaapi" ]]; then encoder_label="h264_vaapi QP $VAAPI_QP"; fi

  local args=()
  args+=("--title" "${TITLE_OVERRIDE:-$SOURCE_BASENAME}")

  args+=("--track-name" "0:$sbs_label ($encoder_label)")
  args+=("--stereo-mode" "0:$stereo_id")
  args+=("--language" "0:und")
  if [[ -n "${ENC_WIDTH:-}" && -n "${ENC_HEIGHT:-}" ]]; then args+=("--aspect-ratio" "0:$ENC_WIDTH/$ENC_HEIGHT"); fi
  if [[ -n "${ENC_FPS_NUM:-}" && -n "${ENC_FPS_DEN:-}" ]]; then args+=("--default-duration" "0:${ENC_FPS_NUM}/${ENC_FPS_DEN}p"); fi
  args+=("--default-track" "0:yes")
  args+=("$ENCODED_FILE")

  local first=1
  if [[ -n "${SELECTED_AUDIO:-}" ]]; then
    while IFS='|' read -r id codec lang desc; do
      local f; f="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${id}*" ! -iname "*.264" ! -iname "*.mvc" | head -1)"
      if [[ -n "$f" ]]; then
        args+=("--track-name" "0:$desc" "--language" "0:$lang" \
               "--default-track" "0:$([[ $first -eq 1 ]] && echo yes || echo no)" \
               "--compression" "0:none" "$f")
        first=0
      fi
    done <<<"$SELECTED_AUDIO"
  fi

  first=1
  if [[ -n "${SELECTED_SUBS:-}" ]]; then
    while IFS='|' read -r id codec lang desc; do
      local f; f="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${id}*.sup" | head -1)"
      if [[ -n "$f" ]]; then
        args+=("--track-name" "0:$desc" "--language" "0:$lang" \
               "--default-track" "0:$([[ $first -eq 1 ]] && echo yes || echo no)" \
               "--forced-track" "0:no" "--compression" "0:none" "$f")
        first=0
      fi
    done <<<"$SELECTED_SUBS"
  fi

  if [[ -n "${CHAPTERS_FILE:-}" ]]; then args+=("--chapter-language" "und" "--chapters" "$CHAPTERS_FILE"); fi

  args+=("--engage" "no_cue_duration")
  args+=("--engage" "no_cue_relative_position")
  args+=("--disable-track-statistics-tags")
  MUX_OUTPUT="$WORKDIR/output.partial.mkv"
  args+=("-o" "$MUX_OUTPUT")

  {
    echo "["
    local i last=$((${#args[@]} - 1))
    for i in "${!args[@]}"; do
      printf '  "%s"%s\n' "$(json_escape "${args[$i]}")" "$([[ $i -lt $last ]] && echo ,)"
    done
    echo "]"
  } > "$MUX_JSON"
}

run_mux() {
  echo "⚙️ [INFO] Multiplexage final avec mkvmerge..."
  local rc=0
  "$MKVMERGE_BIN" "@$MUX_JSON" || rc=$?
  # mkvmerge : 0 = succès, 1 = succès avec avertissements, 2 = erreur.
  if [[ $rc -ge 2 || ! -s "$MUX_OUTPUT" ]]; then
    echo "❌ [ERREUR] mkvmerge a échoué (code $rc). Répertoire de travail conservé : $WORKDIR" >&2
    exit "$EXIT_ENCODE"
  fi
  if [[ $rc -eq 1 ]]; then echo "⚠️ [WARN] mkvmerge a signalé des avertissements (fichier produit)." >&2; fi
  mv -f -- "$MUX_OUTPUT" "$FINAL_MKV"
}

cleanup_workdir() {
  if [[ "$KEEP_INTERMEDIATES" == "true" ]]; then
    echo "📁 [INFO] Répertoire de travail conservé : $WORKDIR"
    return 0
  fi
  # Garde-fou : on ne supprime que notre propre répertoire dédié.
  case "$WORKDIR" in
    *.encbd3d) rm -rf -- "$WORKDIR" ;;
    *) echo "⚠️ [WARN] Répertoire de travail inattendu, non supprimé : $WORKDIR" >&2 ;;
  esac
}

exit_if_final_exists() {
  if [[ -s "$FINAL_MKV" ]]; then
    echo "✅ [INFO] Le fichier final existe déjà : $FINAL_MKV"
    echo "✅ [INFO] Aucun traitement nécessaire. Arrêt du script."
    exit 0
  fi
}

main() {
  parse_args "$@"
  load_config
  apply_cli_overrides
  validate_settings
  resolve_source

  exit_if_final_exists

  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
    pick_playlist
    run_tsmuxer_scan "$PLAYLIST_PATH"
  else
    run_tsmuxer_scan "$SOURCE_PATH"
  fi
  local tracks; tracks="$(scan_tracks)"

  pick_video_track_ids "$tracks"
  pick_audio_tracks "$tracks"
  pick_subtitle_tracks "$tracks"
  pick_encode_settings
  exit_if_final_exists      # le layout choisi peut avoir changé le nom de sortie
  mkdir -p "$WORKDIR"
  build_chapters

  if [[ "$INHIBIT_SLEEP" == "true" ]]; then start_inhibit "Encodage vidéo en cours (encbd3d)"; fi

  build_demux_meta
  run_demux
  find_demuxed_files
  build_vpy
  probe_encoded_video
  run_encode
  build_mkvmerge_json
  run_mux
  cleanup_workdir

  echo "🎉 [INFO] Terminé : $FINAL_MKV"
}

# Permet de « source »-r le fichier pour tester ses fonctions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi