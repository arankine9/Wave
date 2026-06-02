# dmgbuild settings for the Wave installer DMG.
#
# dmgbuild writes the window's .DS_Store directly (via the pure-python ds_store /
# mac_alias libraries), so the drag-to-Applications layout is baked in WITHOUT
# driving Finder over AppleScript. That's the whole point: it produces the same
# styled window locally and on a headless CI runner, where Finder isn't available.
#
# Invoked by scripts/release.sh as:
#   dmgbuild -s scripts/dmg-settings.py \
#       -D app=<path/to/Wave.app> \
#       -D background=<path/to/dmg-background.png> \
#       "Wave" dist/Wave.dmg
#
# The icon coordinates and the 660x440 background must stay in lock-step with
# scripts/make-dmg-background.sh, which draws the arrow to land in the gap
# between the two icons. The window is 470pt tall (not 440): Finder anchors the
# background under the ~28pt title bar, so the window must clear the full 440pt
# image or its top (the headline) gets clipped.

import os.path

app = defines.get("app", "build/Wave.app")
appname = os.path.basename(app)

# ---- image ----
format = "UDZO"           # zlib-compressed, read-only — the standard ship format
compression_level = 9
filesystem = "HFS+"

# ---- contents ----
files = [app]
symlinks = {"Applications": "/Applications"}

# Deliberately NO custom volume icon: we want the mounted disk that appears on
# the Desktop to use the standard macOS disk-image icon, not the Wave app icon.
# (Setting `icon` here would write a .VolumeIcon.icns and override it.)

# ---- window ----
background = defines.get("background", "Resources/dmg-background.png")
window_rect = ((360, 200), (660, 470))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# ---- icon view ----
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 120
icon_locations = {
    appname: (185, 215),
    "Applications": (475, 215),
}
