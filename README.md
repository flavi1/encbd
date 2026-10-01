# encbd

`encbd` transforme un disque en fichiers nommés, prêts pour une médiathèque :

| Disque | Résultat |
| --- | --- |
| Blu-ray, DVD | un MKV encodé (x264 ou VAAPI) |
| Blu-ray 3D (MVC) | un MKV côte à côte (SBS) ou haut-bas (TAB), via `encbd3d.sh` |
| CD audio | un FLAC par piste, étiqueté (MusicBrainz), avec pochette et `.cue` |
| SACD (image ISO) | FLAC 24 bits, DSF ou WavPack DSD sans perte |

Tout est livré dans une seule AppImage, `encbd.appimage`. MakeMKV n'y est pas embarqué : c'est celui de la machine qui est utilisé.

```bash
./encbd.appimage /dev/sr0 ~/Vidéos
```

Si la destination est un dossier existant, le nom du film est résolu automatiquement, par exemple `~/Vidéos/Avatar (2009).mkv` ou `~/Vidéos/Avatar (2009).tab.mkv` en 3D. Sinon, la destination est le chemin exact du fichier, utilisé tel quel.

## Utilisation

```text
encbd.appimage [options] <source> <destination>
```

**Source** : un lecteur (`/dev/sr0`), une image `.iso`, un dossier contenant `BDMV/` ou `VIDEO_TS/`, ou l'adresse `IP:PORT` d'un serveur `sacd_extract`.

| Option | Effet |
| --- | --- |
| `-s`, `--silent` | aucune question ; chaque choix suit une règle fixe (voir plus bas) |
| `--dry-run` | affiche la détection et le plan, sans rien écrire |
| `--title "NOM"`, `--year AAAA` | impose le nom et l'année |
| `--playlist N` | impose le titre : playlist (`800`, `00800.mpls`), titre MakeMKV ou titre DVD |
| `--no-online` | ni TheDiscDB, ni TMDb, ni MusicBrainz |
| `--rip-backend auto\|makemkv\|libaacs` | force le moteur de déchiffrement |
| `--lang fra,eng` | pistes audio et sous-titres à garder |
| `--max-channels N` | canaux audio maximum (2 = stéréo, 0 = sans limite) |
| `--layout sbs\|tab`, `--sbs full\|half` | disposition 3D |
| `--encoder x264\|vaapi`, `--preset`, `--crf`, `--qp`, `--x264-opts`, `--vaapi-opts` | réglages d'encodage |
| `--config`, `--workdir`, `--keep-intermediates`, `--no-inhibit` | configuration, dossier de travail, conservation des fichiers intermédiaires, anti-veille |

Exemples :

```bash
# Voir ce qui serait fait, sans rien lancer
./encbd.appimage --dry-run /dev/sr0 ~/Vidéos

# Traitement automatique, pistes françaises seulement
./encbd.appimage --silent --lang fra /dev/sr0 ~/Vidéos

# Nom imposé, fichier précis
./encbd.appimage --title "Mon film" /dev/sr0 "/media/nas/films/Mon film.mkv"

# CD audio
./encbd.appimage /dev/sr0 ~/Musique

# encbd3d.sh directement, sur un dossier BDMV déjà déchiffré
./encbd.appimage 3d ~/rips/AVATAR
```

### Déroulé

1. **Sonde** : le disque est monté en lecture seule (udisks, sans droits root) et son type est reconnu : Blu-ray, UHD, DVD, CD, ou présence de `BDMV/STREAM/SSIF/` pour la 3D.
2. **Identification** du nom et du titre principal, sans rien déchiffrer.
3. **Contrôle de l'espace disque**.
4. **Rip** du titre principal en MKV, par MakeMKV ou par libaacs / libdvdcss.
5. **Encodage** : en 3D, délégué à `encbd3d.sh` ; sinon fait directement (désentrelacement automatique des DVD, conversion HDR vers SDR des UHD), puis multiplexage avec mkvmerge.
6. **Nettoyage** : le MKV intermédiaire est supprimé. En cas d'échec, le dossier de travail est conservé et les étapes déjà faites sont réutilisées au lancement suivant.

La mise en veille est empêchée pendant tout le traitement (logind, KDE ou GNOME).

### Résolution du nom

Les sources sont essayées dans cet ordre :

1. `--title` ;
2. TheDiscDB, une base communautaire qui reconnaît le disque par une empreinte de ses fichiers ;
3. le titre de l'éditeur (`BDMV/META/DL/bdmt_fra.xml`) ;
4. le label du volume, nettoyé (`AVATAR_3D_FR` donne « Avatar ») ;
5. TMDb, si une clé est configurée, pour le titre localisé et l'année ;
6. la saisie manuelle (proposée pré-remplie en mode interactif).

