#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
# build.sh — compile les dépendances (VapourSynth R65, tsMuxeR, mvc-source) puis
# assemble l'AppImage autonome "encbd.appimage" (encbd.sh + encbd3d.sh).
#
# Fusion de build_deps.sh et make_appimage.sh.
# Utilisable sur toute distribution : les prérequis manquants sont listés
# (avec les noms de paquets apt / dnf / pacman / zypper) avant toute compilation.
#
# Correctif principal par rapport à make_appimage.sh : l'AppImage embarquait le
# `vspipe` du paquet pip « vapoursynth » (version récente dont VSScript cherche
# Python via un fichier de config créé par `vapoursynth config`), mélangé avec
# les libs R65 compilées et un venv dont l'interpréteur pointait vers /usr/bin.
# Ici on embarque UNIQUEMENT la copie R65 compilée, avec sa libpython, la
# bibliothèque standard Python, le module `vapoursynth` et un PYTHONHOME propre.
# Un auto-test (`--selftest`) valide l'ensemble avant et après le packaging.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="encbd"
MAIN_SCRIPT="$SCRIPT_DIR/encbd.sh"
SCRIPT_3D="$SCRIPT_DIR/encbd3d.sh"
LIB_SRC_DIR="$SCRIPT_DIR/lib"
OUTPUT="$SCRIPT_DIR/encbd.appimage"
APPDIR="$SCRIPT_DIR/encbd.AppDir"
CACHE_DIR="$SCRIPT_DIR/.cache"
ARCH="$(uname -m)"
JOBS="$(nproc)"

VS_DIR="$SCRIPT_DIR/vapoursynth"
TSMUXER_DIR="$SCRIPT_DIR/tsMuxer"
MVC_DIR="$SCRIPT_DIR/mvc-source"
EDGE264_DIR="$SCRIPT_DIR/edge264-mvc"
VS_PIN_TAG="R65"     # tag VapourSynth attendu (voir check_pins)

APPIMAGETOOL_URLS=(
  "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH.AppImage"
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
)

# Options (modifiées par parse_args)
FORCE=false
CHECK_ONLY=false
INIT_SOURCES=false
DO_DEPS=true
DO_APPIMAGE=true
KEEP_APPDIR=false
TARGETS=()

# ─── Affichage ───────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
else
  C_RED=""; C_YEL=""; C_BLU=""; C_RST=""
fi

step() { echo "${C_BLU}==>${C_RST} $*"; }
info() { echo "    $*"; }
warn() { echo "${C_YEL}ATTENTION :${C_RST} $*" >&2; }
die()  { echo "${C_RED}ERREUR :${C_RST} $*" >&2; exit 1; }

trap 'echo -e "\n${C_RED}❌ build.sh interrompu ligne $LINENO : $BASH_COMMAND${C_RST}" >&2' ERR

usage() {
  cat <<EOF
Usage : $0 [options] [cible...]

Sans cible : compile les dépendances puis génère l'AppImage.
Avec cible(s) (vapoursynth | tsmuxer | mvc-source) : compile seulement celles-ci.

Options :
  --force           Compile même si une version système existe (VapourSynth, tsMuxeR)
  --check           Vérifie les prérequis puis s'arrête
  --init-sources    Enregistre et récupère les sous-modules listés dans .gitmodules
                    (VapourSynth épinglé sur $VS_PIN_TAG), puis s'arrête
  --deps-only       Compile les dépendances sans générer l'AppImage
  --appimage-only   Génère l'AppImage à partir de ce qui est déjà compilé
  --output FICHIER  Fichier de sortie (défaut : $OUTPUT)
  --script FICHIER  Script principal à embarquer (défaut : $MAIN_SCRIPT ;
                    encbd3d.sh et lib/ sont toujours embarqués à côté)
  --keep-appdir     Conserve le dossier AppDir après génération
  -h, --help        Cette aide
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=true ;;
      --check) CHECK_ONLY=true ;;
      --init-sources) INIT_SOURCES=true ;;
      --deps-only) DO_APPIMAGE=false ;;
      --appimage-only) DO_DEPS=false ;;
      --keep-appdir) KEEP_APPDIR=true ;;
      --output) [[ $# -ge 2 ]] || die "--output attend un argument"; OUTPUT="$2"; shift ;;
      --script) [[ $# -ge 2 ]] || die "--script attend un argument"; MAIN_SCRIPT="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      vapoursynth|tsmuxer|mvc-source) TARGETS+=("$1") ;;
      *) die "Option ou cible inconnue : $1 (voir --help)" ;;
    esac
    shift
  done

  if [[ ${#TARGETS[@]} -gt 0 ]]; then
    DO_APPIMAGE=false      # cibles explicites = compilation seule
  else
    TARGETS=(vapoursynth tsmuxer mvc-source)
  fi
  if [[ "$DO_DEPS" == false && "$DO_APPIMAGE" == false ]]; then
    die "--appimage-only et --deps-only/cibles sont incompatibles"
  fi
}

# ─── Détection de la distribution et table des paquets ──────────────────────
PKG_FAMILY="unknown"
DISTRO_NAME="inconnue"

detect_distro() {
  local id="" like=""
  if [[ -r /etc/os-release ]]; then
    id="$(. /etc/os-release; echo "${ID:-}")"
    like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
    DISTRO_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-$id}")"
  fi
  case " $id $like " in
    *" debian "*|*" ubuntu "*) PKG_FAMILY=apt ;;
    *" fedora "*|*" rhel "*|*" centos "*) PKG_FAMILY=dnf ;;
    *" arch "*) PKG_FAMILY=pacman ;;
    *" suse "*|*" opensuse "*|*" sles "*) PKG_FAMILY=zypper ;;
  esac
  if [[ "$PKG_FAMILY" == "unknown" ]]; then
    if command -v apt-get >/dev/null 2>&1; then PKG_FAMILY=apt
    elif command -v dnf >/dev/null 2>&1; then PKG_FAMILY=dnf
    elif command -v pacman >/dev/null 2>&1; then PKG_FAMILY=pacman
    elif command -v zypper >/dev/null 2>&1; then PKG_FAMILY=zypper
    fi
  fi
}

