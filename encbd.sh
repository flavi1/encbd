#!/usr/bin/env bash
# encbd.sh — transforme un disque en fichiers nommés :
#   Blu-ray 2D, DVD   → MKV encodé (x264 ou VAAPI)
#   Blu-ray 3D (MVC)  → MKV côte à côte / haut-bas, via encbd3d.sh
#   CD audio          → FLAC par piste (cyanrip)
#   SACD (image ISO)  → FLAC 24 bits, DSF ou WavPack DSD (sacd_extract)
#
# Usage : encbd.sh [options] <source> <destination>      (voir --help)
# Mettre DEBUG=1 dans l'environnement pour afficher chaque commande exécutée.

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
set -euo pipefail
trap 'echo -e "\n❌ [ERREUR] encbd.sh s'\''est arrêté à la ligne $LINENO.\nCommande défaillante : $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCBD_LIB_DIR="${ENCBD_LIB_DIR:-$SCRIPT_DIR/lib}"
# shellcheck source=lib/encbd-common.sh
source "$ENCBD_LIB_DIR/encbd-common.sh"

ENCBD_PYTHON="${ENCBD_PYTHON:-python3}"
ENCBD3D_SCRIPT="${ENCBD3D_SCRIPT:-$SCRIPT_DIR/encbd3d.sh}"

helper() { "$ENCBD_PYTHON" "$ENCBD_LIB_DIR/encbd-helper.py" "$@"; }

# ─── État ────────────────────────────────────────────────────────────────────
SOURCE_ARG=""; DEST_ARG=""
DRY_RUN=false
FORCED_TITLE=""; FORCED_YEAR=""; FORCED_PLAYLIST=""
WORKDIR_ROOT=""

SRC_KIND=""          # device | iso | dir | sacd-net
SOURCE_PATH=""       # chemin absolu de la source
DEVICE=""            # périphérique bloc (lecteur ou boucle)
MOUNT_DIR=""         # racine du disque monté
MAKEMKV_SRC=""       # dev:… | iso:… | file:…
DISC_TYPE=""         # bluray | uhd | dvd | cd | sacd
IS_3D="no"
PROTECTION="aucune détectée"
DISC_LABEL=""
WE_MOUNTED=false; MOUNTED_DEV=""; LOOP_DEV=""

BACKEND=""           # makemkv | libaacs
MAKEMKVCON=""
OUTPUT_3D=false
FALLBACK_2D=false

TITLES=""            # index \t secondes \t octets \t source \t nom (durée décroissante)
MAIN_IDX=""; MAIN_SECS=0; MAIN_BYTES=0; MAIN_SOURCE=""; MAIN_ORIGIN=""

NAME_TITLE=""; NAME_YEAR=""; NAME_ORIGIN=""; DISCDB_MAIN=""
DEST_IS_DIR=false; DEST_DIR=""; BASE_NAME=""; FINAL_PATH=""
WORKDIR=""; RIPPED_MKV=""
RUN_TMP=""

WARN_3D_MSG="ATTENTION : LE DISQUE EST EN 3D MAIS MAKEMKVCON EST INTROUVABLE. IL SERA ENCODÉ EN 2D !"

# ─── Aide et arguments ───────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage : $(basename "$0") [options] <source> <destination>

Source       : lecteur (/dev/sr0), image .iso, dossier contenant BDMV/ ou VIDEO_TS/,
               ou serveur sacd_extract (IP:PORT) pour un SACD.
Destination  : dossier existant → nom résolu automatiquement (NAME_TEMPLATE) ;
               sinon chemin du fichier (vidéo) ou du dossier d'album (audio), utilisé tel quel.

Options générales :
  -s, --silent            Aucune question : chaque choix suit une règle fixe
  --dry-run               Affiche la détection et le plan, puis s'arrête sans rien écrire
  --title "NOM"           Impose le nom (pas de résolution)      --year AAAA : impose l'année
  --playlist N            Impose le titre : playlist Blu-ray (800, 00800.mpls),
                          numéro de titre MakeMKV ou titre DVD
  --no-online             Ni TheDiscDB, ni TMDb (MusicBrainz désactivé pour les CD)
  --rip-backend auto|makemkv|libaacs
  --config FICHIER        Configuration (défaut : $CONFIG_FILE)
  --workdir DOSSIER       Où créer le dossier de travail (défaut : à côté du résultat)
  --keep-intermediates    Conserve le dossier de travail après un succès
  --no-inhibit            N'empêche pas la mise en veille

Pistes et encodage vidéo (transmis à encbd3d.sh pour la 3D) :
  --lang LISTE            Pistes audio/sous-titres à garder, ex : fra,eng
  --max-channels N        Canaux audio maximum (2 = stéréo, 0 = sans limite)
  --layout sbs|tab, --tab, --sbs full|half
  --encoder x264|vaapi, --preset NOM, --crf N, --qp N
  --x264-opts "…", --vaapi-opts "…"
  -h, --help              Cette aide

Codes de sortie : 0 succès · 1 usage · 2 prérequis/annulation · 3 source illisible
  4 non pris en charge (UHD illisible…) · 5 déchiffrement · 6 espace disque · 7 rip · 8 encodage
EOF
}

need_arg() { [[ $2 -ge 2 ]] || die_code "$EXIT_USAGE" "$1 attend un argument (voir --help)"; }

parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--silent) SILENT="true"; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --title) need_arg "$1" $#; FORCED_TITLE="$2"; shift 2 ;;
      --year) need_arg "$1" $#; FORCED_YEAR="$2"; shift 2 ;;
      --playlist) need_arg "$1" $#; FORCED_PLAYLIST="$2"; shift 2 ;;
      --no-online) CLI_OVERRIDES+=("ONLINE_LOOKUP=false"); shift ;;
      --rip-backend) need_arg "$1" $#; CLI_OVERRIDES+=("RIP_BACKEND=$2"); shift 2 ;;
      --config) need_arg "$1" $#; CONFIG_FILE="$2"; shift 2 ;;
      --workdir) need_arg "$1" $#; WORKDIR_ROOT="$2"; shift 2 ;;
      --keep-intermediates) CLI_OVERRIDES+=("KEEP_INTERMEDIATES=true"); shift ;;
      --no-inhibit) CLI_OVERRIDES+=("INHIBIT_SLEEP=false"); shift ;;
      --lang) need_arg "$1" $#; LANG_FILTER="$2"; shift 2 ;;
      --max-channels) need_arg "$1" $#; CLI_OVERRIDES+=("AUDIO_MAX_CHANNELS=$2"); shift 2 ;;
      --layout) need_arg "$1" $#; CLI_OVERRIDES+=("STEREO_LAYOUT=$2"); shift 2 ;;
      --tab) CLI_OVERRIDES+=("STEREO_LAYOUT=tab"); shift ;;
      --sbs) need_arg "$1" $#; CLI_OVERRIDES+=("SBS_MODE=$2"); shift 2 ;;
      --encoder) need_arg "$1" $#; CLI_OVERRIDES+=("ENCODER=$2"); shift 2 ;;
      --preset) need_arg "$1" $#; CLI_OVERRIDES+=("X264_PRESET=$2"); shift 2 ;;
      --crf) need_arg "$1" $#; CLI_OVERRIDES+=("X264_CRF=$2"); shift 2 ;;
      --qp) need_arg "$1" $#; CLI_OVERRIDES+=("VAAPI_QP=$2"); shift 2 ;;
      --x264-opts) need_arg "$1" $#; CLI_OVERRIDES+=("X264_EXTRA_OPTS=$2"); shift 2 ;;
      --vaapi-opts) need_arg "$1" $#; CLI_OVERRIDES+=("VAAPI_EXTRA_OPTS=$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; positional+=("$@"); break ;;
      -*) die_code "$EXIT_USAGE" "Option inconnue : $1 (voir --help)" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  if [[ ${#positional[@]} -ne 2 ]]; then usage >&2; exit "$EXIT_USAGE"; fi
  SOURCE_ARG="${positional[0]}"
  DEST_ARG="${positional[1]}"
}

is_silent() { [[ "$SILENT" == "true" ]]; }
is_online() { [[ "$ONLINE_LOOKUP" == "true" ]]; }

require_tool() {   # <commande> <usage>
  command -v "$1" >/dev/null 2>&1 || die_code "$EXIT_PREREQ" "Outil manquant : $1 ($2)"
}

# Choix oui/non en mode interactif ; renvoie 0 pour oui.
confirm() {   # <question>
  local ans=""
  read -rp "$1 [o/N] " ans || true
  [[ "$ans" =~ ^[oOyY] ]]
}

# ─── Fichiers temporaires de la session ─────────────────────────────────────
setup_run_tmp() {
  local base="${XDG_CACHE_HOME:-$HOME/.cache}/encbd"
  mkdir -p "$base"
  RUN_TMP="$(mktemp -d "$base/run.XXXXXX")"
  encbd_add_exit_hook cleanup_run_tmp
}

cleanup_run_tmp() {
  if [[ -z "$RUN_TMP" || ! -d "$RUN_TMP" ]]; then return 0; fi
  if [[ "$ENCBD_EXIT_STATUS" -eq 0 ]]; then
    rm -rf -- "$RUN_TMP"
  else
    echo "📁 [INFO] Journaux conservés : $RUN_TMP" >&2
  fi
}

# ─── Sonde de la source ──────────────────────────────────────────────────────
# Chemin insensible à la casse sous <base> ; vide si absent.
ci_path() {   # <base> <a/b/c>
  local cur="$1" part parts=()
  IFS=/ read -ra parts <<<"$2"
  for part in "${parts[@]}"; do
    cur="$(find "$cur" -mindepth 1 -maxdepth 1 -iname "$part" -print -quit 2>/dev/null || true)"
    if [[ -z "$cur" ]]; then return 0; fi
  done
  printf '%s' "$cur"
}

udev_prop() {   # <propriétés> <clé>
  sed -n "s/^$2=//p" <<<"$1" | head -n1
}

# Vrai si le lecteur contient un CD audio (y compris CD mixte « Enhanced CD »).
probe_optical_media() {   # <périphérique>
  local props audio
  if ! command -v udevadm >/dev/null 2>&1; then return 1; fi
  props="$(host_run udevadm info --query=property --name="$1" 2>/dev/null || true)"
  if [[ -z "$props" ]]; then return 1; fi
  if [[ "$(udev_prop "$props" ID_CDROM)" == "1" && -z "$(udev_prop "$props" ID_CDROM_MEDIA)" ]]; then
    die_code "$EXIT_SOURCE" "Aucun disque dans $1."
  fi
  audio="$(udev_prop "$props" ID_CDROM_MEDIA_TRACK_COUNT_AUDIO)"
  [[ "${audio:-0}" =~ ^[0-9]+$ && "${audio:-0}" -gt 0 ]]
}

unmount_source() {
  if [[ "$WE_MOUNTED" == true && -n "$MOUNTED_DEV" ]]; then
    host_run udisksctl unmount -b "$MOUNTED_DEV" >/dev/null 2>&1 || true
    WE_MOUNTED=false
  fi
  if [[ -n "$LOOP_DEV" ]]; then
    host_run udisksctl loop-delete -b "$LOOP_DEV" >/dev/null 2>&1 || true
    LOOP_DEV=""
  fi
}

find_mountpoint() {   # <périphérique>
  host_run findmnt -n -o TARGET --source "$1" 2>/dev/null | head -n1 || true
}

mount_device() {   # <périphérique>
  local dev="$1" target
  target="$(find_mountpoint "$dev")"
  if [[ -z "$target" ]]; then
    if ! command -v udisksctl >/dev/null 2>&1; then
      die_code "$EXIT_SOURCE" "$dev n'est pas monté et udisksctl est absent : montez le disque, ou passez son dossier en source."
    fi
    if ! host_run udisksctl mount -b "$dev" -o ro >/dev/null 2>&1; then
      die_code "$EXIT_SOURCE" "Montage de $dev impossible (disque absent, illisible, ou SACD non hybride ?)."
    fi
    WE_MOUNTED=true
    MOUNTED_DEV="$dev"
    target="$(find_mountpoint "$dev")"
  fi
  if [[ -z "$target" ]]; then die_code "$EXIT_SOURCE" "Point de montage de $dev introuvable."; fi
  MOUNT_DIR="$target"
  DISC_LABEL="$(host_run blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
  if [[ -z "$DISC_LABEL" ]]; then
    DISC_LABEL="$(host_run findmnt -n -o LABEL --source "$dev" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$DISC_LABEL" ]]; then DISC_LABEL="$(basename "$target")"; fi
}

setup_loop() {   # <image.iso>
  if ! command -v udisksctl >/dev/null 2>&1; then
    die_code "$EXIT_SOURCE" "udisksctl est nécessaire pour lire une image ISO (ou montez-la et passez le dossier)."
  fi
  LOOP_DEV="$(host_run udisksctl loop-setup -r -f "$1" 2>/dev/null | grep -o '/dev/loop[0-9]*' | head -n1 || true)"
  if [[ -z "$LOOP_DEV" ]]; then die_code "$EXIT_SOURCE" "Impossible d'attacher l'image $1 (udisksctl loop-setup)."; fi
  sleep 1   # laisse udisks monter automatiquement le périphérique boucle, le cas échéant
}

detect_video_disc() {
  local ver
  if [[ -n "$(ci_path "$MOUNT_DIR" BDMV)" ]]; then
    ver="$(helper index-version "$MOUNT_DIR" 2>/dev/null || true)"
    if [[ "$ver" == "0300" ]]; then DISC_TYPE="uhd"; else DISC_TYPE="bluray"; fi
    if [[ -n "$(ci_path "$MOUNT_DIR" BDMV/STREAM/SSIF)" ]]; then IS_3D="yes"; fi
    local prot=()
    if [[ -n "$(ci_path "$MOUNT_DIR" AACS)" ]]; then prot+=("AACS"); fi
    if [[ -n "$(ci_path "$MOUNT_DIR" BDSVM)" ]]; then prot+=("BD+"); fi
    if [[ ${#prot[@]} -gt 0 ]]; then PROTECTION="${prot[*]}"; fi
  elif [[ -n "$(ci_path "$MOUNT_DIR" VIDEO_TS)" ]]; then
    DISC_TYPE="dvd"
    PROTECTION="CSS possible (géré par le moteur)"
  else
    die_code "$EXIT_UNSUPPORTED" "Ni BDMV/ ni VIDEO_TS/ dans $MOUNT_DIR : disque non reconnu."
  fi
}

probe_source() {
  local src="$SOURCE_ARG"
  if [[ ! -e "$src" && "$src" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
    SRC_KIND="sacd-net"; DISC_TYPE="sacd"; SOURCE_PATH="$src"
    return 0
  fi
  if [[ ! -e "$src" ]]; then die_code "$EXIT_SOURCE" "Source introuvable : $src"; fi
  SOURCE_PATH="$(realpath "$src")"

  if [[ -b "$SOURCE_PATH" ]]; then
    SRC_KIND="device"; DEVICE="$SOURCE_PATH"; MAKEMKV_SRC="dev:$SOURCE_PATH"
    if probe_optical_media "$DEVICE"; then
      DISC_TYPE="cd"
      DISC_LABEL="CD audio"
      return 0
    fi
    encbd_add_exit_hook unmount_source
    mount_device "$DEVICE"
  elif [[ -f "$SOURCE_PATH" ]]; then
    if helper is-sacd-iso "$SOURCE_PATH"; then
      SRC_KIND="iso"; DISC_TYPE="sacd"
      DISC_LABEL="$(basename "${SOURCE_PATH%.*}")"
      return 0
    fi
    case "${SOURCE_PATH,,}" in
      *.iso) ;;
      *) die_code "$EXIT_SOURCE" "Fichier non reconnu (image .iso attendue) : $SOURCE_PATH" ;;
    esac
    SRC_KIND="iso"; MAKEMKV_SRC="iso:$SOURCE_PATH"
    encbd_add_exit_hook unmount_source
    setup_loop "$SOURCE_PATH"
    mount_device "$LOOP_DEV"
    DISC_LABEL="${DISC_LABEL:-$(basename "${SOURCE_PATH%.*}")}"
  elif [[ -d "$SOURCE_PATH" ]]; then
    local base; base="$(basename "$SOURCE_PATH")"
    if [[ "${base,,}" == "bdmv" || "${base,,}" == "video_ts" ]]; then SOURCE_PATH="$(dirname "$SOURCE_PATH")"; fi
    SRC_KIND="dir"; MOUNT_DIR="$SOURCE_PATH"; MAKEMKV_SRC="file:$SOURCE_PATH"
    DISC_LABEL="$(basename "$SOURCE_PATH")"
  else
    die_code "$EXIT_SOURCE" "Source non prise en charge : $SOURCE_PATH"
  fi
  detect_video_disc
}

disc_type_label() {
  case "$DISC_TYPE" in
    bluray) if [[ "$IS_3D" == yes ]]; then echo "Blu-ray 3D (MVC)"; else echo "Blu-ray"; fi ;;
    uhd) echo "Blu-ray UHD (4K)" ;;
    dvd) echo "DVD" ;;
    cd) echo "CD audio" ;;
    sacd) echo "SACD" ;;
    *) echo "inconnu" ;;
  esac
}

