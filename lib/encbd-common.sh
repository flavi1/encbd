# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
# encbd-common.sh — fonctions partagées par encbd.sh et encbd3d.sh.
# Ce fichier est « sourcé » ; il ne s'exécute pas seul.

# ─── Codes de sortie ─────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # utilisés par les scripts qui sourcent ce fichier
EXIT_OK=0
EXIT_USAGE=1          # erreur d'usage ou erreur non classée
EXIT_PREREQ=2         # prérequis manquant (outil, bibliothèque) ou annulation
EXIT_SOURCE=3         # source illisible : pas de disque, montage impossible
EXIT_UNSUPPORTED=4    # disque illisible par le moteur (UHD notamment) ou format non géré
EXIT_DECRYPT=5        # déchiffrement impossible (clé MakeMKV, VUK, BD+)
EXIT_SPACE=6          # espace disque insuffisant
EXIT_RIP=7            # échec du rip
EXIT_ENCODE=8         # échec de l'encodage ou du mux

# ─── Messages ────────────────────────────────────────────────────────────────
msg_info() { echo "ℹ️  [INFO] $*"; }
msg_step() { echo "⚙️ [INFO] $*"; }
msg_warn() { echo "⚠️ [WARN] $*" >&2; }
die_code() {   # <code> <message...>
  local code="$1"; shift
  echo "❌ [ERREUR] $*" >&2
  exit "$code"
}

# ─── Fonctions exécutées à la sortie (une seule trap EXIT partagée) ─────────
if ! declare -p ENCBD_EXIT_HOOKS >/dev/null 2>&1; then ENCBD_EXIT_HOOKS=(); fi

