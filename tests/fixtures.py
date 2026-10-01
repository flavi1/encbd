# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
"""Fabrique de faux disques pour les tests (aucun contenu vidéo réel)."""
import os
import struct


def mpls_bytes(items):
    """items : liste de (clip '00001', secondes). Produit un MPLS minimal valide."""
    body = b""
    for clip, secs in items:
        t_in, t_out = 0, int(secs * 45000)
        item = clip.encode() + b"M2TS" + b"\x00\x01" + b"\x00" + struct.pack(">II", t_in, t_out)
        body += struct.pack(">H", len(item)) + item
    playlist = b"\x00\x00" + struct.pack(">HH", len(items), 0) + body
    playlist = struct.pack(">I", len(playlist)) + playlist
    header_len = 40
    return b"MPLS0200" + struct.pack(">III", header_len, 0, 0) + b"\x00" * (header_len - 20) + playlist


def make_bdmv(root, playlists, clips, three_d=False, version="0200", label_xml=None, aacs=True):
    """playlists : {'00800': [('00001', 7200)]} ; clips : {'00001': taille_en_octets}."""
    for d in ("BDMV/PLAYLIST", "BDMV/STREAM", "BDMV/CLIPINF"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    with open(os.path.join(root, "BDMV/index.bdmv"), "wb") as f:
        f.write(b"INDX" + version.encode() + b"\x00" * 32)
    for name, items in playlists.items():
        with open(os.path.join(root, "BDMV/PLAYLIST", name + ".mpls"), "wb") as f:
            f.write(mpls_bytes(items))
    for clip, size in clips.items():
        with open(os.path.join(root, "BDMV/STREAM", clip + ".m2ts"), "wb") as f:
            f.truncate(size)          # fichier creux : taille sans occuper le disque
    if three_d:
        os.makedirs(os.path.join(root, "BDMV/STREAM/SSIF"), exist_ok=True)
        for clip in clips:
            open(os.path.join(root, "BDMV/STREAM/SSIF", clip + ".ssif"), "wb").close()
    if label_xml:
        os.makedirs(os.path.join(root, "BDMV/META/DL"), exist_ok=True)
        with open(os.path.join(root, "BDMV/META/DL/bdmt_fra.xml"), "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n<disclib><di:discinfo>'
                    '<di:title><di:name>%s</di:name></di:title></di:discinfo></disclib>\n' % label_xml)
    if aacs:
        os.makedirs(os.path.join(root, "AACS"), exist_ok=True)