# ─── Moteur de déchiffrement ─────────────────────────────────────────────────
ffmpeg_has() {   # <protocols|demuxers|filters> <nom>
  local list
  list="$("$FFMPEG_BIN" -hide_banner "-$1" 2>/dev/null || true)"
  grep -qw -- "$2" <<<"$list"
}

keydb_path() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/aacs/KEYDB.cfg"; }

choose_backend() {
  MAKEMKVCON="$(find_tool "$MAKEMKVCON_BIN" makemkvcon "")"
  if [[ -n "$MAKEMKVCON" && ! -x "$MAKEMKVCON" ]] && ! command -v "$MAKEMKVCON" >/dev/null 2>&1; then MAKEMKVCON=""; fi

  case "$RIP_BACKEND" in
    auto) if [[ -n "$MAKEMKVCON" ]]; then BACKEND="makemkv"; else BACKEND="libaacs"; fi ;;
    makemkv)
      if [[ -z "$MAKEMKVCON" ]]; then die_code "$EXIT_PREREQ" "makemkvcon introuvable (RIP_BACKEND=makemkv). Installez MakeMKV."; fi
      BACKEND="makemkv" ;;
    libaacs) BACKEND="libaacs" ;;
    *) die_code "$EXIT_USAGE" "RIP_BACKEND : auto, makemkv ou libaacs attendu (reçu '$RIP_BACKEND')" ;;
  esac

  if [[ "$DISC_TYPE" == "uhd" && "$BACKEND" == "libaacs" ]]; then
    die_code "$EXIT_UNSUPPORTED" "Disque UHD : libaacs ne gère pas AACS 2.0. Installez MakeMKV (lecteur compatible LibreDrive requis)."
  fi

  if [[ "$IS_3D" == "yes" ]]; then
    if [[ "$BACKEND" == "makemkv" ]]; then
      OUTPUT_3D=true
    else
      FALLBACK_2D=true
    fi
  fi

  if [[ "$BACKEND" == "libaacs" ]]; then
    local problem=""
    if [[ "$DISC_TYPE" == "dvd" ]]; then
      ffmpeg_has demuxers dvdvideo || problem="ffmpeg n'a pas le démuxeur dvdvideo (ffmpeg ≥ 7 avec libdvdnav/libdvdread requis)"
    else
      ffmpeg_has protocols bluray || problem="ffmpeg n'a pas le protocole bluray (libbluray)"
      if [[ "$PROTECTION" == *AACS* && ! -f "$(keydb_path)" ]]; then
        msg_warn "Disque AACS et $(keydb_path) absent : le déchiffrement échouera sans MakeMKV."
      fi
      if [[ "$PROTECTION" == *BD+* ]]; then
        msg_warn "Protection BD+ détectée : libbdplus la gère rarement ; MakeMKV est recommandé."
      fi
    fi
    if [[ -n "$problem" ]]; then
      if [[ "$DRY_RUN" == true ]]; then msg_warn "$problem"; else die_code "$EXIT_PREREQ" "$problem. Installez MakeMKV ou un ffmpeg complet."; fi
    fi
  fi
}

announce_2d_fallback() {
  if [[ "$FALLBACK_2D" != true ]]; then return 0; fi
  echo >&2
  echo "⚠️  $WARN_3D_MSG" >&2
  echo >&2
  if ! is_silent && [[ "$DRY_RUN" != true ]]; then
    confirm "Continuer en 2D ?" || die_code "$EXIT_PREREQ" "Annulé. Installez MakeMKV pour encoder ce disque en 3D."
  fi
}

# ─── MakeMKV ─────────────────────────────────────────────────────────────────
makemkv_key_hint() {
  local conf="$HOME/.MakeMKV/settings.conf"
  if [[ ! -f "$conf" ]] || ! grep -q '^[[:space:]]*app_Key' "$conf"; then
    echo "Aucune clé dans $conf (ligne app_Key = \"T-…\")."
  else
    echo "Mettez à jour la ligne app_Key de $conf (clé bêta publiée sur le forum MakeMKV, ou clé achetée)."
  fi
}

# Arrête le script si le journal makemkvcon signale un problème de clé ou de lecture.
check_makemkv_log() {   # <journal> <code makemkvcon>
  local log="$1" rc="$2" msgs
  msgs="$(grep '^MSG:' "$log" 2>/dev/null || true)"
  if grep -qiE 'expired|too old|registration|evaluation period|invalid.*key|key.*invalid|beta key' <<<"$msgs"; then
    die_code "$EXIT_DECRYPT" "MakeMKV : clé absente ou expirée. $(makemkv_key_hint) Journal : $log"
  fi
  if [[ "$rc" -ne 0 ]] || grep -qiE 'failed to open disc|can.t open|no disc' <<<"$msgs"; then
    if [[ "$DISC_TYPE" == "uhd" ]]; then
      die_code "$EXIT_UNSUPPORTED" "MakeMKV ne parvient pas à lire ce disque UHD (lecteur compatible LibreDrive requis). Journal : $log"
    fi
    if grep -qiE 'failed to open disc|can.t open|no disc' <<<"$msgs"; then
      die_code "$EXIT_SOURCE" "MakeMKV ne parvient pas à ouvrir le disque. Journal : $log"
    fi
  fi
}

makemkv_list_titles() {
  local log="$RUN_TMP/makemkv-info.log" rc=0
  msg_step "Analyse du disque avec MakeMKV (jusqu'à une minute)..."
  host_run "$MAKEMKVCON" -r --minlength="$MIN_SECONDS" info "$MAKEMKV_SRC" >"$log" 2>&1 || rc=$?
  check_makemkv_log "$log" "$rc"
  TITLES="$(helper makemkv-titles "$log" || true)"
  if [[ -z "$TITLES" ]]; then
    if [[ "$DISC_TYPE" == "uhd" ]]; then
      die_code "$EXIT_UNSUPPORTED" "MakeMKV ne liste aucun titre sur ce disque UHD. Journal : $log"
    fi
    die_code "$EXIT_UNSUPPORTED" "MakeMKV ne trouve aucun titre d'au moins $MIN_PLAYLIST_MINUTES min (MIN_PLAYLIST_MINUTES). Journal : $log"
  fi
}

