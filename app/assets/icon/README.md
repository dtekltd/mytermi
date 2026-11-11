# App icon

A green `>_` prompt on the app's dark navy background.

| Source | Used for |
|---|---|
| `icon.svg` | iOS, plus the Android legacy (pre-8.0) icon. Full-bleed square, no transparency, because the OS applies the mask. |
| `icon_background.svg`, `icon_foreground.svg` | Android adaptive icon layers. The glyph sits inside the safe zone. |
| `icon_monochrome.svg` | Android 13+ themed icon. White, single-layer. |
| `icon_desktop.svg` | Windows. Rounded tile with transparent corners. |

The PNGs next to the SVGs are generated. To change the icon, edit the SVGs, then run:

```sh
cd app/tool
npm i --no-save playwright && npx playwright install chromium
node render_icons.mjs                 # PNGs + windows/runner/resources/app_icon.ico
cd .. && dart run flutter_launcher_icons
git checkout ios/Runner.xcodeproj/project.pbxproj
```

The last line undoes a bug in flutter_launcher_icons 0.14: it sets
`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon` in the Xcode project.