# clé | apt | dnf | pacman | zypper
PKG_TABLE='
cc|build-essential|gcc|gcc|gcc
cxx|build-essential|gcc-c++|gcc|gcc-c++
make|make|make|make|make
autoconf|autoconf|autoconf|autoconf|autoconf
automake|automake|automake|automake|automake
libtool|libtool|libtool|libtool|libtool
pkgconf|pkg-config|pkgconf-pkg-config|pkgconf|pkg-config
cmake|cmake|cmake|cmake|cmake
python3|python3|python3|python|python3
pydev|python3-dev|python3-devel|python|python3-devel
cython|cython3|python3-Cython|cython|python3-Cython
zimg|libzimg-dev|zimg-devel|zimg|zimg-devel
zlib|zlib1g-dev|zlib-devel|zlib|zlib-devel
freetype|libfreetype-dev|freetype-devel|freetype2|freetype2-devel
x264|x264|x264|x264|x264
ffmpeg|ffmpeg|ffmpeg|ffmpeg|ffmpeg
mkvmerge|mkvtoolnix|mkvtoolnix|mkvtoolnix-cli|mkvtoolnix
fzf|fzf|fzf|fzf|fzf
libaacs|libaacs0|libaacs|libaacs|libaacs0
libbdplus|libbdplus0|libbdplus|libbdplus|libbdplus0
libdvdcss|libdvd-pkg|libdvdcss|libdvdcss|libdvdcss2
cyanrip|cyanrip|cyanrip|cyanrip|cyanrip
wavpack|wavpack|wavpack|wavpack|wavpack
wget|wget|wget|wget|wget
ldd|libc-bin|glibc-common|glibc|glibc
'

pkg_name() {
  local key="$1" col
  case "$PKG_FAMILY" in
    apt) col=2 ;; dnf) col=3 ;; pacman) col=4 ;; zypper) col=5 ;;
    *) echo "$key"; return 0 ;;
  esac
  awk -F'|' -v k="$key" -v c="$col" '$1 == k { print $c }' <<<"$PKG_TABLE"
}

install_cmd() {
  case "$PKG_FAMILY" in
    apt) echo "sudo apt install" ;;
    dnf) echo "sudo dnf install" ;;
    pacman) echo "sudo pacman -S --needed" ;;
    zypper) echo "sudo zypper install" ;;
  esac
}

# ─── Vérification des prérequis ──────────────────────────────────────────────
declare -A NEED_SEEN=()
MISSING_ITEMS=()
MISSING_KEYS=()

add_missing() {   # <clé-paquet> <description>
  MISSING_ITEMS+=("$2")
  if [[ -z "${NEED_SEEN[$1]:-}" ]]; then
    NEED_SEEN[$1]=1
    MISSING_KEYS+=("$1")
  fi
}

require_cmd() {   # <commande> <clé-paquet> <usage>
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  add_missing "$2" "commande '$1' — $3"
}

require_pc() {    # <module pkg-config> <clé-paquet> <usage>
  if ! command -v pkg-config >/dev/null 2>&1; then return 0; fi   # déjà signalé par require_cmd
  if pkg-config --exists "$1"; then return 0; fi
  add_missing "$2" "bibliothèque de développement '$1' — $3"
}

want_target() {
  local t
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    if [[ "$t" == "$1" ]]; then return 0; fi
  done
  return 1
}

system_tsmuxer() {
  command -v tsMuxeR 2>/dev/null || true
}

system_vapoursynth() {
  local vspipe_path
  vspipe_path="$(command -v vspipe 2>/dev/null || true)"
  if [[ -n "$vspipe_path" ]] && ldconfig -p 2>/dev/null | grep -q 'libvapoursynth\.so'; then
    echo "$vspipe_path"
  fi
}

need_build_vapoursynth() {
  # L'AppImage embarque toujours la copie épinglée R65 : un vspipe système récent
  # exige `vapoursynth config` et n'est pas relocalisable (symptôme constaté).
  if [[ "$FORCE" == true || "$DO_APPIMAGE" == true ]]; then return 0; fi
  [[ -z "$(system_vapoursynth)" ]]
}

need_build_tsmuxer() {
  [[ "$FORCE" == true || -z "$(system_tsmuxer)" ]]
}

check_base_tools() {
  local t
  for t in awk sed grep find; do
    command -v "$t" >/dev/null 2>&1 || die "Outil de base '$t' introuvable : installez-le puis relancez."
  done
}

check_sources() {
  local d missing=()
  if want_target vapoursynth && need_build_vapoursynth; then [[ -d "$VS_DIR" ]] || missing+=("vapoursynth"); fi
  if want_target tsmuxer && need_build_tsmuxer; then [[ -d "$TSMUXER_DIR" ]] || missing+=("tsMuxer"); fi
  if want_target mvc-source; then
    [[ -d "$MVC_DIR" ]] || missing+=("mvc-source")
    [[ -d "$EDGE264_DIR" ]] || missing+=("edge264-mvc")
  fi
  if [[ "$DO_DEPS" == false ]]; then missing=(); fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    for d in "${missing[@]}"; do echo "  - dossier manquant : $SCRIPT_DIR/$d" >&2; done
    if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
       && [[ -z "$(git -C "$SCRIPT_DIR" ls-files --stage | awk '$1 == "160000"')" ]]; then
      echo >&2
      echo "Le dépôt a un .gitmodules mais aucun sous-module enregistré dans son index :" >&2
      echo "« git submodule update » n'a donc rien à récupérer." >&2
      die "Lancez : ./build.sh --init-sources   (puis validez avec git commit)"
    fi
    die "Sources absentes. Lancez : ./build.sh --init-sources"
  fi
  if [[ "$DO_APPIMAGE" == true ]]; then
    [[ -f "$MAIN_SCRIPT" ]] || die "Script principal introuvable : $MAIN_SCRIPT (option --script)"
    [[ -f "$SCRIPT_3D" ]] || die "Script 3D introuvable : $SCRIPT_3D"
    [[ -f "$SCRIPT_DIR/LICENSE" && -f "$SCRIPT_DIR/THIRD_PARTY_LICENSES" ]] \
      || die "LICENSE ou THIRD_PARTY_LICENSES manquant : ils sont obligatoires dans l'AppImage distribuée."
    [[ -f "$LIB_SRC_DIR/encbd-common.sh" && -f "$LIB_SRC_DIR/encbd-helper.py" ]] \
      || die "Bibliothèque incomplète dans $LIB_SRC_DIR (encbd-common.sh, encbd-helper.py)"
  fi
}

# .gitmodules ne fixe que l'URL : la version est le commit enregistré dans le dépôt parent.
check_pins() {
  local cur head
  if ! command -v git >/dev/null 2>&1 || [[ ! -d "$VS_DIR" ]]; then return 0; fi
  cur="$(git -C "$VS_DIR" describe --tags --exact-match 2>/dev/null || true)"
  head="$(git -C "$VS_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ "$cur" == "$VS_PIN_TAG" ]]; then
    info "vapoursynth : $cur (conforme)"
  else
    warn "vapoursynth est sur ${cur:-un commit sans tag ($head)}, attendu $VS_PIN_TAG."
    warn "Pour épingler : git -C vapoursynth checkout $VS_PIN_TAG && git add vapoursynth && git commit"
  fi
}