# ─── Liste des titres sans MakeMKV ───────────────────────────────────────────
libaacs_list_titles() {
  local rows
  if [[ "$DISC_TYPE" == "dvd" ]]; then
    local t out dur secs lines=()
    msg_step "Lecture des titres du DVD..."
    for (( t = 1; t <= 99; t++ )); do
      out="$("$FFMPEG_BIN" -hide_banner -nostdin -f dvdvideo -title "$t" -i "$SOURCE_PATH" 2>&1 || true)"
      dur="$(grep -oE 'Duration: [0-9]+:[0-9]+:[0-9]+' <<<"$out" | head -n1 | awk '{print $2}' || true)"
      if [[ -z "$dur" ]]; then break; fi
      secs="$(duration_to_seconds "$dur")"
      if [[ "$secs" -ge "$MIN_SECONDS" ]]; then
        lines+=("$(printf '%s\t%s\t%s\t%s\t%s' "$t" "$secs" $(( secs * 1250000 )) "title $t" "Titre $t")")
      fi
    done
    if [[ ${#lines[@]} -gt 0 ]]; then
      TITLES="$(printf '%s\n' "${lines[@]}" | sort -t$'\t' -k2,2nr)"
    fi
  else
    rows="$(helper mpls-list "$MOUNT_DIR" "$MIN_SECONDS" || true)"
    TITLES="$(awk -F'\t' -v OFS='\t' '{ n = $1; sub(/\.[mM][pP][lL][sS]$/, "", n); print n + 0, $2, $3, $1, ($4 == "yes" ? "3D" : "") }' <<<"$rows")"
    TITLES="$(sed '/^$/d' <<<"$TITLES")"
  fi
  if [[ -z "$TITLES" ]]; then
    die_code "$EXIT_UNSUPPORTED" "Aucun titre d'au moins $MIN_PLAYLIST_MINUTES min trouvé (MIN_PLAYLIST_MINUTES)."
  fi
}

list_titles() {
  if [[ "$BACKEND" == "makemkv" ]]; then makemkv_list_titles; else libaacs_list_titles; fi
}

# ─── Identification du nom ───────────────────────────────────────────────────
tmdb_attribution() {
  echo "    (données TMDb — This product uses the TMDB API but is not endorsed or certified by TMDB.)"
}

identify_name() {
  local r t y m kind
  if [[ -n "$FORCED_TITLE" ]]; then
    NAME_TITLE="$FORCED_TITLE"; NAME_YEAR="$FORCED_YEAR"; NAME_ORIGIN="option --title"
    return 0
  fi

  # 1. TheDiscDB : titre, année et playlist du film
  if is_online && [[ -n "$MOUNT_DIR" ]]; then
    kind="bluray"; if [[ "$DISC_TYPE" == "dvd" ]]; then kind="dvd"; fi
    msg_step "Recherche du disque dans TheDiscDB..."
    r="$(helper discdb "$MOUNT_DIR" "$kind" 2>/dev/null || true)"
    if [[ -n "$r" ]]; then
      IFS=$'\t' read -r t y m <<<"$r"
      if [[ -n "$t" ]]; then
        NAME_TITLE="$t"; NAME_YEAR="$y"; DISCDB_MAIN="$m"; NAME_ORIGIN="TheDiscDB"
      fi
    fi
  fi

  # 2. Métadonnées de l'éditeur (bdmt_*.xml)
  if [[ -z "$NAME_TITLE" && -n "$MOUNT_DIR" ]]; then
    t="$(helper bdmt "$MOUNT_DIR" 2>/dev/null || true)"
    if [[ -n "$t" ]]; then NAME_TITLE="$t"; NAME_ORIGIN="métadonnées du disque (bdmt)"; fi
  fi

  # 3. Label du volume, nettoyé
  if [[ -z "$NAME_TITLE" ]]; then
    t="$(helper clean-label "$DISC_LABEL" 2>/dev/null || true)"
    if [[ -n "$t" ]]; then NAME_TITLE="$t"; NAME_ORIGIN="label du volume ($DISC_LABEL)"; fi
  fi
  if [[ -z "$NAME_TITLE" ]]; then NAME_TITLE="Sans titre"; NAME_ORIGIN="défaut"; fi

  # 4. TMDb : titre localisé et année
  if is_online && [[ -n "$TMDB_API_KEY" && "$NAME_ORIGIN" != "TheDiscDB" ]]; then
    tmdb_refine
  fi

  # 5. Saisie manuelle
  if ! is_silent && [[ "$DRY_RUN" != true ]]; then
    read -e -rp "Nom du film : " -i "$NAME_TITLE" t || true
    if [[ -n "$t" && "$t" != "$NAME_TITLE" ]]; then NAME_TITLE="$t"; NAME_ORIGIN="saisie"; fi
    read -e -rp "Année (vide si inconnue) : " -i "$NAME_YEAR" y || true
    NAME_YEAR="$y"
  fi
  if [[ -n "$FORCED_YEAR" ]]; then NAME_YEAR="$FORCED_YEAR"; fi
}

tmdb_refine() {
  local results count line t y pick choices=() exact=""
  results="$(helper tmdb "$NAME_TITLE" "$TMDB_API_KEY" "$TMDB_LANGUAGE" 2>/dev/null || true)"
  if [[ -z "$results" ]]; then return 0; fi
  count="$(wc -l <<<"$results")"

  if is_silent || [[ "$DRY_RUN" == true ]]; then
    while IFS=$'\t' read -r t y _; do
      if [[ "${t,,}" == "${NAME_TITLE,,}" ]]; then exact="$t"$'\t'"$y"; break; fi
    done <<<"$results"
    if [[ -n "$exact" ]]; then line="$exact"
    elif [[ "$count" -eq 1 ]]; then line="$results"
    else return 0
    fi
    IFS=$'\t' read -r t y _ <<<"$line"
    NAME_TITLE="$t"; NAME_YEAR="$y"; NAME_ORIGIN="$NAME_ORIGIN + TMDb"
    tmdb_attribution
    return 0
  fi

  while IFS=$'\t' read -r t y _; do
    choices+=("$t${y:+ ($y)}"$'\t'"$t"$'\t'"$y")
  done <<<"$results"
  pick="$(printf '%s\n' "(garder « $NAME_TITLE »)"$'\t'"$NAME_TITLE"$'\t'"$NAME_YEAR" "${choices[@]}" \
    | "$FZF_BIN" --delimiter=$'\t' --with-nth=1 --header="Film correspondant (TMDb)" \
        --height='~40%' --border --layout=reverse || true)"
  if [[ -n "$pick" ]]; then
    IFS=$'\t' read -r _ t y <<<"$pick"
    if [[ "$t" != "$NAME_TITLE" || "$y" != "$NAME_YEAR" ]]; then
      NAME_TITLE="$t"; NAME_YEAR="$y"; NAME_ORIGIN="$NAME_ORIGIN + TMDb"
    fi
  fi
  tmdb_attribution
}

# ─── Choix du titre principal ────────────────────────────────────────────────
playlist_number() {   # « 00800.mpls » → 800 ; vide si non numérique
  local n="${1%.*}"
  n="${n##*/}"
  if [[ "$n" =~ ^[0-9]+$ ]]; then echo $(( 10#$n )); fi
}

set_main_from_line() {   # <ligne TITLES> <origine>
  IFS=$'\t' read -r MAIN_IDX MAIN_SECS MAIN_BYTES MAIN_SOURCE _ <<<"$1"
  MAIN_ORIGIN="$2"
}

find_title_line() {   # <numéro ou fichier source>
  local want="$1" wnum idx secs bytes src name
  wnum="$(playlist_number "$want")"
  while IFS=$'\t' read -r idx secs bytes src name; do
    if [[ -z "$idx" ]]; then continue; fi
    if [[ "${src,,}" == "${want,,}" ]] \
       || [[ -n "$wnum" && "$(playlist_number "$src")" == "$wnum" ]] \
       || [[ "$idx" == "$want" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$secs" "$bytes" "$src" "$name"
      return 0
    fi
  done <<<"$TITLES"
  return 0
}

pick_main_title() {
  local line="" origin="" count pick
  if [[ -n "$FORCED_PLAYLIST" ]]; then
    line="$(find_title_line "$FORCED_PLAYLIST")"
    if [[ -z "$line" ]]; then die_code "$EXIT_USAGE" "Titre ou playlist « $FORCED_PLAYLIST » introuvable parmi les titres d'au moins $MIN_PLAYLIST_MINUTES min."; fi
    set_main_from_line "$line" "option --playlist"
    return 0
  fi

  if [[ -n "$DISCDB_MAIN" ]]; then
    line="$(find_title_line "$DISCDB_MAIN")"
    if [[ -n "$line" ]]; then origin="TheDiscDB"; fi
  fi
  if [[ -z "$line" ]]; then
    line="$(head -n1 <<<"$TITLES")"
    origin="le plus long"
  fi

  count="$(grep -c . <<<"$TITLES" || true)"
  if ! is_silent && [[ "$DRY_RUN" != true && "$count" -gt 1 ]]; then
    local first rest
    first="$(format_title_line "$line" "$origin")"
    rest="$(grep -vxF -- "$line" <<<"$TITLES" | while IFS= read -r l; do format_title_line "$l" ""; done || true)"
    pick="$(printf '%s\n%s\n' "$first" "$rest" | sed '/^$/d' \
      | "$FZF_BIN" --delimiter=$'\t' --with-nth=2 --header="Titre principal (présélection : $origin)" \
          --height='~40%' --border --layout=reverse || true)"
    if [[ -n "$pick" ]]; then
      line="$(cut -f1 <<<"$pick" | base64 -d)"
      if [[ "$(cut -f2 <<<"$pick")" != *"[$origin]"* ]]; then origin="choix manuel"; fi
    fi
  fi
  set_main_from_line "$line" "$origin"
}

# Ligne fzf : <ligne d'origine en base64> \t <libellé lisible>
format_title_line() {   # <ligne TITLES> <origine>
  local idx secs bytes src name gb label
  IFS=$'\t' read -r idx secs bytes src name <<<"$1"
  gb="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1e9 }')"
  label="$(printf '%-12s %s  %6s Go  %s' "$src" "$(seconds_to_hms "$secs")" "$gb" "$name")"
  if [[ -n "$2" ]]; then label="$label  [$2]"; fi
  printf '%s\t%s\n' "$(printf '%s' "$1" | base64 -w0)" "$label"
}

# ─── Destination ─────────────────────────────────────────────────────────────
compute_destination() {
  local rendered
  if [[ -d "$DEST_ARG" ]]; then
    DEST_IS_DIR=true
    DEST_DIR="$(realpath "$DEST_ARG")"
    rendered="$(helper render-name "$NAME_TEMPLATE" "$NAME_TITLE" "$NAME_YEAR" || true)"
    BASE_NAME="$(sanitize_filename "$rendered")"
    if [[ -z "$BASE_NAME" ]]; then BASE_NAME="encbd"; fi
    if [[ "$OUTPUT_3D" == true ]]; then
      FINAL_PATH="$DEST_DIR/$BASE_NAME.$STEREO_LAYOUT.mkv"
    else
      FINAL_PATH="$DEST_DIR/$BASE_NAME.mkv"
    fi
  else
    DEST_IS_DIR=false
    local parent; parent="$(dirname "$DEST_ARG")"
    if [[ ! -d "$parent" ]]; then die_code "$EXIT_USAGE" "Le dossier de destination n'existe pas : $parent"; fi
    FINAL_PATH="$(realpath -m "$DEST_ARG")"
    DEST_DIR="$(dirname "$FINAL_PATH")"
    BASE_NAME="$(basename "$FINAL_PATH")"
    BASE_NAME="${BASE_NAME%.*}"
  fi
  WORKDIR="${WORKDIR_ROOT:-$DEST_DIR}/$(sanitize_filename "$BASE_NAME").encbd"
}

exit_if_final_exists() {
  if [[ -s "$FINAL_PATH" ]]; then
    echo "✅ [INFO] Le fichier final existe déjà : $FINAL_PATH"
    echo "✅ [INFO] Aucun traitement nécessaire."
    exit 0
  fi
}

# ─── Espace disque ───────────────────────────────────────────────────────────
EST_NEED=0; EST_AVAIL=0

existing_parent() {
  local d="$1"
  while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
  printf '%s' "$d"
}

estimate_space() {
  local factor=13      # ×1,3 en 2D (MKV ripé + encodage)
  if [[ "$OUTPUT_3D" == true ]]; then factor=22; fi   # ×2,2 en 3D (+ flux démultiplexés)
  EST_NEED=$(( MAIN_BYTES * factor / 10 + MIN_FREE_GB * 1000000000 ))
  EST_AVAIL="$(df -B1 --output=avail "$(existing_parent "$WORKDIR")" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
  if ! [[ "$EST_AVAIL" =~ ^[0-9]+$ ]]; then EST_AVAIL=0; fi
}

gb() { awk -v b="$1" 'BEGIN { printf "%.1f Go", b / 1e9 }'; }

check_space() {
  estimate_space
  if [[ "$EST_AVAIL" -lt "$EST_NEED" ]]; then
    die_code "$EXIT_SPACE" "Espace insuffisant dans $(existing_parent "$WORKDIR") : $(gb "$EST_NEED") nécessaires (estimation + MIN_FREE_GB), $(gb "$EST_AVAIL") disponibles."
  fi
}

# ─── Rapport --dry-run ───────────────────────────────────────────────────────
dry_run_report() {
  local backend_desc="$BACKEND"
  if [[ "$BACKEND" == "makemkv" ]]; then backend_desc="makemkv ($MAKEMKVCON)"; fi
  if [[ "$BACKEND" == "libaacs" && "$DISC_TYPE" == "dvd" ]]; then backend_desc="libdvdcss (ffmpeg dvdvideo)"; fi
  estimate_space
  echo
  echo "== encbd : détection (--dry-run, rien n'est écrit) =="
  printf '%-17s: %s (%s)\n' "Source" "$SOURCE_PATH" "$SRC_KIND"
  if [[ -n "$MOUNT_DIR" ]]; then printf '%-17s: %s\n' "Contenu" "$MOUNT_DIR"; fi
  printf '%-17s: %s\n' "Type" "$(disc_type_label)"
  printf '%-17s: %s\n' "Protection" "$PROTECTION"
  printf '%-17s: %s\n' "Moteur de rip" "$backend_desc"
  if [[ "$FALLBACK_2D" == true ]]; then printf '%-17s: %s\n' "3D" "$WARN_3D_MSG"; fi
  printf '%-17s: %s%s  [%s]\n' "Nom" "$NAME_TITLE" "${NAME_YEAR:+ ($NAME_YEAR)}" "$NAME_ORIGIN"
  printf '%-17s: %s — %s, %s  [%s]\n' "Titre principal" "${MAIN_SOURCE:-$MAIN_IDX}" "$(seconds_to_hms "$MAIN_SECS")" "$(gb "$MAIN_BYTES")" "$MAIN_ORIGIN"
  printf '%-17s: %s\n' "Fichier final" "$FINAL_PATH"
  printf '%-17s: %s\n' "Travail" "$WORKDIR"
  printf '%-17s: besoin estimé %s, disponible %s\n' "Espace" "$(gb "$EST_NEED")" "$(gb "$EST_AVAIL")"
  if [[ "$OUTPUT_3D" == true ]]; then
    printf '%-17s: encbd3d.sh, %s %s\n' "Traitement" "$STEREO_LAYOUT" "$SBS_MODE"
  else
    printf '%-17s: encodage 2D\n' "Traitement"
  fi
  local enc; enc="$(print_encoder_settings)"
  printf '%-17s: %s\n' "Encodeur" "${enc#Encodage : }"
}

# ─── Rip ─────────────────────────────────────────────────────────────────────
makemkv_progress() {
  awk -F'[:,]' '
    /^PRGV:/ { if ($4 > 0) { printf "\r    Rip : %3d %%", int($3 * 100 / $4); fflush() } }
    END { print "" }'
}

rip_title() {
  local rip_dir="$WORKDIR/rip" log rc=0
  mkdir -p "$rip_dir"
  if [[ -f "$rip_dir/.complete" ]]; then
    msg_info "Rip déjà effectué, réutilisé ($rip_dir)."
  else
    rm -f "$rip_dir"/*.mkv
    log="$WORKDIR/rip.log"
    case "$BACKEND" in
      makemkv)
        msg_step "Rip du titre ${MAIN_SOURCE:-$MAIN_IDX} avec MakeMKV..."
        set +e
        host_run "$MAKEMKVCON" -r --progress=-same --minlength="$MIN_SECONDS" \
          mkv "$MAKEMKV_SRC" "$MAIN_IDX" "$rip_dir" 2>&1 | tee "$log" | makemkv_progress
        rc=${PIPESTATUS[0]}
        set -e
        check_makemkv_log "$log" "$rc"
        ;;
      libaacs)
        set +e
        if [[ "$DISC_TYPE" == "dvd" ]]; then
          msg_step "Rip du titre DVD $MAIN_IDX (libdvdcss)..."
          "$FFMPEG_BIN" -hide_banner -nostdin -loglevel warning -stats \
            -f dvdvideo -preindex 1 -title "$MAIN_IDX" -i "$SOURCE_PATH" \
            -map 0:v -map '0:a?' -map '0:s?' -c copy -dn "$rip_dir/title.mkv" 2> >(tee "$log" >&2)
          rc=$?
        else
          msg_step "Rip de la playlist $MAIN_SOURCE (libaacs)..."
          "$FFMPEG_BIN" -hide_banner -nostdin -loglevel warning -stats \
            -playlist "$MAIN_IDX" -i "bluray:$MOUNT_DIR" \
            -map 0:v:0 -map '0:a?' -map '0:s?' -c copy -dn "$rip_dir/title.mkv" 2> >(tee "$log" >&2)
          rc=$?
        fi
        set -e
        sleep 0.5   # laisse « tee » finir d'écrire le journal
        if [[ "$rc" -ne 0 ]] && grep -qiE 'aacs|bd\+|vuk|keydb|css|decrypt' "$log" 2>/dev/null; then
          die_code "$EXIT_DECRYPT" "Déchiffrement impossible (clé absente de $(keydb_path), BD+ ou CSS). Installez MakeMKV. Journal : $log"
        fi
        ;;
    esac
    if [[ "$rc" -ne 0 ]]; then die_code "$EXIT_RIP" "Échec du rip (code $rc). Journal : $log"; fi
    touch "$rip_dir/.complete"
  fi
  RIPPED_MKV="$(find "$rip_dir" -maxdepth 1 -type f -name '*.mkv' -printf '%s\t%p\n' | sort -rn | head -n1 | cut -f2- || true)"
  if [[ -z "$RIPPED_MKV" || ! -s "$RIPPED_MKV" ]]; then
    rm -f "$rip_dir/.complete"
    die_code "$EXIT_RIP" "Aucun MKV produit par le rip dans $rip_dir."
  fi
  msg_info "MKV ripé : $RIPPED_MKV"
}

# ─── Encodage 3D (délégué) ───────────────────────────────────────────────────
encode_3d() {
  local args=("$RIPPED_MKV"
    --config "$CONFIG_FILE" --workdir "$WORKDIR" --no-inhibit --no-settings-prompt
    --title "$NAME_TITLE${NAME_YEAR:+ ($NAME_YEAR)}"
    --layout "$STEREO_LAYOUT" --sbs "$SBS_MODE" --encoder "$ENCODER"
    --preset "$X264_PRESET" --crf "$X264_CRF" --qp "$VAAPI_QP"
    --x264-opts "$X264_EXTRA_OPTS" --vaapi-opts "$VAAPI_EXTRA_OPTS"
    --max-channels "$AUDIO_MAX_CHANNELS")
  if is_silent; then args+=(--silent); fi
  if [[ -n "$LANG_FILTER" ]]; then args+=(--lang "$LANG_FILTER"); fi
  if [[ "$KEEP_INTERMEDIATES" == "true" ]]; then args+=(--keep-intermediates); fi
  if [[ "$DEST_IS_DIR" == true ]]; then
    args+=(--output-stem "$DEST_DIR/$BASE_NAME")
  else
    args+=(--output "$FINAL_PATH")
  fi
  msg_step "Encodage 3D délégué à encbd3d.sh..."
  if ! bash "$ENCBD3D_SCRIPT" "${args[@]}"; then
    die_code "$EXIT_ENCODE" "encbd3d.sh a échoué. Dossier de travail conservé : $WORKDIR"
  fi
}

# ─── Encodage 2D ─────────────────────────────────────────────────────────────
SELECTED_AUDIO=""; SELECTED_SUBS=""

select_tracks_2d() {   # <lignes id|codec|lang|desc>
  local tracks="$1" lines=()
  if is_silent; then
    SELECTED_AUDIO="$(awk -F'|' '$2 ~ /^A_/' <<<"$tracks" | filter_lang | filter_channels || true)"
    SELECTED_SUBS="$(awk -F'|' '$2 ~ /^S_/' <<<"$tracks" | filter_lang || true)"
    if [[ -z "$SELECTED_AUDIO" ]]; then msg_warn "Aucune piste audio retenue."; fi
    return 0
  fi
  mapfile -t lines < <(awk -F'|' '$2 ~ /^A_/' <<<"$tracks" | filter_lang | filter_channels || true)
  SELECTED_AUDIO="$(pick_many "Pistes audio" ${lines[@]+"${lines[@]}"} || true)"
  mapfile -t lines < <(awk -F'|' '$2 ~ /^S_/' <<<"$tracks" | filter_lang || true)
  SELECTED_SUBS="$(pick_many "Sous-titres" ${lines[@]+"${lines[@]}"} || true)"
}

is_interlaced() {
  local out line tff bff prog
  out="$("$FFMPEG_BIN" -hide_banner -nostdin -ss 300 -t 30 -i "$RIPPED_MKV" -map 0:v:0 -vf idet -an -sn -f null - 2>&1 || true)"
  line="$(grep 'Multi frame detection' <<<"$out" | tail -n1 || true)"
  if [[ -z "$line" ]]; then return 1; fi
  tff="$(sed -E 's/.*TFF: *([0-9]+).*/\1/' <<<"$line")"
  bff="$(sed -E 's/.*BFF: *([0-9]+).*/\1/' <<<"$line")"
  prog="$(sed -E 's/.*Progressive: *([0-9]+).*/\1/' <<<"$line")"
  [[ $(( tff + bff )) -gt "$prog" ]]
}

build_video_filter() {
  VIDEO_FILTER=""
  local deint=false
  case "$DEINTERLACE" in
    on) deint=true ;;
    off) ;;
    *) msg_step "Détection de l'entrelacement..."; if is_interlaced; then deint=true; fi ;;
  esac
  if [[ "$deint" == true ]]; then
    msg_info "Source entrelacée : désentrelacement bwdif."
    VIDEO_FILTER="bwdif=mode=send_frame"
  fi
  if [[ "$DISC_TYPE" == "uhd" ]]; then
    if ! ffmpeg_has filters zscale; then
      die_code "$EXIT_UNSUPPORTED" "UHD : la conversion HDR → SDR exige le filtre zscale de ffmpeg (libzimg), absent."
    fi
    msg_info "UHD : conversion HDR → SDR (tone mapping) pour x264 8 bits."
    VIDEO_FILTER="${VIDEO_FILTER:+$VIDEO_FILTER,}zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
  fi
}

encode_2d() {
  local json="$WORKDIR/ripped.json" tracks dd="" disp="" vinfo
  "$MKVMERGE_BIN" -J "$RIPPED_MKV" >"$json"
  tracks="$(helper mkv-tracks "$json" || true)"
  select_tracks_2d "$tracks"
  vinfo="$(helper mkv-video "$json" || true)"
  if [[ -n "$vinfo" ]]; then IFS=$'\t' read -r dd disp _ <<<"$vinfo"; fi

  local encoded="$WORKDIR/encoded.2d.264" tmp="$WORKDIR/encoded.tmp.264"
  if [[ -s "$encoded" ]]; then
    msg_info "Encodage déjà présent ($encoded), réutilisé."
  else
    build_video_filter
    msg_step "Encodage vidéo avec $ENCODER..."
    if [[ "$ENCODER" == "vaapi" ]]; then
      # shellcheck disable=SC2086  # options supplémentaires découpées volontairement
      "$FFMPEG_BIN" -hide_banner -nostdin -loglevel warning -stats \
        -vaapi_device "$VAAPI_DEVICE" -i "$RIPPED_MKV" -map 0:v:0 \
        -vf "${VIDEO_FILTER:+$VIDEO_FILTER,}format=nv12,hwupload" \
        -c:v h264_vaapi -qp "$VAAPI_QP" $VAAPI_EXTRA_OPTS -f h264 -y "$tmp" \
        || die_code "$EXIT_ENCODE" "Échec de l'encodage VAAPI."
    else
      local vf_args=()
      if [[ -n "$VIDEO_FILTER" ]]; then vf_args=(-vf "$VIDEO_FILTER"); fi
      # shellcheck disable=SC2086
      "$FFMPEG_BIN" -hide_banner -nostdin -loglevel error -i "$RIPPED_MKV" -map 0:v:0 \
          ${vf_args[@]+"${vf_args[@]}"} -pix_fmt yuv420p -strict -1 -f yuv4mpegpipe - \
        | "$X264_BIN" --demuxer y4m --preset "$X264_PRESET" --crf "$X264_CRF" $X264_EXTRA_OPTS -o "$tmp" - \
        || die_code "$EXIT_ENCODE" "Échec de l'encodage x264."
    fi
    mv -f -- "$tmp" "$encoded"
  fi

  # Mux : vidéo encodée + audio, sous-titres et chapitres repris tels quels du MKV ripé.
  local out="$WORKDIR/output.partial.mkv" rc=0 ids
  local enc_label="x264 CRF $X264_CRF preset $X264_PRESET"
  if [[ "$ENCODER" == "vaapi" ]]; then enc_label="h264_vaapi QP $VAAPI_QP"; fi
  local args=(-o "$out" --title "$NAME_TITLE${NAME_YEAR:+ ($NAME_YEAR)}"
    --track-name "0:$enc_label" --language 0:und --default-track 0:yes)
  if [[ -n "$dd" ]]; then args+=(--default-duration "0:${dd}ns"); fi
  if [[ -n "$disp" ]]; then args+=(--display-dimensions "0:$disp"); fi
  args+=("$encoded" --no-video --no-attachments)
  ids="$(cut -d'|' -f1 <<<"$SELECTED_AUDIO" | sed '/^$/d' | paste -sd, - || true)"
  if [[ -n "$ids" ]]; then args+=(--audio-tracks "$ids"); else args+=(--no-audio); fi
  ids="$(cut -d'|' -f1 <<<"$SELECTED_SUBS" | sed '/^$/d' | paste -sd, - || true)"
  if [[ -n "$ids" ]]; then args+=(--subtitle-tracks "$ids"); else args+=(--no-subtitles); fi
  args+=("$RIPPED_MKV")

  msg_step "Multiplexage final avec mkvmerge..."
  "$MKVMERGE_BIN" "${args[@]}" || rc=$?
  if [[ "$rc" -ge 2 || ! -s "$out" ]]; then
    die_code "$EXIT_ENCODE" "mkvmerge a échoué (code $rc). Dossier de travail conservé : $WORKDIR"
  fi
  if [[ "$rc" -eq 1 ]]; then msg_warn "mkvmerge a signalé des avertissements (fichier produit)."; fi
  mv -f -- "$out" "$FINAL_PATH"
}

# ─── Vidéo : déroulé complet ─────────────────────────────────────────────────
run_video() {
  if ! is_silent && [[ "$DRY_RUN" != true ]]; then require_tool "$FZF_BIN" "sélections interactives (ou --silent)"; fi
  choose_backend
  announce_2d_fallback
  list_titles
  identify_name
  pick_main_title
  compute_destination

  if [[ "$DRY_RUN" == true ]]; then dry_run_report; return 0; fi
  exit_if_final_exists

  if ! is_silent; then
    require_tool "$FZF_BIN" "sélections interactives"
    if [[ "$OUTPUT_3D" == true ]]; then pick_stereo_settings; fi
    pick_encoder_settings
    validate_settings
    compute_destination      # la disposition choisie change le nom 3D
    exit_if_final_exists
  fi
  print_encoder_settings
  echo "Destination : $FINAL_PATH"

  require_tool "$MKVMERGE_BIN" "multiplexage"
  require_tool "$FFMPEG_BIN" "décodage"
  if [[ "$ENCODER" == "x264" ]]; then require_tool "$X264_BIN" "encodage x264"; fi
  if [[ "$OUTPUT_3D" == true && ! -f "$ENCBD3D_SCRIPT" ]]; then
    die_code "$EXIT_PREREQ" "encbd3d.sh introuvable ($ENCBD3D_SCRIPT)."
  fi

  check_space
  if [[ "$INHIBIT_SLEEP" == "true" ]]; then start_inhibit "Rip et encodage en cours (encbd)"; fi
  mkdir -p "$WORKDIR"

  rip_title
  if [[ "$OUTPUT_3D" == true ]]; then encode_3d; else encode_2d; fi

  if [[ "$KEEP_INTERMEDIATES" == "true" ]]; then
    echo "📁 [INFO] Dossier de travail conservé : $WORKDIR"
  else
    safe_remove_dir "$WORKDIR" ".encbd"
  fi
  if [[ "$FALLBACK_2D" == true ]]; then echo "⚠️  $WARN_3D_MSG" >&2; fi

  local final="$FINAL_PATH"
  if [[ "$OUTPUT_3D" == true && "$DEST_IS_DIR" == true ]]; then final="$DEST_DIR/$BASE_NAME.$STEREO_LAYOUT.mkv"; fi
  echo "🎉 [INFO] Terminé : $final"
}

# ─── CD audio ────────────────────────────────────────────────────────────────
# Lance cyanrip dans <dossier>, journal ajouté à <journal> ; renvoie le code de cyanrip.
run_cyanrip() {   # <dossier> <journal> <cyanrip> <arguments...>
  local dir="$1" log="$2" rc; shift 2
  set +e
  ( cd "$dir" && "$@" ) 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

run_cd() {
  local cyan run_dir dir_scheme log rc=0 base_args=()
  cyan="$(command -v "$CYANRIP_BIN" 2>/dev/null || true)"
  if [[ -z "$cyan" ]]; then die_code "$EXIT_PREREQ" "cyanrip introuvable : la prise en charge des CD audio est désactivée."; fi

  if [[ -d "$DEST_ARG" ]]; then
    run_dir="$(realpath "$DEST_ARG")"; dir_scheme="$MUSIC_DIR_TEMPLATE"
  else
    run_dir="$(dirname "$DEST_ARG")"
    if [[ ! -d "$run_dir" ]]; then die_code "$EXIT_USAGE" "Le dossier de destination n'existe pas : $run_dir"; fi
    run_dir="$(realpath "$run_dir")"; dir_scheme="$(basename "$DEST_ARG")"
  fi

  base_args=(-d "$DEVICE" -o flac -D "$dir_scheme" -F "$MUSIC_FILE_TEMPLATE")
  if [[ -n "$CD_READ_OFFSET" ]]; then base_args+=(-s "$CD_READ_OFFSET"); fi
  if ! is_online; then base_args+=(-N -A -U); fi

  if [[ "$DRY_RUN" == true ]]; then
    echo
    echo "== encbd : détection (--dry-run, rien n'est écrit) =="
    printf '%-17s: %s\n' "Source" "$DEVICE" "Type" "CD audio" "Destination" "$run_dir/$dir_scheme"
    printf '%-17s: cyanrip (%s)\n' "Extraction" "$cyan"
    if [[ -z "$CD_READ_OFFSET" ]]; then
      echo "Note : CD_READ_OFFSET vide (0). Pour le trouver : encbd.appimage --run cyanrip -f -d $DEVICE"
    fi
    echo
    "$cyan" -I "${base_args[@]}" || true
    return 0
  fi

  if [[ "$INHIBIT_SLEEP" == "true" ]]; then start_inhibit "Extraction du CD audio (encbd)"; fi
  log="$RUN_TMP/cyanrip.log"
  msg_step "Extraction du CD avec cyanrip vers $run_dir..."
  run_cyanrip "$run_dir" "$log" "$cyan" "${base_args[@]}" || rc=$?
  if [[ "$rc" -eq 0 ]]; then echo "🎉 [INFO] Terminé : $run_dir"; return 0; fi

  # Échec, en général parce que MusicBrainz renvoie plusieurs éditions ou aucune.
  local retry=()
  if is_silent; then
    msg_warn "cyanrip a échoué (code $rc) ; nouvel essai avec la première édition MusicBrainz."
    retry=(-R 1)
  else
    echo
    echo "cyanrip a échoué (code $rc). Voir ci-dessus. Que faire ?"
    echo "  1) utiliser une édition MusicBrainz (numéro à saisir)"
    echo "  2) saisir artiste et album, sans MusicBrainz"
    echo "  3) annuler"
    local ans="" n="" artist="" album=""
    read -rp "Choix [1] : " ans || true
    case "${ans:-1}" in
      1) read -rp "Numéro d'édition [1] : " n || true; retry=(-R "${n:-1}") ;;
      2) read -rp "Artiste : " artist || true; read -rp "Album : " album || true
         retry=(-N -a "album=${album:-Album inconnu}:album_artist=${artist:-Artiste inconnu}") ;;
      *) die_code "$EXIT_PREREQ" "Annulé." ;;
    esac
  fi
  rc=0
  run_cyanrip "$run_dir" "$log" "$cyan" "${base_args[@]}" "${retry[@]}" || rc=$?
  if [[ "$rc" -ne 0 ]] && is_silent; then
    msg_warn "Nouvel échec ; extraction sans métadonnées MusicBrainz."
    rc=0
    run_cyanrip "$run_dir" "$log" "$cyan" "${base_args[@]}" -N -a "album=Album inconnu:album_artist=Artiste inconnu" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then die_code "$EXIT_RIP" "Échec de l'extraction du CD (code $rc). Journal : $log"; fi
  echo "🎉 [INFO] Terminé : $run_dir"
}

# ─── SACD ────────────────────────────────────────────────────────────────────
convert_dsf() {   # <fichier.dsf> <sortie sans extension> <format>
  local in="$1" out="$2" fmt="$3" resampler=""
  mkdir -p "$(dirname "$out")"
  case "$fmt" in
    dsf) mv -f -- "$in" "$out.dsf" ;;
    wavpack)
      "$WAVPACK_BIN" -hh -m -q --import-id3 "$in" -o "$out.wv" 2>/dev/null \
        || "$WAVPACK_BIN" -hh -m -q "$in" -o "$out.wv" \
        || die_code "$EXIT_ENCODE" "wavpack a échoué sur $in"
      ;;
    flac)
      local version; version="$("$FFMPEG_BIN" -hide_banner -version 2>/dev/null || true)"
      if grep -q -- '--enable-libsoxr' <<<"$version"; then resampler=":resampler=soxr"; fi
      "$FFMPEG_BIN" -hide_banner -nostdin -loglevel error -i "$in" -map 0:a -map_metadata 0 \
        -af "aresample=88200$resampler" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 \
        -compression_level "$FLAC_LEVEL" -y "$out.flac" \
        || die_code "$EXIT_ENCODE" "Conversion FLAC impossible pour $in"
      ;;
  esac
}

