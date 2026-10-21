#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
"""encbd-helper.py — tâches d'analyse appelées par encbd.sh.

Uniquement la bibliothèque standard (exécuté par le Python embarqué de l'AppImage).
Chaque sous-commande écrit son résultat sur stdout (champs séparés par des tabulations)
et sort avec 0 en cas de succès, 1 si rien n'a été trouvé ou en cas d'erreur.
"""

import csv
import datetime
import json
import os
import re
import struct
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "encbd/1.0 ( https://github.com/flavi1/encbd )"
NET_TIMEOUT = 8
DISCDB_ORIGIN = "https://thediscdb.com"


# ─── Outils ──────────────────────────────────────────────────────────────────
def out(*fields):
    print("\t".join("" if f is None else str(f).replace("\t", " ").replace("\n", " ") for f in fields))


def listdir_ci(path):
    """Dictionnaire nom-en-minuscules → nom réel (les montages UDF varient sur la casse)."""
    try:
        return {n.lower(): n for n in os.listdir(path)}
    except OSError:
        return {}


def join_ci(base, *parts):
    """Résout un chemin sans tenir compte de la casse ; None si absent."""
    cur = base
    for p in parts:
        names = listdir_ci(cur)
        real = names.get(p.lower())
        if real is None:
            return None
        cur = os.path.join(cur, real)
    return cur


def http_json(url, data=None, headers=None):
    hdrs = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdrs, method="POST" if body else "GET")
    with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ─── Nommage ─────────────────────────────────────────────────────────────────
JUNK_TOKENS = {
    "3D", "2D", "BD", "BD25", "BD50", "BLURAY", "BLU", "RAY", "DVD", "DVD5", "DVD9",
    "DISC", "DISK", "D1", "D2", "CD", "FR", "FRA", "FRE", "FRENCH", "VF", "VFF", "VOST",
    "EN", "ENG", "US", "UK", "EU", "EURO", "INT", "PAL", "NTSC", "WS", "FS", "R1", "R2", "R4",
    "UHD", "4K", "HD", "SE", "CE", "STD",
}


# Noms génériques que l'éditeur ou le logiciel de gravure laissent à la place du titre
# (« LOGICAL_VOLUME_ID », « Blu-ray », « DVD_VIDEO »…) : jamais retenus comme titre.
PLACEHOLDERS = {
    "logicalvolumeid", "volumeid", "volume", "newvolume", "volumelabel", "label", "nolabel",
    "bluray", "bluraydisc", "blurayvideo", "bluray3d", "bd", "bdrom", "bdre", "bdr", "bdvideo", "bdmv",
    "bdmvroot", "dvd", "dvdvideo", "dvdrom", "dvdr", "dvdvolume", "videots", "cdrom", "cd", "audiocd",
    "cdaudio", "disc", "disk", "untitled", "notitle", "title", "unknown", "movie", "film", "video",
    "mainmovie", "feature", "main", "sanstitre", "default",
}