check_build_tools() {
  if want_target vapoursynth && need_build_vapoursynth; then
    require_cmd g++ cxx "compilateur C++ (VapourSynth)"
    require_cmd make make "make"
    require_cmd autoreconf autoconf "autoconf (VapourSynth)"
    require_cmd automake automake "automake (VapourSynth)"
    require_cmd libtoolize libtool "libtool (VapourSynth)"
    require_cmd pkg-config pkgconf "pkg-config"
    require_cmd python3 python3 "Python 3"
    require_pc python3-embed pydev "en-têtes Python (VSScript)"
    require_pc zimg zimg "zimg : filtre core.resize (indispensable pour les modes half/tab)"
    if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import Cython' 2>/dev/null; then
      add_missing cython "module Python 'Cython' — génération du module vapoursynth"
    fi
  fi
  if want_target tsmuxer && need_build_tsmuxer; then
    require_cmd cmake cmake "cmake (tsMuxer)"
    require_cmd g++ cxx "compilateur C++ (tsMuxer)"
    require_cmd make make "make"
    require_cmd pkg-config pkgconf "pkg-config"
    require_pc zlib zlib "zlib (tsMuxer)"
    require_pc freetype2 freetype "freetype (tsMuxer)"
  fi
  if want_target mvc-source; then
    require_cmd gcc cc "compilateur C (mvc-source / edge264)"
    require_cmd make make "make"
  fi
}

# Outils facultatifs : leur absence désactive une fonction, sans bloquer la génération.
OPTIONAL_TOOLS=(cyanrip sacd_extract wavpack)
# Bibliothèques chargées par dlopen (invisibles pour ldd) : libbluray → libaacs/libbdplus,
# libdvdread → libdvdcss. Embarquées explicitement, facultatives.
DLOPEN_LIBS=(libaacs.so.0 libbdplus.so.0 libdvdcss.so.2)

find_shared_lib() {   # <soname> → chemin, vide si absente
  ldconfig -p 2>/dev/null | awk -v n="$1" '$1 == n { print $NF; exit }'
}

check_runtime_tools() {
  local enc t lib list
  require_cmd x264 x264 "encodeur x264 à embarquer"
  require_cmd ffmpeg ffmpeg "ffmpeg à embarquer"
  require_cmd mkvmerge mkvmerge "mkvmerge à embarquer"
  require_cmd mkvextract mkvmerge "mkvextract à embarquer (chapitres des MKV 3D)"
  require_cmd fzf fzf "fzf à embarquer"
  if command -v ffmpeg >/dev/null 2>&1; then
    enc="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
    if ! grep -q h264_vaapi <<<"$enc"; then
      warn "ffmpeg n'expose pas h264_vaapi : le mode --encoder vaapi ne fonctionnera pas dans l'AppImage."
    fi
    list="$(ffmpeg -hide_banner -protocols 2>/dev/null || true)"
    grep -qw bluray <<<"$list" || warn "ffmpeg sans protocole bluray (libbluray) : pas de repli libaacs pour les Blu-ray."
    list="$(ffmpeg -hide_banner -demuxers 2>/dev/null || true)"
    grep -qw dvdvideo <<<"$list" || warn "ffmpeg sans démuxeur dvdvideo (ffmpeg ≥ 7) : les DVD exigeront MakeMKV."
    list="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
    grep -qw zscale <<<"$list" || warn "ffmpeg sans filtre zscale : la conversion HDR → SDR des UHD sera impossible."
  fi
  for t in "${OPTIONAL_TOOLS[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      case "$t" in
        cyanrip) warn "cyanrip absent ($(install_cmd) $(pkg_name cyanrip)) : CD audio non pris en charge par l'AppImage." ;;
        sacd_extract) warn "sacd_extract absent (https://github.com/sacd-ripper/sacd-ripper, à compiler) : SACD non pris en charge." ;;
        wavpack) warn "wavpack absent ($(install_cmd) $(pkg_name wavpack)) : format SACD wavpack (et mode --silent SACD) indisponible." ;;
      esac
    fi
  done
  for lib in "${DLOPEN_LIBS[@]}"; do
    if [[ -z "$(find_shared_lib "$lib")" ]]; then
      case "$lib" in
        libaacs*) warn "$lib absente ($(install_cmd) $(pkg_name libaacs)) : pas de repli libaacs pour les Blu-ray." ;;
        libbdplus*) warn "$lib absente ($(install_cmd) $(pkg_name libbdplus)) : BD+ non géré par le repli libaacs." ;;
        libdvdcss*) warn "$lib absente ($(install_cmd) $(pkg_name libdvdcss)) : DVD chiffrés impossibles sans MakeMKV." ;;
      esac
    fi
  done
}

check_packaging_tools() {
  require_cmd ldd ldd "analyse des dépendances des binaires"
  require_cmd python3 python3 "lecture de la bibliothèque standard Python"
  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    add_missing wget "wget ou curl — téléchargement d'appimagetool"
  fi
}

report_missing() {
  if [[ ${#MISSING_ITEMS[@]} -eq 0 ]]; then
    info "Tous les prérequis sont présents."
    return 0
  fi

  local item key pkgs=()
  echo >&2
  echo "${C_RED}Prérequis manquants :${C_RST}" >&2
  for item in "${MISSING_ITEMS[@]}"; do echo "  - $item" >&2; done

  for key in "${MISSING_KEYS[@]}"; do pkgs+=("$(pkg_name "$key")"); done
  echo >&2
  if [[ "$PKG_FAMILY" == "unknown" ]]; then
    echo "Distribution non reconnue : installez l'équivalent de : ${pkgs[*]}" >&2
  else
    echo "Installation suggérée ($DISTRO_NAME) :" >&2
    echo "  $(install_cmd) ${pkgs[*]}" >&2
  fi
  case "$PKG_FAMILY" in
    dnf) echo "Note : x264 et ffmpeg complets viennent de RPM Fusion." >&2 ;;
    zypper) echo "Note : x264 et ffmpeg complets viennent du dépôt Packman." >&2 ;;
  esac
  exit 1
}

check_prerequisites() {
  step "Vérification des prérequis (distribution : $DISTRO_NAME, gestionnaire : $PKG_FAMILY)"
  check_base_tools
  check_sources
  if [[ "$DO_DEPS" == true ]]; then check_pins; check_build_tools; fi
  if [[ "$DO_APPIMAGE" == true ]]; then
    check_runtime_tools
    check_packaging_tools
  fi
  report_missing
}

# ─── Récupération des sources (sous-modules) ────────────────────────────────
# Un .gitmodules seul ne suffit pas : git ne récupère un sous-module que s'il est
# aussi enregistré dans l'index (entrée « gitlink », mode 160000). C'est le cas
# quand les fichiers ont été copiés dans un dépôt neuf : on les ajoute alors.
init_sources() {
  command -v git >/dev/null 2>&1 || die "git est nécessaire pour récupérer les sous-modules."
  git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$SCRIPT_DIR n'est pas un dépôt git (lancez d'abord : git init)."
  [[ -f "$SCRIPT_DIR/.gitmodules" ]] || die "$SCRIPT_DIR/.gitmodules introuvable."

  local key name path url
  while read -r key path; do
    name="${key#submodule.}"; name="${name%.path}"
    url="$(git -C "$SCRIPT_DIR" config -f .gitmodules "submodule.$name.url")"
    if git -C "$SCRIPT_DIR" ls-files --stage -- "$path" | awk '$1 == "160000"' | grep -q .; then
      step "Sous-module $path : déjà enregistré, mise à jour"
      git -C "$SCRIPT_DIR" submodule update --init --recursive -- "$path"
    else
      if [[ -e "$SCRIPT_DIR/$path" && -n "$(ls -A "$SCRIPT_DIR/$path" 2>/dev/null)" ]]; then
        die "$path existe déjà et n'est pas vide : déplacez-le, puis relancez --init-sources."
      fi
      step "Sous-module $path : ajout ($url)"
      git -C "$SCRIPT_DIR" submodule add --force "$url" "$path"
      git -C "$SCRIPT_DIR" submodule update --init --recursive -- "$path"
    fi
  done < <(git -C "$SCRIPT_DIR" config -f "$SCRIPT_DIR/.gitmodules" --get-regexp '^submodule\..*\.path$')

  if [[ -d "$VS_DIR" ]]; then
    step "VapourSynth : épinglage sur $VS_PIN_TAG"
    git -C "$VS_DIR" fetch --tags --quiet origin || warn "Récupération des tags VapourSynth impossible."
    git -C "$VS_DIR" -c advice.detachedHead=false checkout --quiet "$VS_PIN_TAG" \
      || die "Tag $VS_PIN_TAG introuvable dans $VS_DIR."
    git -C "$SCRIPT_DIR" add "$(basename "$VS_DIR")"
  fi

  step "Sous-modules prêts. Pour les enregistrer dans le dépôt :"
  info "git commit -m \"Sous-modules : edge264-mvc, mvc-source, vapoursynth $VS_PIN_TAG, tsMuxer\""
}