ENCBD_EXIT_STATUS=0
_encbd_run_exit_hooks() {
  ENCBD_EXIT_STATUS=$?
  local i
  for (( i = ${#ENCBD_EXIT_HOOKS[@]} - 1; i >= 0; i-- )); do
    "${ENCBD_EXIT_HOOKS[$i]}" || true
  done
}

encbd_add_exit_hook() {   # <fonction>
  ENCBD_EXIT_HOOKS+=("$1")
  trap _encbd_run_exit_hooks EXIT
}

# ─── Outils de l'hôte (hors AppImage) ────────────────────────────────────────
# Sous AppImage, LD_LIBRARY_PATH pointe vers nos bibliothèques : on rend celui de l'hôte
# aux programmes système (makemkvcon, udisksctl, blkid, inhibiteurs…).
encbd_host_ld() {
  printf '%s' "${ENCBD_HOST_LD_LIBRARY_PATH-${ENCBD3D_HOST_LD_LIBRARY_PATH-${LD_LIBRARY_PATH:-}}}"
}

host_run() {
  env LD_LIBRARY_PATH="$(encbd_host_ld)" "$@"
}

# ─── Configuration ───────────────────────────────────────────────────────────
: "${CONFIG_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/encbd.conf}"
if ! declare -p CLI_OVERRIDES >/dev/null 2>&1; then CLI_OVERRIDES=(); fi
: "${LANG_FILTER:=}"
: "${SILENT:=false}"

encbd_default_config() {
  cat <<'EOF'
# encbd.conf — configuration partagée par encbd.sh et encbd3d.sh.
# Les options de la ligne de commande sont prioritaires sur ce fichier.

# ── Outils ────────────────────────────────────────────────────────────────
# Vide = recherche dans le PATH (puis dans l'arborescence de compilation).
TSMUXER_BIN=""
VSPIPE_BIN=""
MVC_SOURCE_PLUGIN=""
MAKEMKVCON_BIN=""        # makemkvcon de la machine ; jamais embarqué dans l'AppImage

X264_BIN="x264"
FFMPEG_BIN="ffmpeg"
MKVMERGE_BIN="mkvmerge"
MKVEXTRACT_BIN="mkvextract"
FZF_BIN="fzf"
CYANRIP_BIN="cyanrip"
SACD_EXTRACT_BIN="sacd_extract"
WAVPACK_BIN="wavpack"

# ── Déchiffrement ─────────────────────────────────────────────────────────
# auto    : MakeMKV s'il est installé, sinon libaacs (Blu-ray) / libdvdcss (DVD)
# makemkv : MakeMKV uniquement      libaacs : libaacs / libdvdcss uniquement
RIP_BACKEND="auto"

# ── Nommage (destination = dossier) ───────────────────────────────────────
# Variables : {title} {year}. Un « () » vide est retiré quand l'année est inconnue.
NAME_TEMPLATE="{title} ({year})"
ONLINE_LOOKUP="true"     # TheDiscDB (sans clé) et TMDb (si clé)
TMDB_API_KEY=""          # clé personnelle TMDb (API v3 ou jeton v4) ; vide = TMDb ignoré
TMDB_LANGUAGE="fr-FR"

# ── Vidéo ─────────────────────────────────────────────────────────────────
STEREO_LAYOUT="tab"      # 3D : sbs (côte à côte) | tab (haut-bas)
SBS_MODE="half"          # 3D : full | half (résolution par œil)
ENCODER="x264"           # x264 | vaapi

X264_PRESET="slow"
X264_CRF="22"
X264_EXTRA_OPTS="--aq-mode 3 --bframes 6"

# VAAPI (matériel). Les options extra suivent la syntaxe ffmpeg (PAS x264).
VAAPI_DEVICE="/dev/dri/renderD128"
VAAPI_QP="20"
VAAPI_EXTRA_OPTS="-profile:v high -rc_mode CQP -quality 0"

DEINTERLACE="auto"       # auto (détection) | on | off

# Titres plus courts ignorés (menus, bandes-annonces, bonus).
MIN_PLAYLIST_MINUTES="40"
# Pistes audio : nombre maximal de canaux (2 = stéréo ; 0 = toutes).
AUDIO_MAX_CHANNELS="2"

KEEP_INTERMEDIATES="false"
INHIBIT_SLEEP="true"
MIN_FREE_GB="10"         # marge d'espace libre exigée en plus de l'estimation

# ── CD audio (gabarits au format cyanrip) ─────────────────────────────────
MUSIC_DIR_TEMPLATE="{album_artist}/{album}"
MUSIC_FILE_TEMPLATE="{track} - {title}"
CD_READ_OFFSET=""        # décalage du lecteur en échantillons (vide = 0)

# ── SACD (image ISO ou serveur réseau sacd_extract) ───────────────────────
SACD_FORMAT="flac"       # flac (PCM 24 bits) | dsf | wavpack (DSD sans perte)
                         # en --silent : toujours wavpack
SACD_CHANNELS="stereo"   # stereo | multi | both
FLAC_LEVEL="8"
EOF
}

encbd_apply_defaults() {
  : "${MAKEMKVCON_BIN:=}"
  : "${X264_BIN:=x264}"
  : "${FFMPEG_BIN:=ffmpeg}"
  : "${MKVMERGE_BIN:=mkvmerge}"
  : "${MKVEXTRACT_BIN:=mkvextract}"
  : "${FZF_BIN:=fzf}"
  : "${CYANRIP_BIN:=cyanrip}"
  : "${SACD_EXTRACT_BIN:=sacd_extract}"
  : "${WAVPACK_BIN:=wavpack}"
  : "${RIP_BACKEND:=auto}"
  [[ -n "${NAME_TEMPLATE:-}" ]] || NAME_TEMPLATE='{title} ({year})'
  : "${ONLINE_LOOKUP:=true}"
  : "${TMDB_API_KEY:=}"
  : "${TMDB_LANGUAGE:=fr-FR}"
  : "${STEREO_LAYOUT:=tab}"
  : "${SBS_MODE:=half}"
  : "${ENCODER:=x264}"
  : "${X264_PRESET:=slow}"
  : "${X264_CRF:=22}"
  # '=' (sans ':') : une valeur vide dans la config est respectée
  : "${X264_EXTRA_OPTS=--aq-mode 3 --bframes 6}"
  : "${VAAPI_DEVICE:=/dev/dri/renderD128}"
  : "${VAAPI_QP:=20}"
  : "${VAAPI_EXTRA_OPTS=-profile:v high -rc_mode CQP -quality 0}"
  : "${DEINTERLACE:=auto}"
  : "${MIN_PLAYLIST_MINUTES:=40}"
  : "${AUDIO_MAX_CHANNELS:=2}"
  : "${KEEP_INTERMEDIATES:=false}"
  : "${INHIBIT_SLEEP:=true}"
  : "${MIN_FREE_GB:=10}"
  [[ -n "${MUSIC_DIR_TEMPLATE:-}" ]] || MUSIC_DIR_TEMPLATE='{album_artist}/{album}'
  [[ -n "${MUSIC_FILE_TEMPLATE:-}" ]] || MUSIC_FILE_TEMPLATE='{track} - {title}'
  : "${CD_READ_OFFSET:=}"
  : "${SACD_FORMAT:=flac}"
  : "${SACD_CHANNELS:=stereo}"
  : "${FLAC_LEVEL:=8}"
}

encbd_load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    encbd_default_config > "$CONFIG_FILE"
    echo "Configuration par défaut écrite dans $CONFIG_FILE"
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  encbd_apply_defaults
}

find_tool() {   # <valeur de la config> <nom> <repli>
  local override="$1" name="$2" fallback="$3"
  if [[ -n "$override" ]]; then echo "$override"; return; fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  echo "$fallback"
}

# Les options CLI sont appliquées APRÈS la config, sinon elle les écraserait.
apply_cli_overrides() {
  if [[ ${#CLI_OVERRIDES[@]} -eq 0 ]]; then return 0; fi
  local kv
  for kv in "${CLI_OVERRIDES[@]}"; do
    declare -g "${kv%%=*}=${kv#*=}"
  done
}

validate_settings() {
  case "$STEREO_LAYOUT" in sbs|tab) ;; *) die_code "$EXIT_USAGE" "layout : sbs ou tab attendu (reçu '$STEREO_LAYOUT')" ;; esac
  case "$SBS_MODE" in full|half) ;; *) die_code "$EXIT_USAGE" "taille : full ou half attendu (reçu '$SBS_MODE')" ;; esac
  case "$ENCODER" in x264|vaapi) ;; *) die_code "$EXIT_USAGE" "encodeur : x264 ou vaapi attendu (reçu '$ENCODER')" ;; esac
  if ! [[ "$AUDIO_MAX_CHANNELS" =~ ^[0-9]+$ ]]; then
    die_code "$EXIT_USAGE" "--max-channels : entier positif attendu (reçu '$AUDIO_MAX_CHANNELS')"
  fi
}