def placeholder_key(name):
    s = unicodedata.normalize("NFKD", name or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", s.lower())


def is_placeholder(name):
    """Vrai si le nom ne désigne pas un contenu (générique, numéro, identifiant)."""
    k = placeholder_key(name)
    if len(k) < 2 or k in PLACEHOLDERS:
        return True
    if re.fullmatch(r"\d+", k):                                     # « 20091216 »
        return True
    if re.fullmatch(r"(disc|disk|dvd|bd|cd|volume|title|track|vol|d)\d+", k):
        return True
    if re.fullmatch(r"[0-9a-f]{8,}", k) and re.search(r"\d", k):  # identifiant hexadécimal
        return True
    return False


def clean_label(label):
    """« AVATAR_3D_FR_DISC1 » → « Avatar » ; vide pour un label générique."""
    s = re.sub(r"[_.]+", " ", label or "").strip()
    tokens = s.split()
    is_junk = lambda t: t.upper() in JUNK_TOKENS or re.fullmatch(r"(DISC|DISK|CD|D)\d+", t.upper())
    # « 3D » est retiré partout ; les autres marqueurs seulement en fin de label
    tokens = [t for t in tokens if t.upper() != "3D"]
    while tokens and is_junk(tokens[-1]):
        tokens.pop()
    s = " ".join(tokens)
    if is_placeholder(s):
        return ""
    if s and s == s.upper():
        small = {"de", "du", "des", "le", "la", "les", "et", "of", "the", "a", "an", "and", "in", "on"}
        words = s.lower().split()
        s = " ".join(w if (i and w in small) else w[:1].upper() + w[1:] for i, w in enumerate(words))
    return s


def render_name(template, title, year):
    name = template.replace("{title}", title or "").replace("{year}", year or "")
    name = re.sub(r"\(\s*\)|\[\s*\]", "", name)        # « () » vide
    name = re.sub(r"\s{2,}", " ", name).strip(" -_.")
    name = name.replace("/", "-")
    name = re.sub(r"[\x00-\x1f]", "", name)
    return name


def bdmt_title(mount, langs=("fra", "fre", "eng")):
    """Titre des métadonnées de l'éditeur (BDMV/META/DL/bdmt_<langue>.xml).

    Langues préférées d'abord, puis toutes les autres ; les noms génériques
    (« Blu-ray », « LOGICAL_VOLUME_ID »…) sont ignorés."""
    import html
    meta = join_ci(mount, "BDMV", "META", "DL")
    if not meta:
        return None
    names = listdir_ci(meta)
    files = [names["bdmt_%s.xml" % l] for l in langs if "bdmt_%s.xml" % l in names]
    files += sorted(real for low, real in names.items() if re.fullmatch(r"bdmt_\w+\.xml", low) and real not in files)
    for real in files:
        try:
            with open(os.path.join(meta, real), "r", encoding="utf-8", errors="replace") as f:
                xml = f.read()
        except OSError:
            continue
        for m in re.finditer(r"<(?:\w+:)?name>\s*(.*?)\s*</(?:\w+:)?name>", xml, re.S):
            t = re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()
            if t and not is_placeholder(t):
                return t
    return None


# ─── Contenu déjà présent ───────────────────────────────────────────────────
# « Avatar (2009) [3D] [VFF].mkv » correspond à « Avatar (2009) » : les mentions entre
# crochets, la casse, les accents et l'espacement ne comptent pas. L'année n'est
# comparée que si les deux noms en ont une.
YEAR_RE = re.compile(r"\(\s*(\d{4})\s*\)")


def name_key(name):
    s = re.sub(r"\[[^\]]*\]", " ", name or "")
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).casefold()
    s = re.sub(r"[\s_]+", " ", s).strip(" -_.")
    return s


def same_name(a, b):
    ka, kb = name_key(a), name_key(b)
    if ka == kb:
        return True
    ya, yb = YEAR_RE.search(ka), YEAR_RE.search(kb)
    if bool(ya) != bool(yb):        # une seule année : comparer sans elle
        strip = lambda k: re.sub(r"\s+", " ", YEAR_RE.sub(" ", k)).strip(" -_.")
        return strip(ka) == strip(kb)
    return False


def find_existing(base, rel, ext=""):
    """Chemins sous <base> correspondant à <rel> (composants séparés par « / »),
    sans tenir compte des mentions entre crochets. <ext> (ex. « .mkv ») s'applique
    au dernier composant, qui doit alors être un fichier non vide."""
    parts = [p for p in rel.split("/") if p]
    if not parts:
        return []
    cur = [base]
    for i, part in enumerate(parts):
        last = i == len(parts) - 1
        nxt = []
        for d in cur:
            try:
                entries = sorted(os.listdir(d))
            except OSError:
                continue
            for n in entries:
                p = os.path.join(d, n)
                if last and ext:
                    if not n.lower().endswith(ext.lower()) or not os.path.isfile(p) or os.path.getsize(p) == 0:
                        continue
                    stem = n[: -len(ext)]
                elif not os.path.isdir(p):
                    continue
                else:
                    stem = n
                if same_name(stem, part):
                    nxt.append(p)
        cur = nxt
    return cur


def count_audio(path):
    n = 0
    for _root, _dirs, files in os.walk(path):
        n += sum(1 for f in files if f.lower().endswith((".flac", ".wv", ".dsf", ".mp3", ".ogg", ".opus", ".m4a", ".wav")))
    return n