# ─── Compilation des dépendances (ex build_deps.sh) ─────────────────────────
build_vapoursynth() {
  if ! need_build_vapoursynth; then
    info "VapourSynth système trouvé ($(system_vapoursynth)) — compilation ignorée (--force pour forcer)."
    info "Note : le projet épingle R65 (API V4) ; un paquet antérieur à R63 ne chargera pas mvc-source."
    return 0
  fi
  (
    cd "$VS_DIR"
    [[ -x ./configure ]] || ./autogen.sh
    [[ -f Makefile ]] || ./configure
    make -j"$JOBS"
  )
}

build_tsmuxer() {
  if ! need_build_tsmuxer; then
    info "tsMuxeR système trouvé ($(system_tsmuxer)) — compilation ignorée (--force pour forcer)."
    return 0
  fi
  ( cd "$TSMUXER_DIR" && ./scripts/rebuild_linux.sh )
}

build_mvc_source() {
  ( cd "$MVC_DIR" && make libvsmvc.so EDGE264_SRC="$EDGE264_DIR" EDGE264_MAKE="CFLAGS=-fPIC" -j"$JOBS" )
}

build_dependencies() {
  local t
  for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    step "Compilation : $t"
    case "$t" in
      vapoursynth) build_vapoursynth ;;
      tsmuxer) build_tsmuxer ;;
      mvc-source) build_mvc_source ;;
    esac
  done
}

# ─── Outils communs au packaging ─────────────────────────────────────────────
is_elf() {
  [[ -f "$1" && "$(head -c 4 "$1" 2>/dev/null | tail -c 3)" == "ELF" ]]
}

download() {   # <url> <fichier>
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$out" "$url"
  else
    curl -fL --progress-bar -o "$out" "$url"
  fi
}

# Bibliothèques laissées à l'hôte : glibc, pile graphique/VAAPI (liée au pilote de la
# machine), libstdc++/libgcc. Le reste est embarqué.
EXCLUDE_LIBS_RE='^(ld-linux.*|linux-vdso.*|libc|libm|libdl|libpthread|librt|libutil|libresolv|libnsl|libanl|libBrokenLocale|libnss_.*|libthread_db|libmvec|libcrypt|libstdc\+\+|libgcc_s|libGL|libGLX|libGLdispatch|libOpenGL|libEGL|libGLESv2|libgbm|libdrm.*|libva.*|libvdpau|libwayland-.*|libnvidia-.*|libcuda|libnvcuvid)\.so'

is_excluded_lib() {
  [[ "$1" =~ $EXCLUDE_LIBS_RE ]]
}

declare -A UNRESOLVED_LIBS=()

# Origine de chaque fichier copié depuis la machine de compilation : sert à relever
# les paquets, versions et licences embarqués (ai_collect_licenses).
declare -A BUNDLED_ORIGINS=()
record_origin() { BUNDLED_ORIGINS["$1"]=1; }

# Copie dans $LIB_DIR les dépendances dynamiques de <elf>. ldd est déjà transitif.
bundle_libs_of() {   # <elf> [chemin de recherche supplémentaire]
  local elf="$1" ldp="${2:-}" line name arrow path base
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then ldp="${ldp:+$ldp:}$LD_LIBRARY_PATH"; fi
  while IFS= read -r line; do
    read -r name arrow path _ <<<"$line"
    [[ "$arrow" == "=>" ]] || continue
    if [[ "$path" == "not" ]]; then UNRESOLVED_LIBS["$name"]=1; continue; fi
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    if is_excluded_lib "$base"; then continue; fi
    if [[ -e "$LIB_DIR/$base" ]]; then continue; fi
    cp -L "$path" "$LIB_DIR/$base"
    record_origin "$path"
  done < <(LD_LIBRARY_PATH="$ldp" ldd "$elf" 2>/dev/null || true)
}

# ─── Packaging : localisation des artefacts ─────────────────────────────────
VS_LIBS_DIR=""; VSPIPE_SRC=""; VS_MODULE_SRC=""; TSMUXER_SRC=""; MVC_PLUGIN_SRC=""

resolve_artifacts() {
  step "Localisation des artefacts compilés"

  VS_LIBS_DIR="$VS_DIR/.libs"
  VSPIPE_SRC="$VS_LIBS_DIR/vspipe"
  if ! is_elf "$VSPIPE_SRC"; then
    die "vspipe R65 introuvable ($VSPIPE_SRC). Lancez d'abord : ./build.sh vapoursynth"
  fi
  local candidates
  candidates="$(find "$VS_LIBS_DIR" -maxdepth 1 -type f -name 'vapoursynth*.so*' 2>/dev/null || true)"
  if [[ -z "$candidates" ]]; then
    candidates="$(find "$VS_DIR" -maxdepth 4 -type f -name 'vapoursynth*.so*' ! -name 'libvapoursynth*' 2>/dev/null || true)"
  fi
  VS_MODULE_SRC="$(head -n1 <<<"$candidates")"
  if [[ -n "$candidates" && "$(wc -l <<<"$candidates")" -gt 1 ]]; then
    warn "Plusieurs modules Python vapoursynth trouvés, retenu : $VS_MODULE_SRC"
  fi
  if [[ -z "$VS_MODULE_SRC" ]]; then
    die "Module Python 'vapoursynth' introuvable dans $VS_DIR (Cython absent au configure ?). Installez Cython puis : (cd vapoursynth && make clean) && ./build.sh vapoursynth"
  fi

  if [[ -x "$TSMUXER_DIR/bin/tsMuxeR" ]]; then TSMUXER_SRC="$TSMUXER_DIR/bin/tsMuxeR"
  elif [[ -x "$TSMUXER_DIR/bin/tsMuxer" ]]; then TSMUXER_SRC="$TSMUXER_DIR/bin/tsMuxer"
  else TSMUXER_SRC="$(system_tsmuxer)"
  fi
  if [[ -z "$TSMUXER_SRC" ]]; then die "tsMuxeR introuvable. Lancez d'abord : ./build.sh tsmuxer"; fi

  MVC_PLUGIN_SRC="$MVC_DIR/libvsmvc.so"
  if [[ ! -f "$MVC_PLUGIN_SRC" ]]; then die "libvsmvc.so introuvable. Lancez d'abord : ./build.sh mvc-source"; fi

  info "vspipe        : $VSPIPE_SRC"
  info "module python : $VS_MODULE_SRC"
  info "tsMuxeR       : $TSMUXER_SRC"
  info "plugin mvc    : $MVC_PLUGIN_SRC"
}

