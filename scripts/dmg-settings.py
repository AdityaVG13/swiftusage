# dmgbuild's settings for the disk image scripts/release.sh makes: the app beside a link to
# Applications, to drag it to, in a plain window without toolbars.
import os.path

app = defines["app"]

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

window_rect = ((200, 200), (560, 340))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (150, 150), "Applications": (410, 150)}
