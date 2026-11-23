"""QR reader tests. qr_samples.json holds module grids made by libqrencode (an independent
encoder): a URL (byte mode), letters and digits at level H, kanji, and a version 7 code."""
import json
import os
import random
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

from PIL import Image, ImageDraw  # noqa: E402

import camworker  # noqa: E402
import qrscan  # noqa: E402

with open(os.path.join(HERE, "qr_samples.json"), encoding="utf-8") as f:
    SAMPLES = json.load(f)


def grid(sample):
    return [[int(ch) for ch in row] for row in sample["rows"]]


def picture(sample, px=5, angle=0, mirror=False, size=640):
    g = grid(sample)
    n = len(g) + 8
    img = Image.new("L", (n * px, n * px), 210)
    d = ImageDraw.Draw(img)
    for r, row in enumerate(g):
        for c, v in enumerate(row):
            if v:
                d.rectangle([(c + 4) * px, (r + 4) * px, (c + 5) * px - 1, (r + 5) * px - 1], fill=25)
    if mirror:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    img = img.rotate(angle, expand=True, fillcolor=210, resample=Image.BILINEAR)
    canvas = Image.new("L", (size, size), 120)
    canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2))
    return canvas


def test_samples_cover_the_modes():
    assert len(SAMPLES) == 4
    assert {len(s["rows"]) for s in SAMPLES} >= {21, 45}


@pytest.mark.parametrize("sample", SAMPLES, ids=lambda s: str(len(s["rows"])))
def test_grid_decodes(sample):
    assert qrscan._try_grid(grid(sample)) == sample["text"]


def test_mirrored_grid_decodes():
    g = grid(SAMPLES[0])
    assert qrscan._try_grid([list(col) for col in zip(*g)]) == SAMPLES[0]["text"]


def test_error_correction_fixes_flipped_modules():
    s = [x for x in SAMPLES if x["text"] == "HELLO WORLD 123"][0]      # level H
    g = grid(s)
    rnd = random.Random(5)
    for _ in range(6):
        r, c = rnd.randrange(9, len(g)), rnd.randrange(9, len(g))
        g[r][c] ^= 1
    assert qrscan._try_grid(g) == s["text"]


def test_reed_solomon():
    # message + 10 check symbols from a systematic encoder, then 5 errors
    gen = [1]
    for i in range(10):
        nxt = [0] * (len(gen) + 1)
        for j, c in enumerate(gen):
            nxt[j] ^= c
            nxt[j + 1] ^= qrscan._mul(c, qrscan._EXP[i])
        gen = nxt
    msg = list(range(1, 21))
    rem = msg + [0] * 10
    for i in range(len(msg)):
        coef = rem[i]
        if coef:
            for j in range(1, len(gen)):
                rem[i + j] ^= qrscan._mul(gen[j], coef)
    code = msg + rem[len(msg):]
    bad = code[:]
    for pos in (0, 3, 11, 22, 29):
        bad[pos] ^= 0x5A
    assert qrscan.rs_correct(bad, 10)
    assert bad == code
    worse = code[:]
    for pos in range(6):
        worse[pos] ^= 0x33
    assert not qrscan.rs_correct(worse, 10) or worse != code


def test_alignment_positions():
    assert qrscan._alignment_positions(1) == []
    assert qrscan._alignment_positions(2) == [6, 18]
    assert qrscan._alignment_positions(7) == [6, 22, 38]
    assert qrscan._alignment_positions(32) == [6, 34, 60, 86, 112, 138]


@pytest.mark.parametrize("angle,mirror", [(0, False), (33, False), (180, False), (70, True)])
def test_pictures_decode(angle, mirror):
    for s in SAMPLES:
        assert qrscan.decode_image(picture(s, angle=angle, mirror=mirror)) == s["text"]


def test_no_code():
    img = Image.new("L", (400, 300), 128)
    ImageDraw.Draw(img).rectangle([50, 50, 150, 120], fill=20)
    assert qrscan.decode_image(img) is None


def test_scan_qr(tmp_path):
    p = tmp_path / "frame.bmp"
    picture(SAMPLES[0], angle=12).convert("RGB").save(str(p))
    text, mean = camworker.scan_qr("file://" + str(p))
    assert text == SAMPLES[0]["text"]
    assert mean > 50
    assert not p.exists()                                  # removed after reading

    black = tmp_path / "black.bmp"
    Image.new("RGB", (64, 64)).save(str(black))
    assert camworker.scan_qr(str(black), False) == ["", 0.0]
    assert black.exists()
    assert camworker.scan_qr(str(tmp_path / "missing.bmp")) == ["", -1]