# ─── Packaging : AppDir ──────────────────────────────────────────────────────
BIN_DIR=""; LIB_DIR=""; PY_HOME=""; PY_VER=""; PY_BIN=""; PY_STDLIB_DEST=""; MAIN_NAME=""

ai_prepare_appdir() {
  step "Création de l'AppDir : $APPDIR"
  rm -rf "$APPDIR"
  BIN_DIR="$APPDIR/usr/bin"
  LIB_DIR="$APPDIR/usr/lib"
  PY_HOME="$APPDIR/usr/python"
  MAIN_NAME="$(basename "$MAIN_SCRIPT")"
  mkdir -p "$BIN_DIR/mvc-source" "$LIB_DIR" "$PY_HOME/lib"
}

# Version de Python contre laquelle libvapoursynth-script est liée, puis interpréteur
# correspondant (pour lire sa bibliothèque standard).
ai_detect_python() {
  step "Détection du Python lié à VapourSynth"
  local ldd_out cand v
  ldd_out="$(LD_LIBRARY_PATH="$VS_LIBS_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$VSPIPE_SRC" 2>&1 || true)"
  PY_VER="$(grep -oE 'libpython3\.[0-9]+' <<<"$ldd_out" | head -n1 | sed 's/^libpython//')" || true
  if [[ -z "$PY_VER" ]]; then
    warn "vspipe n'affiche pas de dépendance libpython : repli sur la version de python3."
    PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  fi

  PY_BIN=""
  for cand in "python$PY_VER" python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
      v="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
      if [[ "$v" == "$PY_VER" ]]; then PY_BIN="$(command -v "$cand")"; break; fi
    fi
  done
  if [[ -z "$PY_BIN" ]]; then
    die "VapourSynth est lié à Python $PY_VER mais aucun interpréteur python$PY_VER n'est installé (sa bibliothèque standard est à embarquer)."
  fi
  info "Python $PY_VER ($PY_BIN)"
}

