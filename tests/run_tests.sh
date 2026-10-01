#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
# Tests d'intégration d'encbd.sh sur de faux disques (sans lecteur, sans MakeMKV réel).
# Usage : tests/run_tests.sh      Prérequis : bash, python3, ffmpeg (avec libx264).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_CACHE_HOME="$TMP/home/.cache"
mkdir -p "$XDG_CONFIG_HOME"
BASE_PATH="$HERE/shims:/usr/local/bin:/usr/bin:/bin"
CONF="$TMP/encbd.conf"
cat > "$CONF" <<'C'
MIN_FREE_GB="0"
INHIBIT_SLEEP="false"
X264_PRESET="ultrafast"
X264_EXTRA_OPTS=""
DEINTERLACE="off"
C

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && sed 's/^/       | /' <<<"$2"; }
check() { # <nom> <code attendu> <code obtenu> <sortie> [motif attendu]...
  local name="$1" want="$2" got="$3" out="$4"; shift 4
  if [[ "$got" != "$want" ]]; then ko "$name (code $got, attendu $want)" "$out"; return; fi
  local p
  for p in "$@"; do
    if ! grep -qF -- "$p" <<<"$out"; then ko "$name (motif absent : $p)" "$out"; return; fi
  done
  ok "$name"
}
run() { # <PATH> <args...> → sortie dans $OUT, code dans $RC
  local path="$1"; shift
  OUT="$(PATH="$path" bash "$ROOT/encbd.sh" --config "$CONF" "$@" 2>&1)"; RC=$?
}

mkdisc() { # <dossier> <options python>
  python3 -c "
import sys; sys.path.insert(0, '$HERE'); import fixtures
fixtures.make_bdmv('$1', {'00800': [('00001', 6600)], '00001': [('00002', 60)], '00900': [('00003', 2700)]},
                   {'00001': 1000000000, '00002': 1, '00003': 3000000000}, $2)"
}

DEST="$TMP/Videos"; mkdir -p "$DEST"
mkdisc "$TMP/AVATAR_FR" "three_d=False, label_xml=None"
mkdisc "$TMP/FILM_3D_FR_DISC1" "three_d=True, label_xml='Mon film'"
mkdisc "$TMP/UHD" "version='0300'"

echo "== Détection (--dry-run)"
run "$BASE_PATH" --dry-run --silent --no-online "$TMP/AVATAR_FR" "$DEST"
check "Blu-ray 2D sans MakeMKV : repli libaacs, nom depuis le label" 0 "$RC" "$OUT" \
  "Moteur de rip    : libaacs" "Nom              : Avatar  [label du volume (AVATAR_FR)]" \
  "00800.mpls — 1:50:00" "Fichier final    : $DEST/Avatar.mkv"

run "$BASE_PATH" --dry-run --silent --no-online "$TMP/FILM_3D_FR_DISC1" "$DEST"
check "Blu-ray 3D sans MakeMKV : avertissement en majuscules, sortie 2D" 0 "$RC" "$OUT" \
  "LE DISQUE EST EN 3D MAIS MAKEMKVCON EST INTROUVABLE. IL SERA ENCODÉ EN 2D !" \
  "Nom              : Mon film  [métadonnées du disque (bdmt)]" "Fichier final    : $DEST/Mon film.mkv"

run "$HERE/shims-makemkv:$BASE_PATH" --dry-run --silent --no-online --year 2009 "$TMP/FILM_3D_FR_DISC1" "$DEST"
check "Blu-ray 3D avec MakeMKV : délégation 3D, suffixe .tab" 0 "$RC" "$OUT" \
  "Moteur de rip    : makemkv" "Fichier final    : $DEST/Mon film (2009).tab.mkv" "Traitement       : encbd3d.sh, tab half"

run "$HERE/shims-makemkv:$BASE_PATH" --dry-run --silent --no-online --playlist 900 --title "Bonus" "$TMP/AVATAR_FR" "$DEST/autre nom.mkv"
check "--playlist, --title et destination fichier utilisée telle quelle" 0 "$RC" "$OUT" \
  "00900.mpls — 0:45:00" "[option --playlist]" "Fichier final    : $DEST/autre nom.mkv"

run "$BASE_PATH" --dry-run --silent --no-online "$TMP/UHD" "$DEST"
check "UHD avec libaacs : refus propre (code 4)" 4 "$RC" "$OUT" "AACS 2.0"

FAKE_MAKEMKV_MODE=uhdfail run "$HERE/shims-makemkv:$BASE_PATH" --dry-run --silent --no-online "$TMP/UHD" "$DEST"
check "UHD illisible par MakeMKV : échec propre (code 4)" 4 "$RC" "$OUT" "LibreDrive"

