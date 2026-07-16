<h1 align="center">lyra-dynamic-wallpaper</h1>

<!-- TODO: hero banner (assets/hero.jpg) — regenerate via make-image when an image backend is available -->

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://github.com/GeneralD/lyra-dynamic-wallpaper/actions/workflows/ci.yml/badge.svg" alt="CI">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License GPL-3.0">
  <a href="https://github.com/GeneralD/lyra"><img src="https://img.shields.io/badge/built%20on-LyraKit-8A63D2" alt="Built on LyraKit"></a>
</p>

Turn [lyra](https://github.com/GeneralD/lyra)'s video wallpapers into a macOS **Dynamic Desktop** — a time-of-day `.heic` that carries lyra's world onto the one surface no third-party code can reach: the **lock screen**.

The lock screen is drawn by `loginwindow` and hosts no third-party code, so neither lyra's live wallpaper nor [lyra-screensaver](https://github.com/GeneralD/lyra-screensaver) can appear there. A Dynamic Desktop HEIC can: macOS itself picks the frame matching the local clock, so the day flows through your configured videos — morning clips at dawn, night clips after dark.

## How it works

<a href="https://github.com/GeneralD/lyra/blob/main/docs/LyraKit.md"><img src="assets/lyrakit-icon-transparent.png" align="right" width="88" alt="LyraKit"></a>

1. Reads your existing lyra config (`~/.config/lyra/config.toml`, `[[wallpaper.items]]`) through [LyraKit](https://github.com/GeneralD/lyra) — the same library product lyra-screensaver links. No re-parsing, no re-implementation.
2. Resolves every item to its locally cached video using lyra's own resolve pipeline (YouTube/remote download, content-hash cache, SQLite dedup index).
3. Lays each item's **trim range** (`start`/`end`) end-to-end into one 24-hour timeline and samples N frames across it (frames are distributed proportionally to each clip's duration).
4. Renders each frame the way lyra shows it: aspect-fill to the output size, then the item's **`scale`** applied as a centered zoom.
5. Encodes a multi-image HEIC with `apple_desktop:h24` metadata — the schema Apple's own dynamic wallpapers use. Time-of-day based, no Location Services needed (unlike the `solar` schema).

> [!NOTE]
> A Dynamic Desktop is a time-keyed slideshow, **not motion**. More frames only make the time-of-day transition finer. macOS re-evaluates the wallpaper on its own schedule, so frame changes are not guaranteed to be minute-exact.

## Install

```sh
brew install GeneralD/tap/lyra-dynamic-wallpaper   # also installs lyra itself
```

Or build from source:

```sh
git clone https://github.com/GeneralD/lyra-dynamic-wallpaper.git
cd lyra-dynamic-wallpaper
make install   # builds release and installs to /usr/local/bin
```

Requires macOS 14+, a lyra config with `[wallpaper]` items, and (only for videos not yet cached by lyra) `yt-dlp` on `PATH`.

## Usage

```sh
# 1440 frames (one per minute of the day), 2560x1440, saved to ~/Pictures
lyra-dynamic-wallpaper

# fewer frames, custom size and destination
lyra-dynamic-wallpaper -n 480 -r 3024x1964 -o ~/Documents/lyra-day.heic

# generate and set as desktop wallpaper in one go (lock screen follows)
lyra-dynamic-wallpaper --apply
```

| Option | Default | Description |
|---|---|---|
| `-n, --frames` | `1440` | Frames mapped across the 24h day |
| `-o, --output` | `~/Pictures/lyra-dynamic-wallpaper.heic` | Output path |
| `-r, --resize` | `2560x1440` | Output frame size `WxH` |
| `-q, --quality` | `0.7` | HEIC quality (0–1] |
| `--apply` | off | Set as desktop wallpaper on every screen |

For the lock screen: setting the desktop wallpaper is enough on default setups (the lock screen follows the desktop). If you've customised them separately, add the generated `.heic` via **System Settings › Wallpaper**.

## Sizing guide

At 2560×1440 / quality 0.7 (measured on real lyra footage):

| Frames | Granularity | File size |
|---|---|---|
| 480 | ~3 min | ~30 MB |
| 1440 | ~1 min | ~110 MB |

## Related

- [lyra](https://github.com/GeneralD/lyra) — the lyrics & video wallpaper overlay this tool feeds on (tracking issue: [lyra#325](https://github.com/GeneralD/lyra/issues/325))
- [lyra-screensaver](https://github.com/GeneralD/lyra-screensaver) — the same wallpapers as a screen saver

## License

[GPL-3.0](LICENSE)
