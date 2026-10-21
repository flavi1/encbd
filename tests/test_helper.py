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


class Identification(unittest.TestCase):
    def test_placeholders(self):
        for name in ("LOGICAL_VOLUME_ID", "Blu-ray", "BLURAY", "DVD_VIDEO", "BDROM", "VIDEO_TS",
                     "Untitled", "DISC1", "20091216", "Volume 3"[:6], "3F2A9B1C0D"):
            self.assertTrue(helper.is_placeholder(name), name)
        for name in ("Avatar", "Le Seigneur des Anneaux", "Blu-ray Bonus Edition", "Se7en"):
            self.assertFalse(helper.is_placeholder(name), name)
        self.assertEqual(helper.clean_label("LOGICAL_VOLUME_ID"), "")
        self.assertEqual(helper.clean_label("DVD_VIDEO"), "")

    def test_bdmt_skips_placeholders_and_reads_all_languages(self):
        with tempfile.TemporaryDirectory() as root:
            meta = os.path.join(root, "BDMV", "META", "DL")
            os.makedirs(meta)
            xml = '<disclib><di:discinfo><di:title><di:name>%s</di:name></di:title></di:discinfo></disclib>'
            with open(os.path.join(meta, "bdmt_eng.xml"), "w") as f:
                f.write(xml % "Blu-ray")
            self.assertIsNone(helper.bdmt_title(root))
            with open(os.path.join(meta, "bdmt_deu.xml"), "w") as f:
                f.write(xml % "Das Boot")
            self.assertEqual(helper.bdmt_title(root), "Das Boot")
            with open(os.path.join(meta, "bdmt_fra.xml"), "w") as f:
                f.write(xml % "Le Bateau")
            self.assertEqual(helper.bdmt_title(root), "Le Bateau")

    def test_same_name_ignores_bracket_tags(self):
        self.assertTrue(helper.same_name("Avatar (2009) [3D] [VFF]", "avatar (2009)"))
        self.assertTrue(helper.same_name("Avatar [Director's cut]", "Avatar (2009)"))
        self.assertTrue(helper.same_name("Amélie", "AMELIE"))
        self.assertFalse(helper.same_name("Dune (1984)", "Dune (2021)"))
        self.assertFalse(helper.same_name("Alien", "Aliens"))

    def test_find_existing(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "AC-DC [FLAC]", "Back in Black [Remaster]"))
            with open(os.path.join(root, "Avatar (2009) [VFF].mkv"), "w") as f:
                f.write("x")
            open(os.path.join(root, "Vide.mkv"), "w").close()
            self.assertEqual(helper.find_existing(root, "Avatar (2009)", ".mkv"), [os.path.join(root, "Avatar (2009) [VFF].mkv")])
            self.assertEqual(helper.find_existing(root, "Vide", ".mkv"), [])
            self.assertEqual(helper.find_existing(root, "AC-DC/Back in Black"),
                             [os.path.join(root, "AC-DC [FLAC]", "Back in Black [Remaster]")])

    def test_disc_id(self):
        # Exemple de la documentation MusicBrainz (« Disc ID Calculation »)
        self.assertEqual(helper.disc_id(1, 6, 95462, [150, 15363, 32314, 46592, 63414, 80489]),
                         "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")

    def test_audio_toc_enhanced_cd(self):
        tracks = [(1, 0, False), (2, 15000, False), (3, 125824, True)]
        self.assertEqual(helper.audio_toc(1, 3, tracks, 200000), (1, 2, 125824 - 11400 + 150, [150, 15150]))
        self.assertEqual(helper.audio_toc(1, 2, tracks[:2], 30000), (1, 2, 30150, [150, 15150]))

    def test_musicbrainz_releases(self):
        sample = {"releases": [{
            "id": "rel-1", "title": "Album", "date": "1999-03-01", "country": "FR", "disambiguation": "",
            "artist-credit": [{"name": "A", "joinphrase": " & "}, {"name": "B", "joinphrase": ""}],
            "media": [{"position": 1, "discs": [{"id": "OTHER"}], "tracks": [{}] * 3},
                      {"position": 2, "discs": [{"id": "DID"}], "tracks": [{}] * 2}]}]}
        orig = helper.http_json
        helper.http_json = lambda url, *a, **k: sample
        try:
            rels = helper.musicbrainz_releases("DID", (1, 2, 30150, [150, 15150]))
        finally:
            helper.http_json = orig
        self.assertEqual(rels[0]["artist"], "A & B")
        self.assertEqual((rels[0]["year"], rels[0]["tracks"], rels[0]["disc"]), ("1999", 2, "2"))

    def test_render_music(self):
        v = {"album_artist": "AC/DC", "album": "Back in Black", "year": "1980"}
        self.assertEqual(helper.render_music("{album_artist}/{album} ({year})", v), "AC-DC/Back in Black (1980)")
        self.assertIsNone(helper.render_music("{album}{if #disc# > #1# (|disc|)}", v))
        self.assertIsNone(helper.render_music("{album} {barcode}", v))

    def test_wikidata(self):
        search = {"query": {"search": [{"title": "Q24871"}, {"title": "Q1"}]}}
        ents = {"entities": {
            "Q24871": {"labels": {"fr": {"value": "Avatar"}}, "claims": {"P577": [
                {"mainsnak": {"datavalue": {"value": {"time": "+2009-12-16T00:00:00Z"}}}},
                {"mainsnak": {"datavalue": {"value": {"time": "+2009-12-10T00:00:00Z"}}}}]}},
            "Q1": {"labels": {}}}}
        orig = helper.http_json
        helper.http_json = lambda url, *a, **k: search if "list=search" in url else ents
        import io
        import contextlib
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = helper.wikidata_search("Avatar", "fr-FR")
        finally:
            helper.http_json = orig
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue(), "Avatar\t2009\tQ24871\n")