ai_bundle_python() {
  step "Python $PY_VER embarqué (bibliothèque standard + extensions C)"
  local stdlib platstdlib
  stdlib="$("$PY_BIN" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
  platstdlib="$("$PY_BIN" -c 'import sysconfig; print(sysconfig.get_path("platstdlib"))')"
  PY_STDLIB_DEST="$PY_HOME/lib/python$PY_VER"

  mkdir -p "$PY_STDLIB_DEST"
  cp -a "$stdlib/." "$PY_STDLIB_DEST/"
  record_origin "$stdlib/os.py"
  # Fedora/SUSE : les extensions (lib-dynload) vivent dans lib64 → on fusionne.
  if [[ "$platstdlib" != "$stdlib" && -d "$platstdlib" ]]; then
    cp -a "$platstdlib/." "$PY_STDLIB_DEST/"
  fi

  if [[ ! -f "$PY_STDLIB_DEST/os.py" || ! -d "$PY_STDLIB_DEST/encodings" ]]; then
    die "Bibliothèque standard Python incomplète dans $stdlib (paquet python3-libs / python3-stdlib manquant ?)"
  fi
  if [[ ! -d "$PY_STDLIB_DEST/lib-dynload" ]]; then
    warn "Pas de lib-dynload dans la copie de la stdlib : certains modules C seront indisponibles."
  fi

  # Allègement : paquets système, tests, IDE, Tk, curses, dbm…
  rm -rf "$PY_STDLIB_DEST"/{site-packages,dist-packages,test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
         "$PY_STDLIB_DEST"/config-* "$PY_STDLIB_DEST"/turtle.py
  find "$PY_STDLIB_DEST" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$PY_STDLIB_DEST/lib-dynload" -type f \( -name '_tkinter*' -o -name '_curses*' -o -name '_dbm*' -o -name '_gdbm*' \) -delete 2>/dev/null || true
  mkdir -p "$PY_STDLIB_DEST/site-packages"

  # Dépendances natives des extensions C (libffi, libz, libexpat, libssl…).
  local so
  while IFS= read -r so; do
    bundle_libs_of "$so"
  done < <(find "$PY_STDLIB_DEST/lib-dynload" -type f -name '*.so' 2>/dev/null)

  # Interpréteur embarqué : exécute encbd-helper.py et sert à diagnostiquer
  # (./encbd.appimage --python -c "import vapoursynth")
  mkdir -p "$PY_HOME/bin"
  install -m 755 "$(readlink -f "$PY_BIN")" "$PY_HOME/bin/python3"
  record_origin "$(readlink -f "$PY_BIN")"
  bundle_libs_of "$(readlink -f "$PY_BIN")"
}

ai_bundle_vapoursynth() {
  step "VapourSynth R65 : vspipe, bibliothèques, module Python, plugin mvc"
  install -m 755 "$VSPIPE_SRC" "$BIN_DIR/vspipe"
  cp -a "$VS_LIBS_DIR"/libvapoursynth*.so* "$LIB_DIR/"
  install -m 644 "$VS_MODULE_SRC" "$PY_STDLIB_DEST/site-packages/$(basename "$VS_MODULE_SRC")"

  bundle_libs_of "$VSPIPE_SRC" "$VS_LIBS_DIR"                  # libpython, zimg, …
  bundle_libs_of "$VS_MODULE_SRC" "$VS_LIBS_DIR"

  install -m 755 "$MVC_PLUGIN_SRC" "$BIN_DIR/mvc-source/libvsmvc.so"
  bundle_libs_of "$MVC_PLUGIN_SRC"
}

bundle_tool() {   # <commande>
  local tool="$1" path
  path="$(readlink -f "$(command -v "$tool")")"
  if ! is_elf "$path"; then
    warn "$tool ($path) n'est pas un binaire ELF (script/wrapper ?) : copié tel quel, portabilité non garantie."
  fi
  install -m 755 "$path" "$BIN_DIR/$tool"
  record_origin "$path"
  bundle_libs_of "$path"
}

ai_bundle_tools() {
  step "Outils : tsMuxeR, x264, ffmpeg, mkvmerge, mkvextract, fzf (+ facultatifs)"
  install -m 755 "$TSMUXER_SRC" "$BIN_DIR/tsMuxeR"
  bundle_libs_of "$TSMUXER_SRC"

  local tool lib path
  for tool in x264 ffmpeg mkvmerge mkvextract fzf; do bundle_tool "$tool"; done
  for tool in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then bundle_tool "$tool"; info "facultatif embarqué : $tool"; fi
  done

  # Bibliothèques dlopen : copiées sous leur soname, avec leurs propres dépendances.
  for lib in "${DLOPEN_LIBS[@]}"; do
    path="$(find_shared_lib "$lib")"
    if [[ -n "$path" ]]; then
      cp -L "$path" "$LIB_DIR/$lib"
      record_origin "$path"
      bundle_libs_of "$path"
      info "bibliothèque dlopen embarquée : $lib"
    fi
  done
}

ai_bundle_script() {
  step "Scripts : $MAIN_NAME, $(basename "$SCRIPT_3D"), lib/"
  install -m 755 "$MAIN_SCRIPT" "$BIN_DIR/$MAIN_NAME"
  install -m 755 "$SCRIPT_3D" "$BIN_DIR/$(basename "$SCRIPT_3D")"
  mkdir -p "$BIN_DIR/lib"
  install -m 644 "$LIB_SRC_DIR/encbd-common.sh" "$BIN_DIR/lib/encbd-common.sh"
  install -m 755 "$LIB_SRC_DIR/encbd-helper.py" "$BIN_DIR/lib/encbd-helper.py"
}

ai_report_unresolved() {
  local lib
  if [[ ${#UNRESOLVED_LIBS[@]} -eq 0 ]]; then return 0; fi
  warn "Bibliothèques introuvables sur la machine de build (non embarquées) :"
  for lib in "${!UNRESOLVED_LIBS[@]}"; do echo "    - $lib" >&2; done
}

ai_write_apprun() {
  step "AppRun"
  sed -e "s|@PY_VER@|$PY_VER|g" -e "s|@MAIN@|$MAIN_NAME|g" > "$APPDIR/AppRun" <<'APPRUN_EOF'
#!/usr/bin/env bash
# AppRun — point d'entrée de l'AppImage (@MAIN@)
set -euo pipefail

APPDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export APPDIR

export PATH="$APPDIR/usr/bin:$PATH"
# LD_LIBRARY_PATH d'origine : rendu aux programmes de l'hôte (makemkvcon, udisksctl,
# systemd-inhibit, kde-inhibit…). HOME et XDG_CONFIG_HOME ne sont JAMAIS modifiés :
# ~/.MakeMKV/settings.conf (clé MakeMKV), ~/.config/aacs/KEYDB.cfg et ~/.config/encbd.conf
# restent lus là où l'utilisateur les a mis.
export ENCBD_HOST_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export ENCBD3D_HOST_LD_LIBRARY_PATH="$ENCBD_HOST_LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Python embarqué + chemin non-ASCII (ex : « Vidéos ») : sans locale UTF-8 (env -i, cron,
# ssh, sudo…), l'import des modules C échoue ("surrogates not allowed") et VSScript répond
# « Failed to initialize VSScript ». PYTHONUTF8 ne suffit pas : il faut une vraie locale.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

# Python embarqué (chargé par libvapoursynth-script à l'intérieur de vspipe).
export PYTHONHOME="$APPDIR/usr/python"
export PYTHONPATH="$APPDIR/usr/python/lib/python@PY_VER@/site-packages"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1        # le squashfs est en lecture seule
unset PYTHONSTARTUP PYTHONEXECUTABLE PYTHONPLATLIBDIR PYTHONUSERBASE VIRTUAL_ENV

PY="$APPDIR/usr/python/bin/python3"
export ENCBD_PYTHON="$PY"
export ENCBD_LIB_DIR="$APPDIR/usr/bin/lib"
export ENCBD3D_SCRIPT="$APPDIR/usr/bin/encbd3d.sh"

# Certificats TLS de l'hôte pour le Python embarqué (TheDiscDB, TMDb).
if [[ -z "${SSL_CERT_FILE:-}" ]]; then
  for _ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
             /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    if [[ -r "$_ca" ]]; then export SSL_CERT_FILE="$_ca"; break; fi
  done
fi

export TSMUXER_BIN="$APPDIR/usr/bin/tsMuxeR"
export VSPIPE_BIN="$APPDIR/usr/bin/vspipe"
export MVC_SOURCE_PLUGIN="$APPDIR/usr/bin/mvc-source/libvsmvc.so"

selftest() {
  local tmp out t fails=0
  tmp="$(mktemp -d)"
  echo "== auto-diagnostic (APPDIR=$APPDIR) =="

  for t in x264 ffmpeg mkvmerge mkvextract fzf; do
    if "$t" --version >/dev/null 2>&1 || "$t" -version >/dev/null 2>&1; then
      echo "  [ OK ] $t"
    else
      echo "  [FAIL] $t ne démarre pas (bibliothèque manquante ?)"; fails=$((fails + 1))
    fi
  done

  # Outils facultatifs (CD audio, SACD) : absents = fonction désactivée, pas un échec.
  for t in cyanrip sacd_extract wavpack; do
    if [[ ! -x "$APPDIR/usr/bin/$t" ]]; then
      echo "  [ -- ] $t non embarqué (fonction correspondante indisponible)"
    elif out="$("$t" -V 2>&1 || "$t" --version 2>&1 || "$t" --help 2>&1 || true)"; \
         grep -qiE 'error while loading|not found' <<<"$out"; then
      echo "  [FAIL] $t ne démarre pas : ${out:0:200}"; fails=$((fails + 1))
    else
      echo "  [ OK ] $t"
    fi
  done

  if out="$("$PY" "$ENCBD_LIB_DIR/encbd-helper.py" clean-label "AVATAR_3D_FR" 2>&1)" && [[ "$out" == "Avatar" ]] \
     && "$PY" -c 'import ssl, urllib.request, json, csv' 2>/dev/null; then
    echo "  [ OK ] assistant Python (encbd-helper.py, ssl)"
  else
    echo "  [FAIL] assistant Python : $out"; fails=$((fails + 1))
  fi

  out="$(ffmpeg -hide_banner -protocols 2>/dev/null || true)"
  if grep -qw bluray <<<"$out"; then echo "  [ OK ] ffmpeg : protocole bluray"; else echo "  [ -- ] ffmpeg sans protocole bluray (repli libaacs indisponible)"; fi
  out="$(ffmpeg -hide_banner -demuxers 2>/dev/null || true)"
  if grep -qw dvdvideo <<<"$out"; then echo "  [ OK ] ffmpeg : démuxeur dvdvideo"; else echo "  [ -- ] ffmpeg sans démuxeur dvdvideo (DVD : MakeMKV requis)"; fi

  for t in libaacs.so.0 libdvdcss.so.2; do
    if "$PY" -c "import ctypes, sys; ctypes.CDLL(sys.argv[1])" "$t" 2>/dev/null; then
      echo "  [ OK ] $t chargeable"
    else
      echo "  [ -- ] $t non chargeable (repli sans MakeMKV limité)"
    fi
  done
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/aacs/KEYDB.cfg" ]]; then
    echo "  [ OK ] KEYDB.cfg présent"
  else
    echo "  [ -- ] ${XDG_CONFIG_HOME:-$HOME/.config}/aacs/KEYDB.cfg absent (Blu-ray AACS : MakeMKV requis)"
  fi

  # makemkvcon : celui de l'hôte, lancé avec le LD_LIBRARY_PATH de l'hôte.
  if command -v makemkvcon >/dev/null 2>&1; then
    echo "  [ OK ] makemkvcon (hôte) : $(command -v makemkvcon)"
    if grep -qs '^[[:space:]]*app_Key' "$HOME/.MakeMKV/settings.conf"; then
      echo "  [ OK ] clé MakeMKV présente dans ~/.MakeMKV/settings.conf"
    else
      echo "  [ -- ] pas de ligne app_Key dans ~/.MakeMKV/settings.conf (version d'essai ou clé à saisir)"
    fi
  else
    echo "  [ -- ] makemkvcon absent : Blu-ray via libaacs uniquement, 3D encodée en 2D"
  fi

  out="$(tsMuxeR 2>&1 || true)"
  if ! grep -qiE 'not found|error while loading' <<<"$out" && grep -qi 'version' <<<"$out"; then
    echo "  [ OK ] tsMuxeR"
  else
    echo "  [FAIL] tsMuxeR ne démarre pas : ${out:0:200}"; fails=$((fails + 1))
  fi

  if [[ -x "$PY" ]]; then
    if out="$("$PY" -c 'import vapoursynth as vs; print("R%d" % vs.core.version_number())' 2>&1)"; then
      echo "  [ OK ] Python embarqué + module vapoursynth ($out)"
    else
      echo "  [FAIL] import vapoursynth (Python embarqué) :"
      sed 's/^/           /' <<<"$out"
      fails=$((fails + 1))
    fi
  fi

  cat > "$tmp/t.vpy" <<'PYEOF'
import os, sys
import vapoursynth as vs
app = os.environ["APPDIR"]
assert sys.prefix.startswith(app), "Python hors AppImage : " + sys.prefix
assert vs.__file__.startswith(app), "module vapoursynth hors AppImage : " + vs.__file__
core = vs.core
core.std.LoadPlugin(os.environ["MVC_SOURCE_PLUGIN"])
assert hasattr(core, "mvc"), "plugin mvc non chargé"
clip = core.std.BlankClip(width=128, height=64, length=2)
clip = core.resize.Bicubic(clip, width=64)
clip = core.std.StackVertical([clip, clip])
clip.set_output()
PYEOF
  if out="$(vspipe --info "$tmp/t.vpy" 2>&1)" && grep -q '^Width: 64' <<<"$out"; then
    echo "  [ OK ] vspipe + Python embarqué + core.resize + plugin mvc"
  else
    echo "  [FAIL] vspipe : $out"; fails=$((fails + 1))
    echo "         dernières lignes de la trace d'imports Python (PYTHONVERBOSE=2) :"
    PYTHONVERBOSE=2 vspipe --info "$tmp/t.vpy" 2>&1 | tail -n 30 | sed 's/^/           /' || true
  fi

  if [[ -e /dev/dri/renderD128 ]]; then
    echo "  [ OK ] /dev/dri/renderD128 présent (VAAPI possible)"
  else
    echo "  [ -- ] pas de /dev/dri/renderD128 : utilisez --encoder x264"
  fi

  rm -rf "$tmp"
  [[ $fails -eq 0 ]]
}

case "${1:-}" in
  --selftest) rc=0; selftest || rc=$?; exit "$rc" ;;
  3d)         shift; exec "$APPDIR/usr/bin/encbd3d.sh" "$@" ;;   # encbd3d.sh directement
  --python)   shift; exec "$PY" "$@" ;;                       # Python embarqué
  --licenses) cat "$APPDIR/usr/share/licenses/THIRD_PARTY_LICENSES" "$APPDIR/usr/share/licenses/SOURCES.txt"; exit 0 ;;
  --run)      shift; exec "$@" ;;                             # commande dans l'environnement de l'AppImage
  --shell)    exec "${SHELL:-/bin/bash}" ;;                   # shell dans cet environnement
