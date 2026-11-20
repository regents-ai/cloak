# /// script
# requires-python = ">=3.12"
# dependencies = ["ds-store==1.3.1", "mac-alias==2.2.2"]
# ///
"""Lay out the window a person sees on opening the disk image, for
app/release.sh: the app on the left, Applications on the right, the arrow of
app/install-window.tiff between them, large icons and no toolbar or sidebar.

Finder keeps a folder's layout in its .DS_Store, and names the picture by an
alias that only resolves on the volume it was made on, so this runs against
the mounted, writable image, with the picture already at
.background/install-window.tiff.

    uv run app/install-window.py <mounted volume>
"""

import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias, Bookmark

# In points, as app/art.swift draws the picture: 640 by 400, the icons'
# centres 180 down.
WIDTH, HEIGHT, TITLE_BAR = 640, 400, 28
PLACES = {"Cloak.app": (170, 180), "Applications": (470, 180)}

volume = Path(sys.argv[1])
picture = volume / ".background" / "install-window.tiff"

with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": f"{{{{200, 120}}, {{{WIDTH}, {HEIGHT + TITLE_BAR}}}}}",
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusbar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(str(picture)).to_bytes(),
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "arrangeBy": "none",
        "iconSize": 128.0,
        "textSize": 13.0,
        "labelOnBottom": True,
        "showIconPreview": False,
        "showItemInfo": False,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["."]["pBBk"] = Bookmark.for_file(str(picture))
    for name, place in PLACES.items():
        store[name]["Iloc"] = place