print_encoder_settings() {
  if [[ "$ENCODER" == "x264" ]]; then
    echo "Encodage : x264 preset=$X264_PRESET crf=$X264_CRF extra=\"$X264_EXTRA_OPTS\""
  else
    echo "Encodage : vaapi qp=$VAAPI_QP extra=\"$VAAPI_EXTRA_OPTS\""
  fi
}

# ─── Sélections interactives (fzf) ───────────────────────────────────────────
fzf_pick() {   # <en-tête> <hauteur> <choix...> → choix sur stdout (vide si annulé)
  local header="$1" height="$2"; shift 2
  printf '%s\n' "$@" | "$FZF_BIN" --header="$header" --height="$height" --border --layout=reverse || true
}

pick_stereo_settings() {
  local choice
  choice="$(fzf_pick "Disposition 3D (actuelle : $STEREO_LAYOUT)" '~20%' sbs tab)"
  if [[ -n "$choice" ]]; then STEREO_LAYOUT="$choice"; fi
  choice="$(fzf_pick "Taille par œil (actuelle : $SBS_MODE)" '~20%' full half)"
  if [[ -n "$choice" ]]; then SBS_MODE="$choice"; fi
}

pick_encoder_settings() {
  local choice
  choice="$(fzf_pick "Encodeur (actuel : $ENCODER)" '~20%' x264 vaapi)"
  if [[ -n "$choice" ]]; then ENCODER="$choice"; fi

  if [[ "$ENCODER" == "x264" ]]; then
    choice="$(fzf_pick "Preset x264 (actuel : $X264_PRESET)" '~40%' \
      ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)"
    if [[ -n "$choice" ]]; then X264_PRESET="$choice"; fi
    read -rp "CRF x264 [$X264_CRF] : " choice
    if [[ -n "$choice" ]]; then X264_CRF="$choice"; fi
    read -rp "Options x264 supplémentaires ('-' pour vider) [$X264_EXTRA_OPTS] : " choice
    if [[ "$choice" == "-" ]]; then X264_EXTRA_OPTS=""; elif [[ -n "$choice" ]]; then X264_EXTRA_OPTS="$choice"; fi
  else
    read -rp "QP VAAPI [$VAAPI_QP] : " choice
    if [[ -n "$choice" ]]; then VAAPI_QP="$choice"; fi
    read -rp "Options ffmpeg supplémentaires ('-' pour vider) [$VAAPI_EXTRA_OPTS] : " choice
    if [[ "$choice" == "-" ]]; then VAAPI_EXTRA_OPTS=""; elif [[ -n "$choice" ]]; then VAAPI_EXTRA_OPTS="$choice"; fi
  fi
}