esac

exec "$APPDIR/usr/bin/@MAIN@" "$@"
APPRUN_EOF
  chmod +x "$APPDIR/AppRun"
}

# ─── Packaging : licences des composants embarqués ──────────────────────────
# Paquet propriétaire d'un fichier : « nom version », vide si inconnu.
owning_package() {   # <fichier>
  local f="$1" alt cand pkg=""
  local cands=("$f" "$(readlink -f "$f")")
  alt="${f#/usr}"; [[ "$alt" != "$f" ]] && cands+=("$alt")
  for cand in "${cands[@]}"; do
    case "$PKG_FAMILY" in
      apt)
        pkg="$(dpkg -S "$cand" 2>/dev/null | head -n1 | cut -d: -f1 | cut -d, -f1 || true)"
        if [[ -n "$pkg" ]]; then echo "$pkg $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"; return; fi ;;
      dnf|zypper)
        pkg="$(rpm -qf --qf '%{NAME} %{VERSION}-%{RELEASE}\n' "$cand" 2>/dev/null | head -n1 || true)"
        if [[ -n "$pkg" && "$pkg" != *"not owned"* ]]; then echo "$pkg"; return; fi ;;
      pacman)
        pkg="$(pacman -Qqo "$cand" 2>/dev/null | head -n1 || true)"
        if [[ -n "$pkg" ]]; then pacman -Q "$pkg" 2>/dev/null; return; fi ;;
    esac
  done
}

# Copie les fichiers de licence d'un paquet dans <dossier>.
copy_package_licenses() {   # <paquet> <dossier>
  local pkg="$1" dest="$2" f
  mkdir -p "$dest"
  case "$PKG_FAMILY" in
    apt) [[ -f "/usr/share/doc/$pkg/copyright" ]] && cp -L "/usr/share/doc/$pkg/copyright" "$dest/" ;;
    dnf|zypper) while IFS= read -r f; do [[ -f "$f" ]] && cp -L "$f" "$dest/"; done < <(rpm -qL "$pkg" 2>/dev/null || true) ;;
    pacman) [[ -d "/usr/share/licenses/$pkg" ]] && cp -rL "/usr/share/licenses/$pkg/." "$dest/" ;;
  esac
  [[ -n "$(ls -A "$dest" 2>/dev/null)" ]] || rmdir "$dest" 2>/dev/null || true
}

