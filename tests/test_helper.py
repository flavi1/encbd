# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Flavien Guillon
"""Tests unitaires de lib/encbd-helper.py : python3 -m unittest discover -s tests"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fixtures  # noqa: E402

spec = importlib.util.spec_from_file_location("helper", os.path.join(HERE, "..", "lib", "encbd-helper.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Naming(unittest.TestCase):
    def test_clean_label(self):
        self.assertEqual(helper.clean_label("AVATAR_3D_FR"), "Avatar")
        self.assertEqual(helper.clean_label("LE_SEIGNEUR_DES_ANNEAUX_DISC1"), "Le Seigneur des Anneaux")
        self.assertEqual(helper.clean_label("Inception"), "Inception")
        self.assertEqual(helper.clean_label("THE_MATRIX_BD50_FRA"), "The Matrix")
        self.assertEqual(helper.clean_label(""), "")

    def test_render_name(self):
        t = "{title} ({year})"
        self.assertEqual(helper.render_name(t, "Mon film", "2009"), "Mon film (2009)")
        self.assertEqual(helper.render_name(t, "Mon film", ""), "Mon film")
        self.assertEqual(helper.render_name(t, "AC/DC Live", "1991"), "AC-DC Live (1991)")
        self.assertEqual(helper.render_name("{title}", "Mon film", "2009"), "Mon film")


class BluRay(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        fixtures.make_bdmv(self.root,
                           {"00800": [("00001", 3600), ("00002", 3000)], "00001": [("00003", 90)],
                            "00900": [("00004", 6500)]},
                           {"00001": 20_000_000_000, "00002": 15_000_000_000, "00003": 1, "00004": 30_000_000_000},
                           three_d=True, label_xml="Mon Film &amp; Cie")

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse_mpls(self):
        secs, clips = helper.parse_mpls(os.path.join(self.root, "BDMV/PLAYLIST/00800.mpls"))
        self.assertEqual(int(secs), 6600)
        self.assertEqual(clips, ["00001", "00002"])

    def test_mpls_list_sorted_and_filtered(self):
        from io import StringIO
        old, sys.stdout = sys.stdout, StringIO()
        try:
            rc = helper.mpls_list(self.root, 2400)
            lines = sys.stdout.getvalue().splitlines()
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0)
        self.assertEqual([l.split("\t")[0] for l in lines], ["00800.mpls", "00900.mpls"])
        self.assertEqual(lines[0].split("\t")[2], str(35_000_000_000))
        self.assertEqual(lines[0].split("\t")[3], "yes")

    def test_bdmt_title(self):
        self.assertEqual(helper.bdmt_title(self.root), "Mon Film & Cie")

    def test_uhd_version(self):
        with open(os.path.join(self.root, "BDMV/index.bdmv"), "r+b") as f:
            f.seek(4)
            f.write(b"0300")
        from io import StringIO
        old, sys.stdout = sys.stdout, StringIO()
        try:
            helper.index_version(self.root)
            self.assertEqual(sys.stdout.getvalue().strip(), "0300")
        finally:
            sys.stdout = old


class Parsers(unittest.TestCase):
    def capture(self, fn, *args):
        from io import StringIO
        old, sys.stdout = sys.stdout, StringIO()
        try:
            rc = fn(*args)
            return rc, sys.stdout.getvalue().splitlines()
        finally:
            sys.stdout = old

    def test_makemkv_titles(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
            f.write('MSG:1005,0,1,"MakeMKV v1.17.7 linux(x64-release) started","%1 started","MakeMKV"\n'
                    'TINFO:0,2,0,"Disc Title"\nTINFO:0,9,0,"0:48:10"\nTINFO:0,11,0,"9876543210"\n'
                    'TINFO:0,16,0,"00001.mpls"\n'
                    'TINFO:1,2,0,"Mon, film"\nTINFO:1,9,0,"2:01:30"\nTINFO:1,11,0,"35000000000"\n'
                    'TINFO:1,16,0,"00800.mpls"\n')
        try:
            rc, lines = self.capture(helper.makemkv_titles, f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(rc, 0)
        self.assertEqual(lines[0].split("\t"), ["1", "7290", "35000000000", "00800.mpls", "Mon, film"])

    def test_mkv_tracks(self):
        info = {"tracks": [
            {"id": 0, "type": "video", "codec": "AVC", "properties": {"codec_id": "V_MPEG4/ISO/AVC"}},
            {"id": 1, "type": "audio", "codec": "AC-3", "properties": {"codec_id": "A_AC3", "language": "fre", "audio_channels": 6}},
            {"id": 2, "type": "audio", "codec": "AAC", "properties": {"codec_id": "A_AAC", "audio_channels": 2, "track_name": "Com|ment"}},
            {"id": 3, "type": "subtitles", "codec": "PGS", "properties": {"codec_id": "S_HDMV/PGS", "language": "fre"}},
        ]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(info, f)
        try:
            rc, lines = self.capture(helper.mkv_tracks, f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(lines, ["1|A_AC3|fre|AC-3, Channels: 6",
                                 "2|A_AAC|und|AAC, Channels: 2, Com/ment",
                                 "3|S_HDMV/PGS|fre|PGS"])

    def test_sacd_iso_detection(self):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.seek(510 * 2048)
            f.write(b"SACDMTOC")
        try:
            self.assertTrue(helper.is_sacd_iso(f.name))
        finally:
            os.unlink(f.name)
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"\0" * 4096)
        try:
            self.assertFalse(helper.is_sacd_iso(f.name))
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