FAKE_MAKEMKV_MODE=expired run "$HERE/shims-makemkv:$BASE_PATH" --dry-run --silent --no-online "$TMP/AVATAR_FR" "$DEST"
check "Clé MakeMKV expirée : code 5" 5 "$RC" "$OUT" "clé absente ou expirée" "settings.conf"

run "$BASE_PATH" --silent "$TMP/nexistepas" "$DEST"
check "Source introuvable : code 3" 3 "$RC" "$OUT"

run "$BASE_PATH" --bogus "$TMP/AVATAR_FR" "$DEST"
check "Option inconnue : code 1" 1 "$RC" "$OUT" "Option inconnue"

echo "== Traitement complet 2D (faux MakeMKV, faux x264/mkvmerge)"
run "$HERE/shims-makemkv:$BASE_PATH" --silent --no-online --title "Mon film" --year 2009 "$TMP/AVATAR_FR" "$DEST"
FINAL="$DEST/Mon film (2009).mkv"
if [[ "$RC" -eq 0 && -s "$FINAL" ]]; then
  streams="$(ffprobe -v error -show_entries stream=codec_type,channels -of csv=p=0 "$FINAL" | tr '\n' ' ')"
  if [[ "$streams" == "video audio,1 subtitle "* || "$streams" == "video audio,1 subtitle" ]]; then
    ok "2D : MKV produit, audio filtré (≤ 2 canaux), sous-titres conservés"
  else
    ko "2D : pistes inattendues : $streams" "$OUT"
  fi
  if compgen -G "$DEST/*.encbd" >/dev/null; then ko "2D : dossier de travail non supprimé"; else ok "2D : dossier de travail supprimé"; fi
else
  ko "2D : traitement complet (code $RC)" "$OUT"
fi

run "$HERE/shims-makemkv:$BASE_PATH" --silent --no-online --title "Mon film" --year 2009 "$TMP/AVATAR_FR" "$DEST"
check "Fichier final déjà présent : arrêt immédiat (code 0)" 0 "$RC" "$OUT" "existe déjà"

echo "== Délégation 3D (encbd3d.sh remplacé par un témoin)"
# Un ancien rip sans piste MVC (une seule vidéo) doit être détecté et refait.
OLD="$DEST/Mon film.encbd/rip"; mkdir -p "$OLD"
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i testsrc=size=320x240:rate=25:duration=2 \
  -c:v libx264 -preset ultrafast "$OLD/Film_t01.mkv"; touch "$OLD/.complete"
mkdir -p "$HOME/.MakeMKV"; printf 'app_Key = "T-cle-de-test"\napp_DefaultSelectionString = "-sel:all,-sel:mvcvideo"\n' > "$HOME/.MakeMKV/settings.conf"
cat > "$TMP/encbd3d-temoin.sh" <<'W'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEMOIN_ARGS"
stem=""; prev=""
for a in "$@"; do [[ "$prev" == "--output-stem" ]] && stem="$a"; prev="$a"; done
echo fake > "$stem.tab.mkv"
W
export TEMOIN_ARGS="$TMP/args.txt"
OUT="$(PATH="$HERE/shims-makemkv:$BASE_PATH" ENCBD3D_SCRIPT="$TMP/encbd3d-temoin.sh" \
  bash "$ROOT/encbd.sh" --config "$CONF" --silent --no-online --lang fra "$TMP/FILM_3D_FR_DISC1" "$DEST" 2>&1)"; RC=$?
args="$(tr '\n' ' ' < "$TEMOIN_ARGS" 2>/dev/null || true)"
if [[ "$RC" -eq 0 && -s "$DEST/Mon film.tab.mkv" && "$args" == *"--output-stem $DEST/Mon film "* \
      && "$args" == *"--silent"* && "$args" == *"--lang fra"* && "$args" == *"--no-settings-prompt"* \
      && "$args" == *".mkv --config"* ]]; then
  ok "3D : encbd3d.sh reçoit le MKV ripé, --output-stem, --silent, --lang"
  if [[ "$OUT" == *"ne contient pas l'œil droit"*"nouveau rip"* ]]; then ok "3D : ancien rip sans piste MVC détecté et refait"; else ko "3D : ancien rip sans MVC non détecté" "$OUT"; fi
  if grep -q 'app_DefaultSelectionString = "-sel:all,-sel:mvcvideo"' "$HOME/.MakeMKV/settings.conf" && grep -q 'T-cle-de-test' "$HOME/.MakeMKV/settings.conf"; then
    ok "MakeMKV : règle de sélection forcée via une copie, settings.conf d'origine intact"
  else ko "MakeMKV : settings.conf d'origine modifié"; fi
