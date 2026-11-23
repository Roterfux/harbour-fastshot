"""Copy the image engine from Photo Enhance (the source of truth) into FastShot.

    python tools/sync-engine.py
"""
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "harbour-photoenhance", "python", "enhance.py")
DST = os.path.join(HERE, "..", "python", "enhance.py")

shutil.copyfile(SRC, DST)
print("copied", os.path.normpath(SRC), "->", os.path.normpath(DST))