**Titre principal** : celui désigné par TheDiscDB, ce qui déjoue les playlists leurres. À défaut, c'est le plus long d'au moins `MIN_PLAYLIST_MINUTES` minutes.

### Mode `--silent`

| Choix | Règle |
| --- | --- |
| Nom | première source disponible ; TMDb seulement si le résultat est unique ou identique |
| Titre principal | TheDiscDB, sinon le plus long |
| Pistes | toutes, filtrées par `--lang` et `AUDIO_MAX_CHANNELS` |
| Réglages | ceux de `encbd.conf` et de la ligne de commande |
| Blu-ray 3D sans MakeMKV | encodage en 2D, avec le message `ATTENTION : LE DISQUE EST EN 3D MAIS MAKEMKVCON EST INTROUVABLE. IL SERA ENCODÉ EN 2D !` |
| CD sans correspondance MusicBrainz unique | première édition, sinon « Artiste inconnu / Album inconnu » |
| SACD | toujours WavPack (DSD sans perte), quel que soit `SACD_FORMAT` |

## Ce qu'il faut sur la machine

| Disque | Requis | Sans cela |
| --- | --- | --- |
| Blu-ray | MakeMKV (`makemkvcon`) ; à défaut, `~/.config/aacs/KEYDB.cfg` | repli libaacs : seulement les disques présents dans KEYDB, pas de BD+, pas de 3D |
| Blu-ray 3D | MakeMKV | encodé en 2D, avec avertissement |
| UHD (4K) | MakeMKV et un lecteur compatible LibreDrive | arrêt propre (code 4) |
| DVD | rien (libdvdcss est embarquée) | — |
| CD audio | rien (cyanrip est embarqué) | — |
| SACD | une image ISO (les lecteurs d'ordinateur ne lisent pas la couche SACD) | un SACD hybride se lit comme un CD |

Outils de l'hôte utilisés sans être embarqués : `udisksctl`, `findmnt`, `blkid`, `udevadm`.

### Fichiers lus, jamais modifiés

| Fichier | Rôle |
| --- | --- |
| `~/.MakeMKV/settings.conf` | clé MakeMKV : ligne `app_Key = "T-…"`. C'est la seule source de vérité ; encbd ne la copie pas. |
| `~/.config/aacs/KEYDB.cfg` | clés des Blu-ray pour le repli libaacs |
| `~/.dvdcss/` | cache des clés DVD (créé par libdvdcss) |

L'AppImage ne modifie ni `HOME` ni `XDG_CONFIG_HOME` : ces fichiers sont lus à leur emplacement habituel. Si la clé MakeMKV est absente ou expirée, encbd s'arrête avec le code 5 et indique la ligne à corriger.

## Configuration

Le fichier `~/.config/encbd.conf` est partagé par `encbd.sh` et `encbd3d.sh`. Il est créé avec ses valeurs par défaut au premier lancement ; l'ancien `~/.config/encbd3d/config.sh` n'est pas repris. Les options de la ligne de commande l'emportent sur ce fichier.

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `RIP_BACKEND` | `auto` | `auto` = MakeMKV s'il est installé, sinon libaacs / libdvdcss |
| `MAKEMKVCON_BIN` | vide | chemin de makemkvcon (vide = recherche dans le PATH) |
| `NAME_TEMPLATE` | `{title} ({year})` | nom du fichier ; un `()` vide est retiré |
| `ONLINE_LOOKUP` | `true` | TheDiscDB, TMDb, MusicBrainz |
| `TMDB_API_KEY` | vide | clé TMDb personnelle (v3 ou jeton v4) ; vide = TMDb ignoré |
| `TMDB_LANGUAGE` | `fr-FR` | langue des titres TMDb |
| `STEREO_LAYOUT`, `SBS_MODE` | `tab`, `half` | 3D |
| `ENCODER` | `x264` | `x264` ou `vaapi` |
| `X264_PRESET`, `X264_CRF`, `X264_EXTRA_OPTS` | `slow`, `22`, `--aq-mode 3 --bframes 6` | x264 |
| `VAAPI_DEVICE`, `VAAPI_QP`, `VAAPI_EXTRA_OPTS` | `/dev/dri/renderD128`, `20`, … | VAAPI (options au format ffmpeg) |
| `DEINTERLACE` | `auto` | `auto`, `on`, `off` |
| `MIN_PLAYLIST_MINUTES` | `40` | durée minimale du titre principal |
| `AUDIO_MAX_CHANNELS` | `2` | canaux audio maximum (0 = toutes les pistes) |
| `MIN_FREE_GB` | `10` | marge d'espace libre exigée en plus de l'estimation |
| `KEEP_INTERMEDIATES`, `INHIBIT_SLEEP` | `false`, `true` | conservation des fichiers intermédiaires, anti-veille |
| `MUSIC_DIR_TEMPLATE`, `MUSIC_FILE_TEMPLATE` | `{album_artist}/{album}`, `{track} - {title}` | CD audio (syntaxe cyanrip) |
| `CD_READ_OFFSET` | vide | décalage de lecture du lecteur (voir ci-dessous) |
| `SACD_FORMAT` | `flac` | `flac` (PCM 24 bits), `dsf` ou `wavpack` |
| `SACD_CHANNELS` | `stereo` | `stereo`, `multi` ou `both` |
| `FLAC_LEVEL` | `8` | compression FLAC (SACD) |

**Décalage de lecture du CD** : il est propre à chaque modèle de lecteur. Pour le mesurer, insérez un CD connu d'AccurateRip, lancez `./encbd.appimage --run cyanrip -f -d /dev/sr0`, puis reportez la valeur dans `CD_READ_OFFSET`.

**SACD et « sans perte »** : le SACD stocke du DSD. `flac` le convertit en PCM 24 bits / 88,2 kHz, ce qui est fidèle mais pas identique bit à bit. `dsf` et `wavpack` conservent le DSD tel quel.

## Codes de sortie

| Code | Cause |
| --- | --- |
| 0 | succès, ou fichier final déjà présent |
| 1 | erreur d'usage |
| 2 | prérequis manquant, ou annulation |
| 3 | source illisible (pas de disque, montage impossible) |
| 4 | disque illisible par le moteur (UHD notamment) ou non pris en charge |
| 5 | déchiffrement impossible (clé MakeMKV, KEYDB, BD+) |
| 6 | espace disque insuffisant |
| 7 | échec du rip |
| 8 | échec de l'encodage ou du multiplexage |

L'éjection et l'enchaînement de plusieurs disques ne font pas partie d'encbd : un script appelant l'AppImage s'en charge facilement à partir de ces codes.

## Commandes de l'AppImage

| Commande | Effet |
| --- | --- |
| `encbd.appimage --selftest` | diagnostic : outils embarqués, Python, libaacs, KEYDB, makemkvcon, clé MakeMKV |
| `encbd.appimage 3d …` | lance `encbd3d.sh` directement |
| `encbd.appimage --run CMD …` | lance une commande dans l'environnement de l'AppImage |
| `encbd.appimage --python …` | Python embarqué |
| `encbd.appimage --shell` | shell dans l'environnement de l'AppImage |

## Compilation

```bash
git submodule update --init --recursive
./build.sh --check     # liste les prérequis manquants, avec la commande d'installation
./build.sh             # compile VapourSynth R65, tsMuxeR, mvc-source, puis encbd.appimage
```

`build.sh` embarque `encbd.sh`, `encbd3d.sh`, `lib/`, x264, ffmpeg, mkvmerge, mkvextract, fzf, le Python embarqué et, s'ils sont installés sur la machine de compilation, cyanrip, sacd_extract, wavpack, libaacs, libbdplus et libdvdcss. Une absence est signalée et désactive seulement la fonction correspondante. sacd_extract n'est empaqueté par presque aucune distribution : compilez-le depuis [sacd-ripper](https://github.com/sacd-ripper/sacd-ripper).

## Tests

```bash
python3 -m unittest discover -s tests   # analyse des playlists, nommage, sorties MakeMKV et mkvmerge
tests/run_tests.sh                      # scénarios complets sur de faux disques (python3, ffmpeg avec libx264)
```

Les tests n'ont besoin ni de lecteur ni de MakeMKV : de faux outils (`tests/shims*`) imitent makemkvcon, x264, mkvmerge, sacd_extract et wavpack.

## Fichiers

| Fichier | Rôle |
| --- | --- |
| `encbd.sh` | orchestrateur : sonde, identification, rip, aiguillage |
| `encbd3d.sh` | Blu-ray 3D : tsMuxeR, mvc-source (VapourSynth), assemblage SBS/TAB, encodage |
| `lib/encbd-common.sh` | configuration, anti-veille, sélections fzf, filtres de pistes, codes de sortie |
| `lib/encbd-helper.py` | analyses : playlists MPLS, TheDiscDB, TMDb, sorties MakeMKV et mkvmerge |
| `build.sh` | compilation des dépendances et génération de l'AppImage |

## Mentions

- Données de films : TheDiscDB et TMDb. *This product uses the TMDB API but is not endorsed or certified by TMDB.* L'API TMDb est gratuite pour un usage non commercial ; chaque utilisateur crée sa propre clé.
- Métadonnées musicales : MusicBrainz et Cover Art Archive, via cyanrip.
- En France, la loi DADVSI encadre le contournement des mesures techniques de protection, y compris pour la copie privée. Vous êtes responsable de l'usage que vous faites de cet outil.