# ─── Blu-ray : playlists MPLS ───────────────────────────────────────────────
def parse_mpls(path):
    """Renvoie (durée en secondes, [noms de clips])."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"MPLS":
        raise ValueError("pas un fichier MPLS")
    pl = int.from_bytes(data[8:12], "big")
    n_items = int.from_bytes(data[pl + 6:pl + 8], "big")
    pos = pl + 10
    total = 0
    clips = []
    for _ in range(n_items):
        length = int.from_bytes(data[pos:pos + 2], "big")
        clip = data[pos + 2:pos + 7].decode("ascii", "replace")
        t_in = int.from_bytes(data[pos + 14:pos + 18], "big")
        t_out = int.from_bytes(data[pos + 18:pos + 22], "big")
        if t_out > t_in:
            total += t_out - t_in
        clips.append(clip)
        pos += 2 + length
    return total / 45000.0, clips


def mpls_list(mount, min_seconds):
    """Lignes : nom.mpls, secondes, octets des clips, 3D (yes/no) — durée décroissante."""
    pldir = join_ci(mount, "BDMV", "PLAYLIST")
    stream = join_ci(mount, "BDMV", "STREAM")
    if not pldir or not stream:
        return 1
    m2ts = listdir_ci(stream)
    ssif_dir = join_ci(stream, "SSIF")
    ssif = listdir_ci(ssif_dir) if ssif_dir else {}
    rows = []
    for name in sorted(os.listdir(pldir)):
        if not name.lower().endswith(".mpls"):
            continue
        try:
            secs, clips = parse_mpls(os.path.join(pldir, name))
        except (OSError, ValueError, IndexError):
            continue
        if secs < min_seconds:
            continue
        size = 0
        for c in dict.fromkeys(clips):
            real = m2ts.get(c.lower() + ".m2ts")
            if real:
                try:
                    size += os.path.getsize(os.path.join(stream, real))
                except OSError:
                    pass
        is3d = any((c.lower() + ".ssif") in ssif for c in clips)
        rows.append((name, int(secs), size, "yes" if is3d else "no"))
    rows.sort(key=lambda r: (-r[1], r[0]))
    for r in rows:
        out(*r)
    return 0 if rows else 1


def index_version(mount):
    p = join_ci(mount, "BDMV", "index.bdmv")
    if not p:
        return 1
    with open(p, "rb") as f:
        head = f.read(8)
    out(head[4:8].decode("ascii", "replace"))
    return 0


# ─── MakeMKV (sortie robot « -r ») ──────────────────────────────────────────
def hms_to_seconds(s):
    parts = [int(x) for x in re.findall(r"\d+", s or "")]
    total = 0
    for p in parts:
        total = total * 60 + p
    return total


def makemkv_titles(robot_file):
    """Lignes : index, secondes, octets, fichier source, nom — durée décroissante."""
    titles = {}
    with open(robot_file, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("TINFO:"):
                continue
            try:
                fields = next(csv.reader([line[6:].rstrip("\n")]))
                idx, attr, value = int(fields[0]), int(fields[1]), fields[3]
            except (StopIteration, ValueError, IndexError):
                continue
            titles.setdefault(idx, {})[attr] = value
    rows = []
    for idx, a in titles.items():
        rows.append((idx, hms_to_seconds(a.get(9, "")), int(a.get(11, "0") or 0), a.get(16, ""), a.get(2, "")))
    rows.sort(key=lambda r: (-r[1], r[0]))
    for r in rows:
        out(*r)
    return 0 if rows else 1


# ─── mkvmerge -J ─────────────────────────────────────────────────────────────
def mkv_tracks(json_file):
    """Lignes id|codec|lang|desc pour l'audio et les sous-titres."""
    with open(json_file, "r", encoding="utf-8") as f:
        info = json.load(f)
    for t in info.get("tracks", []):
        if t.get("type") not in ("audio", "subtitles"):
            continue
        p = t.get("properties", {})
        codec_id = p.get("codec_id", "")
        lang = p.get("language") or "und"
        parts = [t.get("codec", "")]
        if t.get("type") == "audio" and p.get("audio_channels"):
            parts.append("Channels: %d" % p["audio_channels"])
        if p.get("track_name"):
            parts.append(p["track_name"])
        desc = ", ".join(x for x in parts if x).replace("|", "/")
        print("%s|%s|%s|%s" % (t.get("id"), codec_id, lang, desc))
    return 0