pick_many() {   # <invite> <lignes id|codec|lang|desc...>
  local prompt="$1"; shift
  if [[ $# -eq 0 ]]; then return 0; fi
  printf '%s\n' "NONE|(aucune)|--|--" "$@" | "$FZF_BIN" --multi \
    --delimiter='|' --with-nth=2,3,4 \
    --bind 'load:select-all' --bind 'ctrl-a:toggle-all+first' \
    --header="$prompt  [tout est sélectionné - tab : une piste, ctrl-a : toutes, entrée : valider]" \
    --height='~40%' --border --layout=reverse | awk -F'|' '$1 != "NONE"'
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

# stdin : lignes id|codec|lang|desc ; filtre selon --lang (ex : fra,eng)
filter_lang() {
  if [[ -z "$LANG_FILTER" ]]; then cat; return 0; fi
  awk -F'|' -v langs=",${LANG_FILTER}," 'index(langs, "," $3 ",")'
}

# ─── Divers ──────────────────────────────────────────────────────────────────
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

duration_to_seconds() {
  awk -F: '{ s=0; for (i=1;i<=NF;i++) s = s*60 + $i; print int(s) }' <<<"$1"
}

seconds_to_hms() {
  printf '%d:%02d:%02d' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 ))
}

# Nom de fichier sûr : « / » et caractères de contrôle remplacés, pas de point initial.
sanitize_filename() {
  local s="$1"
  s="${s//\//-}"
  s="$(tr -d '\000-\037' <<<"$s")"
  s="${s#"${s%%[![:space:].]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Supprime un dossier de travail seulement s'il porte bien le suffixe attendu.
safe_remove_dir() {   # <dossier> <suffixe>
  case "$1" in
    *"$2") rm -rf -- "$1" ;;
    *) msg_warn "Dossier inattendu, non supprimé : $1" ;;
  esac
}

# ─── Anti-veille (X11 et Wayland) ────────────────────────────────────────────
# Chaque inhibiteur (systemd-inhibit, kde-inhibit, gnome-session-inhibit) tient son verrou
# tant que la commande qu'il enveloppe tourne. On l'enveloppe donc autour d'un « gardien »
# qui surveille le PID du script : même après un SIGKILL, le verrou saute en quelques secondes.
INHIBIT_PIDS=()
INHIBIT_ACTIVE=()

_inhibit_with() {   # <nom> <commande-inhibiteur...>
  local name="$1"; shift
  env LD_LIBRARY_PATH="$(encbd_host_ld)" "$@" \
    bash -c 'while kill -0 "$1" 2>/dev/null; do sleep "$2"; done' _ "$$" "${INHIBIT_POLL:-5}" \
    >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    INHIBIT_PIDS+=("$pid")
    INHIBIT_ACTIVE+=("$name")
  fi
}

stop_inhibit() {
  if [[ ${#INHIBIT_PIDS[@]} -gt 0 ]]; then kill "${INHIBIT_PIDS[@]}" 2>/dev/null || true; fi
  INHIBIT_PIDS=()
}

# Vrai s'il y a une session graphique (Wayland ou X11) ET un bus de session D-Bus.
_has_desktop_session() {
  [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] || return 1
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" || -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]]
}

start_inhibit() {   # [raison]
  local why="${1:-Traitement vidéo en cours (encbd)}"
  if [[ ${#INHIBIT_PIDS[@]} -gt 0 ]]; then return 0; fi   # déjà actif
  # Couche système (logind) : veille + mise en veille sur inactivité. Indépendant du bureau.
  if command -v systemd-inhibit >/dev/null 2>&1; then
    _inhibit_with systemd-inhibit systemd-inhibit --what=sleep:idle --who=encbd --why="$why" --mode=block
  fi
  # Couche bureau (extinction de l'écran, verrouillage) : Wayland comme X11.
  # Ignorée hors session graphique (TTY, ssh, cron) : ces outils ont besoin du bus D-Bus de session.
  if _has_desktop_session; then
    if command -v kde-inhibit >/dev/null 2>&1; then
      _inhibit_with kde-inhibit kde-inhibit --power --screenSaver --
    elif command -v gnome-session-inhibit >/dev/null 2>&1; then
      _inhibit_with gnome-session-inhibit gnome-session-inhibit --inhibit idle:suspend --reason "$why"
    fi
  fi

  if [[ ${#INHIBIT_ACTIVE[@]} -eq 0 ]]; then
    msg_warn "Aucun inhibiteur de veille n'a pu être activé : la machine peut se mettre en veille."
    return 0
  fi
  encbd_add_exit_hook stop_inhibit
  echo "🔒 [INFO] Mise en veille inhibée (${INHIBIT_ACTIVE[*]})"
}