run_sacd() {
  local sacd fmt="$SACD_FORMAT" chan=() input="$SOURCE_PATH" out_root strip_first=false
  sacd="$(command -v "$SACD_EXTRACT_BIN" 2>/dev/null || true)"
  if [[ -z "$sacd" ]]; then die_code "$EXIT_PREREQ" "sacd_extract introuvable : la prise en charge des SACD est désactivée."; fi

  case "$SACD_CHANNELS" in
    stereo) chan=(-2) ;;
    multi) chan=(-m) ;;
    both) chan=(-2 -m) ;;
    *) die_code "$EXIT_USAGE" "SACD_CHANNELS : stereo, multi ou both attendu (reçu '$SACD_CHANNELS')" ;;
  esac

  if is_silent; then
    fmt="wavpack"     # règle de --silent : DSD conservé sans perte
  elif [[ "$DRY_RUN" != true ]]; then
    require_tool "$FZF_BIN" "sélections interactives"
    local others=() f
    for f in flac dsf wavpack; do if [[ "$f" != "$fmt" ]]; then others+=("$f"); fi; done
    f="$(fzf_pick "Format SACD : flac (PCM 24 bits, converti) | dsf (DSD brut) | wavpack (DSD sans perte)" '~20%' "$fmt" "${others[@]}")"
    if [[ -n "$f" ]]; then fmt="$f"; fi
  fi
  case "$fmt" in
    flac|dsf|wavpack) ;;
    *) die_code "$EXIT_USAGE" "SACD_FORMAT : flac, dsf ou wavpack attendu (reçu '$fmt')" ;;
  esac

  if [[ -d "$DEST_ARG" ]]; then
    out_root="$(realpath "$DEST_ARG")"
  else
    if [[ ! -d "$(dirname "$DEST_ARG")" ]]; then die_code "$EXIT_USAGE" "Le dossier de destination n'existe pas : $(dirname "$DEST_ARG")"; fi
    out_root="$(realpath -m "$DEST_ARG")"
    strip_first=true      # la destination est le dossier de l'album lui-même
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo
    echo "== encbd : détection (--dry-run, rien n'est écrit) =="
    printf '%-17s: %s\n' "Source" "$input" "Type" "SACD" "Format" "$fmt" "Canaux" "$SACD_CHANNELS" "Destination" "$out_root"
    echo
    "$sacd" -P "-i$input" || true
    return 0
  fi

  if [[ "$fmt" == "wavpack" ]]; then require_tool "$WAVPACK_BIN" "compression DSD sans perte"; fi
  if [[ "$fmt" == "flac" ]]; then require_tool "$FFMPEG_BIN" "conversion DSD → PCM"; fi
  if [[ "$INHIBIT_SLEEP" == "true" ]]; then start_inhibit "Extraction du SACD (encbd)"; fi

  local work
  work="${WORKDIR_ROOT:-$(dirname "$out_root")}/sacd-$$.encbd"
  mkdir -p "$work"
  msg_step "Extraction DSD avec sacd_extract..."
  ( cd "$work" && "$sacd" "${chan[@]}" -s "-i$input" ) || die_code "$EXIT_RIP" "sacd_extract a échoué (dossier conservé : $work)."

  local f rel dest count=0
  while IFS= read -r -d '' f; do
    rel="${f#"$work"/}"
    if [[ "$strip_first" == true && "$rel" == */* ]]; then rel="${rel#*/}"; fi
    dest="$out_root/$rel"
    if [[ "${f,,}" == *.dsf ]]; then
      msg_step "$(basename "$f") → $fmt"
      convert_dsf "$f" "${dest%.*}" "$fmt"
      count=$((count + 1))
    else
      mkdir -p "$(dirname "$dest")"
      cp -f -- "$f" "$dest"
    fi
  done < <(find "$work" -type f -print0 | sort -z)

  if [[ "$count" -eq 0 ]]; then die_code "$EXIT_RIP" "Aucune piste DSD extraite (dossier conservé : $work)."; fi
  if [[ "$KEEP_INTERMEDIATES" != "true" ]]; then safe_remove_dir "$work" ".encbd"; fi
  echo "🎉 [INFO] Terminé : $count piste(s) dans $out_root"
}

# ─── Programme principal ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  encbd_load_config
  apply_cli_overrides
  validate_settings
  if ! [[ "$MIN_PLAYLIST_MINUTES" =~ ^[0-9]+$ ]]; then die_code "$EXIT_USAGE" "MIN_PLAYLIST_MINUTES doit être un entier."; fi
  if ! [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then die_code "$EXIT_USAGE" "MIN_FREE_GB doit être un entier."; fi
  MIN_SECONDS=$(( MIN_PLAYLIST_MINUTES * 60 ))
  if ! command -v "$ENCBD_PYTHON" >/dev/null 2>&1; then die_code "$EXIT_PREREQ" "Python introuvable ($ENCBD_PYTHON)."; fi
  setup_run_tmp

  probe_source
  msg_info "Disque : $(disc_type_label) — source $SOURCE_PATH"
  case "$DISC_TYPE" in
    cd) run_cd ;;
    sacd) run_sacd ;;
    *) run_video ;;
  esac
}

# Permet de « source »-r le fichier pour tester ses fonctions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