def mkv_video(json_file):
    """Une ligne : durée d'image (ns), dimensions d'affichage, dimensions en pixels."""
    with open(json_file, "r", encoding="utf-8") as f:
        info = json.load(f)
    for t in info.get("tracks", []):
        if t.get("type") == "video":
            p = t.get("properties", {})
            out(p.get("default_duration", ""), p.get("display_dimensions", ""), p.get("pixel_dimensions", ""))
            return 0
    return 1


def mkv_video_id(json_file):
    """Identifiant de la première piste vidéo H.264 (ou MVC)."""
    with open(json_file, "r", encoding="utf-8") as f:
        info = json.load(f)
    for t in info.get("tracks", []):
        cid = t.get("properties", {}).get("codec_id", "")
        if t.get("type") == "video" and cid.startswith("V_MPEG4/ISO/"):
            out(t.get("id"))
            return 0
    return 1


def mkv_video_ids(json_file):
    with open(json_file, "r", encoding="utf-8") as f:
        info = json.load(f)
    return [t.get("id") for t in info.get("tracks", [])
            if t.get("type") == "video" and t.get("properties", {}).get("codec_id", "").startswith("V_MPEG4/ISO/")]


def fps_from_ns(ns):
    """Durée d'image en ns → « num den » (24000/1001, 25/1…)."""
    ns = float(ns)
    if ns <= 0:
        return 1
    fps = 1e9 / ns
    num = round(fps * 1001)
    if num % 1000 == 0 and abs(num / 1001 - fps) < 0.002:
        out(num, 1001)              # 23,976 · 29,97 · 59,94
    elif abs(round(fps) - fps) < 0.002:
        out(round(fps), 1)          # 24 · 25 · 50
    else:
        out(round(fps * 1000), 1000)
    return 0


def has_mvc(path, limit=64 * 1024 * 1024):
    """Vrai si le flux Annex B contient des NAL MVC (type 20 ; 15 = subset SPS)."""
    seen = set()
    with open(path, "rb") as f:
        data = f.read(limit)
    i = data.find(b"\x00\x00\x01")
    while i != -1 and i + 3 < len(data):
        nal = data[i + 3] & 0x1F
        if nal in (15, 20):
            seen.add(nal)
            if 20 in seen:
                return True
        i = data.find(b"\x00\x00\x01", i + 3)
    return False


