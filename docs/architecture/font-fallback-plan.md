# Bundled Nerd Font symbol fallback

Provide Nerd Font Private Use Area glyph coverage without requiring users to
install or select a particular primary terminal font. Keep the fallback local
to ttyrtle, preserve normal DirectWrite system fallback for other scripts, and
ship the font's required licensing material with the application.

## Implementation status

Complete. The build installs Symbols Nerd Font Mono beside the executable and
its OFL license under `assets/fonts/`. The DirectWrite fallback chain gives the
bundled face priority for Private Use Area symbols while retaining system font
fallback for other missing glyphs. `THIRD_PARTY_NOTICES.md` records the bundled
font and license.

Choosing a better primary terminal font remains separate configuration and
appearance work.
