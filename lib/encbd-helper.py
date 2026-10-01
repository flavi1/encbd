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
import sys
import urllib.parse
import urllib.request

USER_AGENT = "encbd/1.0 (+https://github.com/)"
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


def clean_label(label):
    """« AVATAR_3D_FR_DISC1 » → « Avatar »."""
    s = re.sub(r"[_.]+", " ", label or "").strip()
    tokens = s.split()
    is_junk = lambda t: t.upper() in JUNK_TOKENS or re.fullmatch(r"(DISC|DISK|CD|D)\d+", t.upper())
    # « 3D » est retiré partout ; les autres marqueurs seulement en fin de label
    tokens = [t for t in tokens if t.upper() != "3D"]
    while tokens and is_junk(tokens[-1]):
        tokens.pop()
    s = " ".join(tokens)
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


def bdmt_title(mount):
    meta = join_ci(mount, "BDMV", "META", "DL")
    if not meta:
        return None
    names = listdir_ci(meta)
    for lang in ("fra", "fre", "eng"):
        real = names.get("bdmt_%s.xml" % lang)
        if not real:
            continue
        try:
            with open(os.path.join(meta, real), "r", encoding="utf-8", errors="replace") as f:
                xml = f.read()
        except OSError:
            continue
        m = re.search(r"<(?:\w+:)?name>\s*(.*?)\s*</(?:\w+:)?name>", xml, re.S)
        if m and m.group(1).strip():
            import html
            return html.unescape(m.group(1).strip())
    return None


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
    if cmd == "is-sacd-iso":
        return 0 if is_sacd_iso(args[0]) else 1
    print("sous-commande inconnue : %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