# ─── TheDiscDB ───────────────────────────────────────────────────────────────
def disc_files(mount, kind):
    if kind == "dvd":
        d = join_ci(mount, "VIDEO_TS")
        names = sorted(os.listdir(d)) if d else []
    else:
        d = join_ci(mount, "BDMV", "STREAM")
        names = sorted(n for n in os.listdir(d) if n.lower().endswith(".m2ts")) if d else []
    files = []
    for i, n in enumerate(names, 1):
        p = os.path.join(d, n)
        if not os.path.isfile(p):
            continue
        st = os.stat(p)
        created = datetime.datetime.fromtimestamp(st.st_mtime, tz=datetime.timezone.utc)
        files.append({
            "Index": i,
            "Name": n,
            "Size": st.st_size,
            "CreationTime": created.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (created.microsecond // 1000),
        })
    return files


def discdb_hash(mount, kind):
    files = disc_files(mount, kind)
    if not files:
        return None
    res = http_json(DISCDB_ORIGIN + "/api/hash", {"Files": files})
    return res.get("hash")


def discdb_lookup(mount, kind):
    """Une ligne : titre, année, playlist ou fichier source du film (peut être vide)."""
    try:
        h = discdb_hash(mount, kind)
        if not h or not re.fullmatch(r"[0-9A-Fa-f]{16,64}", h):
            return 1
        query = (
            '{ mediaItems(where: {releases: {some: {discs: {some: {contentHash: {eq: "%s"}}}}}}) '
            "{ nodes { title year type releases { discs { contentHash "
            "titles { index sourceFile duration item { type title } } } } } } }" % h
        )
        res = http_json(DISCDB_ORIGIN + "/graphql", {"query": query})
    except Exception as exc:  # réseau, JSON, HTTP 404…
        print("discdb: %s" % exc, file=sys.stderr)
        return 1
    nodes = ((res.get("data") or {}).get("mediaItems") or {}).get("nodes") or []
    if not nodes:
        return 1
    node = nodes[0]
    main = ""
    for rel in node.get("releases") or []:
        for disc in rel.get("discs") or []:
            if (disc.get("contentHash") or "").upper() != h.upper():
                continue
            for t in disc.get("titles") or []:
                item = t.get("item") or {}
                if re.sub(r"[^a-z]", "", (item.get("type") or "").lower()) == "mainmovie":
                    main = t.get("sourceFile") or ""
                    break
            if main:
                break
        if main:
            break
    out(node.get("title", ""), node.get("year", ""), main)
    return 0


# ─── TMDb ────────────────────────────────────────────────────────────────────
def tmdb_search(query, key, lang):
    """Lignes : titre, année, identifiant TMDb (10 premiers résultats)."""
    params = {"query": query, "language": lang, "include_adult": "false"}
    headers = {}
    if len(key) > 40:          # jeton « API Read Access Token » (v4)
        headers["Authorization"] = "Bearer " + key
    else:                      # clé v3
        params["api_key"] = key
    url = "https://api.themoviedb.org/3/search/movie?" + urllib.parse.urlencode(params)
    try:
        res = http_json(url, headers=headers)
    except Exception as exc:
        print("tmdb: %s" % exc, file=sys.stderr)
        return 1
    results = res.get("results") or []
    for r in results[:10]:
        out(r.get("title") or r.get("original_title") or "", (r.get("release_date") or "")[:4], r.get("id", ""))
    return 0 if results else 1


# ─── Wikidata (sans clé) ─────────────────────────────────────────────────────
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
# film, film d'animation, long métrage d'animation, film 3D, téléfilm, film à épisodes
FILM_CLASSES = ("Q11424", "Q202866", "Q29168811", "Q229390", "Q506240", "Q24862", "Q24869")


def wikidata_search(query, lang="fr"):
    """Lignes : titre (langue demandée, sinon anglais), année, identifiant Wikidata."""
    lang = (lang or "fr").split("-")[0].lower() or "fr"
    films = "|".join("P31=" + q for q in FILM_CLASSES)
    try:
        res = http_json(WIKIDATA_API + "?" + urllib.parse.urlencode({
            "action": "query", "list": "search", "format": "json", "srlimit": "6",
            "srsearch": "%s haswbstatement:%s" % (query, films)}))
        ids = [h["title"] for h in (res.get("query") or {}).get("search") or [] if re.fullmatch(r"Q\d+", h.get("title", ""))]
        if not ids:
            return 1
        ent = http_json(WIKIDATA_API + "?" + urllib.parse.urlencode({
            "action": "wbgetentities", "format": "json", "ids": "|".join(ids),
            "props": "labels|claims", "languages": "%s|en" % lang}))
    except Exception as exc:
        print("wikidata: %s" % exc, file=sys.stderr)
        return 1
    found = 0
    for qid in ids:
        e = (ent.get("entities") or {}).get(qid) or {}
        labels = e.get("labels") or {}
        title = (labels.get(lang) or labels.get("en") or {}).get("value")
        if not title:
            continue
        years = []
        for c in (e.get("claims") or {}).get("P577") or []:
            t = ((((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")) or {}).get("time", "")
            m = re.match(r"[+-](\d{4})", t)
            if m:
                years.append(m.group(1))
        out(title, min(years) if years else "", qid)
        found += 1
    return 0 if found else 1


# ─── CD audio : identifiant de disque MusicBrainz ───────────────────────────
CDROMREADTOCHDR = 0x5305
CDROMREADTOCENTRY = 0x5306
CDROM_LBA = 0x01
CDROM_LEADOUT = 0xAA


def read_toc(device):
    """Table des matières : (premier, dernier, [(piste, lba, données?)…], lba de fin)."""
    import fcntl
    fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
    try:
        first, last = struct.unpack("BB", fcntl.ioctl(fd, CDROMREADTOCHDR, bytes(2)))
        tracks = []
        for t in list(range(first, last + 1)) + [CDROM_LEADOUT]:
            buf = struct.pack("BBBxiB3x", t, 0, CDROM_LBA, 0, 0)
            r = fcntl.ioctl(fd, CDROMREADTOCENTRY, buf)
            _trk, adr_ctrl, _fmt, lba, _mode = struct.unpack("BBBxiB3x", r)
            tracks.append((t, lba, bool((adr_ctrl >> 4) & 0x04)))
    finally:
        os.close(fd)
    leadout = tracks.pop()[1]
    return first, last, tracks, leadout


def audio_toc(first, last, tracks, leadout):
    """TOC MusicBrainz (décalages + 150) : (premier, dernier audio, fin, [décalages])."""
    audio = [t for t in tracks if not t[2]]
    if not audio:
        return None
    last_audio = audio[-1][0]
    after = [t for t in tracks if t[0] > last_audio]
    if after:                     # CD enrichi : la session de données suit
        end = after[0][1] - 11400 + 150
    else:
        end = leadout + 150
    return first, last_audio, end, [t[1] + 150 for t in audio if t[0] >= first]


def disc_id(first, last, leadout, offsets):
    import base64
    import hashlib
    data = "%02X%02X%08X" % (first, last, leadout)
    padded = list(offsets) + [0] * (99 - len(offsets))
    data += "".join("%08X" % o for o in padded[:99])
    digest = hashlib.sha1(data.encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii").translate(str.maketrans("+/=", "._-"))


def artist_credit(ac):
    return "".join((c.get("name") or (c.get("artist") or {}).get("name") or "") + (c.get("joinphrase") or "") for c in ac or [])


def musicbrainz_releases(did, toc):
    """Éditions MusicBrainz du disque (identifiant exact, puis TOC approchée)."""
    first, last, end, offsets = toc
    params = {"inc": "artist-credits+recordings", "fmt": "json", "cdstubs": "no",
              "toc": " ".join(str(x) for x in [first, last, end] + offsets)}
    url = "https://musicbrainz.org/ws/2/discid/%s?%s" % (did, urllib.parse.urlencode(params))
    try:
        res = http_json(url)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return []
        raise
    rels = res.get("releases") or []
    lines = []
    for r in rels:
        tracks = 0
        disc = ""
        media = r.get("media") or []
        for m in media:
            ids = [d.get("id") for d in m.get("discs") or []]
            if did in ids or (not tracks and len(m.get("tracks") or []) == len(offsets)):
                tracks = len(m.get("tracks") or []) or m.get("track-count") or 0
                disc = str(m.get("position") or "")
                if did in ids:
                    break
        lines.append({
            "release": r.get("id", ""),
            "artist": artist_credit(r.get("artist-credit")),
            "album": r.get("title", ""),
            "year": (r.get("date") or "")[:4],
            "country": r.get("country") or "",
            "comment": r.get("disambiguation") or "",
            "tracks": tracks or len(offsets),
            "disc": disc,
            "discs": len(media),
        })
    return lines


def cd_identify(device, online=True):
    """Ligne « disc » puis une ligne par édition : identifiant, artiste, album, année,
    pays, commentaire, pistes, disque, disques."""
    try:
        toc = audio_toc(*read_toc(device))
    except OSError as exc:
        print("toc: %s" % exc, file=sys.stderr)
        return 1
    if not toc:
        return 1
    did = disc_id(toc[0], toc[1], toc[2], toc[3])
    out("disc", did, len(toc[3]))
    if not online:
        return 0
    try:
        rels = musicbrainz_releases(did, toc)
    except Exception as exc:
        print("musicbrainz: %s" % exc, file=sys.stderr)
        return 0
    for r in rels:
        out("release", r["release"], r["artist"], r["album"], r["year"], r["country"], r["comment"], r["tracks"], r["disc"], r["discs"])
    return 0


def render_music(template, values):
    """Modèle cyanrip ({album_artist}/{album}…) → chemin, ou None si le modèle
    utilise une variable ou une condition inconnue (cyanrip le rendra lui-même)."""
    if "{if" in template:
        return None
    unknown = []

    def sub(m):
        k = m.group(1)
        if k not in values:
            unknown.append(k)
            return ""
        v = str(values[k] or "")
        v = v.replace("/", "-").replace("{", "(").replace("}", ")")
        return re.sub(r"[\x00-\x1f]", "", v)

    rendered = re.sub(r"\{([a-z_]+)\}", sub, template)
    if unknown:
        return None
    parts = [re.sub(r"\s{2,}", " ", p).strip(" .") for p in rendered.split("/")]
    if any(not p for p in parts):
        return None
    return "/".join(parts)


def json_object(pairs):
    """« clé=valeur » … → objet JSON ; « clé:=json » pour une valeur déjà JSON."""
    obj = {}
    for p in pairs:
        k, v = p.split("=", 1)
        if k.endswith(":"):
            obj[k[:-1]] = json.loads(v)
        else:
            obj[k] = v
    return json.dumps(obj, ensure_ascii=False)


# ─── SACD ────────────────────────────────────────────────────────────────────
def is_sacd_iso(path):
    """Une image SACD porte « SACDMTOC » au secteur 510."""
    try:
        with open(path, "rb") as f:
            f.seek(510 * 2048)
            return f.read(8) == b"SACDMTOC"
    except OSError:
        return False


# ─── Point d'entrée ──────────────────────────────────────────────────────────
def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "clean-label":
        r = clean_label(args[0] if args else "")
        if r:
            out(r)
        return 0 if r else 1
    if cmd == "render-name":
        out(render_name(args[0], args[1], args[2] if len(args) > 2 else ""))
        return 0
    if cmd == "bdmt":
        t = bdmt_title(args[0])
        if t:
            out(t)
        return 0 if t else 1
    if cmd == "mpls-list":
        return mpls_list(args[0], int(args[1]) if len(args) > 1 else 0)
    if cmd == "index-version":
        return index_version(args[0])
    if cmd == "makemkv-titles":
        return makemkv_titles(args[0])
    if cmd == "mkv-tracks":
        return mkv_tracks(args[0])
    if cmd == "mkv-video":
        return mkv_video(args[0])
    if cmd == "mkv-video-count":
        out(len(mkv_video_ids(args[0])))
        return 0
    if cmd == "mkv-video-ids":
        ids = mkv_video_ids(args[0])
        out(*ids)
        return 0 if ids else 1
    if cmd == "mkv-video-id":
        return mkv_video_id(args[0])
    if cmd == "fps-from-ns":
        return fps_from_ns(args[0])
    if cmd == "has-mvc":
        return 0 if has_mvc(args[0]) else 1
    if cmd == "discdb":
        return discdb_lookup(args[0], args[1])
    if cmd == "tmdb":
        return tmdb_search(args[0], args[1], args[2] if len(args) > 2 else "fr-FR")
    if cmd == "is-placeholder":
        return 0 if is_placeholder(args[0] if args else "") else 1
    if cmd == "find-existing":
        found = find_existing(args[0], args[1], args[2] if len(args) > 2 else "")
        for f in found:
            out(f)
        return 0 if found else 1
    if cmd == "same-name":
        return 0 if same_name(args[0], args[1]) else 1
    if cmd == "count-audio":
        out(count_audio(args[0]))
        return 0
    if cmd == "wikidata":
        return wikidata_search(args[0], args[1] if len(args) > 1 else "fr")
    if cmd == "cd-identify":
        return cd_identify(args[0], not (len(args) > 1 and args[1] == "offline"))
    if cmd == "render-music":
        vals = dict(a.split("=", 1) for a in args[1:])
        r = render_music(args[0], vals)
        if r:
            out(r)
        return 0 if r else 1
    if cmd == "json-list":
        print(json.dumps([l for l in (args[0] if args else "").split("\n") if l], ensure_ascii=False))
        return 0
    if cmd == "json":
        print(json_object(args))
        return 0
    if cmd == "is-sacd-iso":
        return 0 if is_sacd_iso(args[0]) else 1
    print("sous-commande inconnue : %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