submodule_rev() {   # <dossier>
  git -C "$1" rev-parse --short=12 HEAD 2>/dev/null || echo "inconnu"
}

ai_collect_licenses() {
  step "Licences des composants embarqués"
  local lic="$APPDIR/usr/share/licenses" src pkgline pkg unknown_count=0
  declare -A seen_pkg=()
  mkdir -p "$lic/encbd"
  install -m 644 "$SCRIPT_DIR/LICENSE" "$lic/encbd/LICENSE"
  install -m 644 "$SCRIPT_DIR/THIRD_PARTY_LICENSES" "$lic/THIRD_PARTY_LICENSES"
  if [[ -d "$SCRIPT_DIR/licenses" ]]; then cp -a "$SCRIPT_DIR/licenses/." "$lic/encbd/"; fi

  # Sous-modules compilés : leurs propres fichiers de licence.
  local name dir file
  for name in edge264-mvc mvc-source vapoursynth tsMuxer; do
    dir="$SCRIPT_DIR/$name"
    mkdir -p "$lic/$name"
    for file in LICENSE LICENSE_BSD.txt LICENSE.md COPYING COPYING.LESSER COPYING.LGPLv2.1; do
      [[ -f "$dir/$file" ]] && cp -L "$dir/$file" "$lic/$name/"
    done
    [[ -n "$(ls -A "$lic/$name")" ]] || { warn "Aucun fichier de licence trouvé dans $dir"; rmdir "$lic/$name"; }
  done

  {
    echo "# Composants de encbd.appimage et leur origine (généré par build.sh le $(date -u +%Y-%m-%d))"
    echo "# Distribution de compilation : $DISTRO_NAME"
    echo
    echo "## Compilés depuis les sous-modules (source : commit indiqué)"
    for name in edge264-mvc mvc-source vapoursynth tsMuxer; do
      printf '%-14s %s\n' "$name" "$(submodule_rev "$SCRIPT_DIR/$name")"
    done
    echo
    echo "## Copiés depuis la machine de compilation : fichier → paquet version"
    while IFS= read -r src; do
      pkgline="$(owning_package "$src")"
      if [[ -n "$pkgline" ]]; then
        printf '%s\t%s\n' "$src" "$pkgline"
        pkg="${pkgline%% *}"
        if [[ -z "${seen_pkg[$pkg]:-}" ]]; then
          seen_pkg[$pkg]=1
          copy_package_licenses "$pkg" "$lic/$pkg"
        fi
      else
        printf '%s\t%s\n' "$src" "paquet inconnu (installé hors gestionnaire de paquets)"
        unknown_count=$((unknown_count + 1))
      fi
    done < <(printf '%s\n' "${!BUNDLED_ORIGINS[@]}" | sort)
  } > "$lic/SOURCES.txt"

  info "$(( ${#seen_pkg[@]} )) paquet(s) relevé(s), licences copiées dans usr/share/licenses/"
  if [[ "$unknown_count" -gt 0 ]]; then
    warn "$unknown_count fichier(s) embarqué(s) sans paquet identifiable (voir usr/share/licenses/SOURCES.txt) :"
    warn "ajoutez leur licence et l'adresse de leur source à la main avant de distribuer l'AppImage."
  fi
}

ai_write_metadata() {
  step "Métadonnées (desktop + icône)"
  cat > "$APPDIR/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Blu-ray, Blu-ray 3D et DVD vers MKV ; CD audio et SACD vers FLAC
Exec=$MAIN_NAME
Icon=$APP_NAME
Categories=AudioVideo;Video;
Terminal=true
EOF

  cat > "$APPDIR/$APP_NAME.svg" <<'SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="40" fill="#1f2a44"/>
  <rect x="28" y="72" width="96" height="112" rx="8" fill="#4da3ff"/>
  <rect x="132" y="72" width="96" height="112" rx="8" fill="#ff5a5a"/>
  <text x="128" y="226" font-family="sans-serif" font-size="32" font-weight="bold"
        text-anchor="middle" fill="#ffffff">encbd</text>
</svg>
SVG_EOF
}

# ─── Packaging : tests et image finale ──────────────────────────────────────
ai_selftest_appdir() {
  step "Auto-test de l'AppDir (environnement vidé)"
  if ! env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" TERM="${TERM:-dumb}" "$APPDIR/AppRun" --selftest; then
    die "L'auto-test a échoué : l'AppDir est conservé dans $APPDIR pour inspection."
  fi
}

APPIMAGETOOL=""

ai_fetch_appimagetool() {
  step "appimagetool"
  APPIMAGETOOL="$CACHE_DIR/appimagetool-$ARCH.AppImage"
  if [[ -x "$APPIMAGETOOL" ]]; then info "déjà présent : $APPIMAGETOOL"; return 0; fi

  mkdir -p "$CACHE_DIR"
  local url
  for url in "${APPIMAGETOOL_URLS[@]}"; do
    info "téléchargement : $url"
    if download "$url" "$APPIMAGETOOL.part"; then
      mv "$APPIMAGETOOL.part" "$APPIMAGETOOL"
      chmod +x "$APPIMAGETOOL"
      return 0
    fi
    rm -f "$APPIMAGETOOL.part"
  done
  die "Téléchargement d'appimagetool impossible (réseau ?). Placez-le manuellement dans : $APPIMAGETOOL"
}

ai_build_image() {
  step "Génération de $OUTPUT"
  rm -f "$OUTPUT"
  ARCH="$ARCH" "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUTPUT"
  chmod +x "$OUTPUT"
}

ai_selftest_image() {
  step "Auto-test de l'AppImage finale"
  if ! APPIMAGE_EXTRACT_AND_RUN=1 "$OUTPUT" --selftest; then
    warn "L'AppImage a été produite mais son auto-test échoue (voir ci-dessus)."
    return 1
  fi
}

make_appimage() {
  resolve_artifacts
  ai_prepare_appdir
  ai_detect_python
  ai_bundle_python
  ai_bundle_vapoursynth
  ai_bundle_tools
  ai_bundle_script
  ai_report_unresolved
  ai_collect_licenses
  ai_write_apprun
  ai_write_metadata
  ai_selftest_appdir
  ai_fetch_appimagetool
  ai_build_image
  ai_selftest_image || true
  if [[ "$KEEP_APPDIR" != true ]]; then rm -rf "$APPDIR"; fi
  step "Terminé : $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
}

# ─── Programme principal ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  detect_distro
  if [[ "$INIT_SOURCES" == true ]]; then init_sources; return 0; fi
  check_prerequisites
  if [[ "$CHECK_ONLY" == true ]]; then
    step "Mode --check : rien à compiler."
    return 0
  fi
  if [[ "$DO_DEPS" == true ]]; then build_dependencies; fi
  if [[ "$DO_APPIMAGE" == true ]]; then make_appimage; fi
  step "Terminé."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
