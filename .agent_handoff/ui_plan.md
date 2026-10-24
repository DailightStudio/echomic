# Home screen redesign — "stage + neon" (2026-10-24)

Files: `lib/main.dart` (theme), `lib/home_screen.dart` (layout + widgets). Do not change engine calls, state logic, analytics, prefs, or the `_MicLiveBanner` (App Review 2.5.14 — must stay always-on while running). Keep all existing Semantics/tooltips and add them for new controls. Korean UI text, formal tone.

## Problems seen on the current screen (emulator capture, 1080x2400)
1. The idle, disabled auto-tune pad (96 dp, full width) is the largest element on screen and pushes effects down; the 리버브 slider is cut by the bottom bar on first view.
2. The disabled 녹음 outlined button is grey-on-grey and reads as broken; no hint why.
3. Level meter is a lone empty bar between pad and presets; it belongs with the stage status.
4. Stock M3 purple everywhere; no visual identity; start button and record button compete in one row.

## Theme (main.dart)
- Dark only. Background `#0E0B14`; surfaces via `ColorScheme.fromSeed(seedColor: Color(0xFF9B5CFF), brightness: dark)` then `.copyWith(surface: Color(0xFF0E0B14), surfaceContainer: Color(0xFF17121F), surfaceContainerHigh: Color(0xFF1F1829), surfaceContainerHighest: Color(0xFF2A2236))`, `scaffoldBackgroundColor` = surface.
- Accents (put as `const` in a small `lib/ui_colors.dart` so both screens use one source): `kNeonA = Color(0xFF9B5CFF)`, `kNeonB = Color(0xFFFF4FA3)` (gradient pair for the start button / active meter), `kRec = Color(0xFFFF3B5C)`, `kTune = Color(0xFF2EE6D6)`.
- `sliderTheme`: trackHeight 4, thumb radius 9, overlay radius 18, activeTrack = kNeonA. `chipTheme`: StadiumBorder, selected color kNeonA at 25% alpha with kNeonA border. `appBarTheme`: transparent background, no elevation, centerTitle, titleTextStyle 18 sp w600. `cardTheme`: surfaceContainer, radius 20, elevation 0.

## Layout (top to bottom)
1. **AppBar** unchanged content (title + 녹음 목록 icon), styled by theme.
2. **Stage header** (existing `_StageHeader` photo): keep, and move the `_LevelMeter` INTO the header's bottom area (under the status text, horizontal padding 32). Meter fill uses the kNeonA→kNeonB gradient with a soft glow (BoxShadow kNeonB 40% alpha, blur 12) when level > 0. Keep it a ValueListenableBuilder on `_rmsLevel` so only it rebuilds. While running, draw a subtle pulsing glow ring behind the mic (AnimatedContainer/AnimationController, 1.6 s, low alpha) — skip if the header already animates something; keep cheap.
3. `_hint` text right under the header, unchanged behaviour.
4. **Effects card** (`Card`, margin h16): header row "효과" (titleMedium) ; preset chips in a horizontal `SingleChildScrollView` row with leading icons (노래방 `Icons.mic_external_on`, 콘서트홀 `Icons.stadium`, 동굴 `Icons.landscape`, 원음 `Icons.graphic_eq`) — map icon by preset name in the widget, do not change `_Preset`. Then the four sliders. `_SliderTile` made more compact: label + value on one row (value in kNeonA-tinted labelLarge with tabular figures), slider directly below with reduced vertical padding (total tile height ≈ 64 dp).
5. **Advanced card**: the existing `ExpansionTile` moved into its own `Card` (same margins), with `shape`/`collapsedShape` = no border, leading `Icons.tune`.
6. **Bottom control deck** (fixed, outside the scroll view, replaces the current Row): `Container` with surfaceContainerHigh, top radius 28, padding (16, 14, 16, 12), subtle top border white 6%. Three columns, each = control + 12 sp caption below:
   - Left — **녹음**: 60 dp circle. Idle+stopped: outline kRec at 35% alpha, red dot icon at 50% alpha, caption "녹음" plus small second line "시작 후 가능" (bodySmall, muted) so the disabled state explains itself. Running, not recording: outline kRec, solid red dot. Recording: filled kRec, white stop square icon, gentle pulse, caption shows `mm:ss` (existing `_recSeconds` ValueListenableBuilder).
   - Center — **시작/정지**: 84 dp circle, gradient kNeonA→kNeonB (stopped) or solid `cs.error` (running), white play/stop icon 40 dp, glow shadow; caption "시작"/"정지". Disabled while `_busy` (show small CircularProgressIndicator overlay).
   - Right — **오토튠**: 60 dp rounded-square (radius 18) DJ pad, using the existing `Listener` press/release logic of `_AutotunePad` (keep `_setTune` calls exactly). Idle: outline kTune 35% alpha, icon `Icons.graphic_eq`. Held/latched: filled kTune with outer glow (BoxShadow kTune 60%, blur 20), dark icon. Lock: small 24 dp circular badge at the pad's top-right corner (lock / lock_open) toggling `_setTune(latched:)`, with the existing tooltips. Caption "오토튠" + second line "누르는 동안" (or "고정됨" when latched). Disabled when not running, same muted treatment as record.
   - Remove the old full-width `_AutotunePad` from the scroll column (rewrite the class into the deck widget; no dead code left).
7. Ad: keep `Divider` + `SizedBox(height: 24)` + `AdBanner()` below the deck exactly as now (thumb-safety gap).

## Verify
`export PATH=/c/dev/flutter/bin:$PATH; flutter analyze` clean; `flutter build apk --release --target-platform android-x64` OK. Small screens: at 360x640 dp and text scale 1.3 the deck must not overflow (use FittedBox/Flexible on captions).