else
  ko "3D : délégation (code $RC) args=[$args]" "$OUT"
fi

echo "== SACD (image ISO factice)"
python3 -c "
f = open('$TMP/album.iso', 'wb'); f.seek(510 * 2048); f.write(b'SACDMTOC'); f.close()"
run "$BASE_PATH" --silent "$TMP/album.iso" "$DEST"
check "SACD sans sacd_extract : code 2" 2 "$RC" "$OUT" "sacd_extract introuvable"
mkdir -p "$TMP/sacd-shims"
cat > "$TMP/sacd-shims/sacd_extract" <<'S'
#!/usr/bin/env bash
mkdir -p "Artiste - Album"; : > "Artiste - Album/01 - Titre.dsf"; : > "Artiste - Album/02 - Autre.dsf"
S
cat > "$TMP/sacd-shims/wavpack" <<'S'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { : > "$2"; exit 0; }; shift; done; exit 1
S
chmod +x "$TMP/sacd-shims/"*
run "$TMP/sacd-shims:$BASE_PATH" --silent "$TMP/album.iso" "$DEST"
if [[ "$RC" -eq 0 && -f "$DEST/Artiste - Album/01 - Titre.wv" && -f "$DEST/Artiste - Album/02 - Autre.wv" ]]; then
  ok "SACD en --silent : WavPack imposé, arborescence conservée"
else
  ko "SACD en --silent (code $RC)" "$OUT"
fi

echo "== encbd3d.sh"
OUT="$(bash "$ROOT/encbd3d.sh" --help 2>&1)"; RC=$?
check "encbd3d.sh --help (bibliothèque chargée)" 0 "$RC" "$OUT" "--output-stem" "encbd.conf"

# MKV « MakeMKV » : vidéo + une seule piste audio 5.1 + sous-titres (pas de stéréo).
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i testsrc=size=320x240:rate=24000/1001:duration=4 \
  -f lavfi -i sine=frequency=220:duration=4 -i "$HERE/shims-makemkv/sub.srt" \
  -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a6]" -map 0:v -map "[a6]" -map 2:s \
  -c:v libx264 -preset ultrafast -c:a ac3 -c:s srt "$TMP/film3d.mkv"
run3d() { OUT="$(PATH="$BASE_PATH" VSPIPE_BIN="$HERE/shims/vspipe" MVC_SOURCE_PLUGIN=/dev/null \
  bash "$ROOT/encbd3d.sh" --config "$CONF" --silent "$@" 2>&1)"; RC=$?; }

run3d "$TMP/film3d.mkv" --output "$TMP/film-2d.tab.mkv"
check "encbd3d.sh : MKV sans vue MVC refusé (code 4), sans tsMuxeR" 4 "$RC" "$OUT" "ne contient pas de vue MVC" "Mpeg4-MVC-3D"

rm -rf "$TMP/film3d.encbd3d"   # dossier de travail laissé par l'échec précédent
FAKE_MVC=1 run3d "$TMP/film3d.mkv" --title "Film 3D" --output "$TMP/film.tab.mkv"
OUT_COMBINED="$OUT"; RC_COMBINED="$RC"
ffmpeg -hide_banner -loglevel error -nostdin -i "$TMP/film3d.mkv" -map 0:v -map 0:v -map 0:a -map 0:s -c copy "$TMP/deux-vues.mkv"
FAKE_MVC=1 run3d "$TMP/deux-vues.mkv" --output "$TMP/deux-vues.tab.mkv"
check "encbd3d.sh : MKV à deux pistes vidéo (MakeMKV) → vues gauche et droite séparées" 0 "$RC" "$OUT" \
  "Extraction des vues gauche (piste 0) et droite (piste 1)"
OUT="$OUT_COMBINED"; RC="$RC_COMBINED"
if [[ "$RC" -eq 0 && -s "$TMP/film.tab.mkv" ]]; then
  streams="$(ffprobe -v error -show_entries stream=codec_type,channels -of csv=p=0 "$TMP/film.tab.mkv" | tr '\n' ' ')"
  if [[ "$streams" == "video audio,6 subtitle"* && "$OUT" == *"pistes à 6 canaux conservées"* && "$OUT" != *tsMuxeR* ]]; then
    ok "encbd3d.sh : MKV MVC traité sans tsMuxeR, audio 5.1 gardé faute de stéréo, sous-titres repris"
  else
    ko "encbd3d.sh : pistes inattendues : $streams" "$OUT"
  fi
else
  ko "encbd3d.sh : MKV MVC (code $RC)" "$OUT"
fi

echo
echo "Résultat : $PASS réussi(s), $FAIL échec(s)"
[[ "$FAIL" -eq 0 ]]
