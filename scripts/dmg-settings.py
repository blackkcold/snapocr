from pathlib import Path

app_path = Path(defines["app_path"]).resolve()
background_path = Path(defines["background_path"]).resolve()
icon_path = Path(defines["icon_path"]).resolve()

format = "UDZO"
filesystem = "HFS+"
size = None

files = [str(app_path)]
symlinks = {"Applications": "/Applications"}

background = str(background_path)
icon = str(icon_path)
badge_icon = str(icon_path)

window_rect = ((220, 180), (800, 500))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 16
label_pos = "bottom"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100

icon_locations = {
    "SnapGlass.app": (180, 255),
    "Applications": (620, 255),
}
