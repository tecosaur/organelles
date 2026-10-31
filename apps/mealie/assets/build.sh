# Mealie
favmake .
svg2png favicon.svg icon-x64.png -h 64
svg2png favicon.svg android-chrome-192x192.png -h 192
svg2png favicon.svg android-chrome-512x512.png -h 512
svg2png apple-touch-icon.svg -h 180
rm favicon.svg apple-touch-icon.svg
svg2png icon-maskable.svg android-chrome-maskable-192x192.png -h 192
svg2png icon-maskable.svg android-chrome-maskable-512x512.png -h 512
rm icon-maskable.svg
svg2png calendar-multiselect.svg mdiFormatListChecks-96x96.png -h 96
svg2png calendar-multiselect.svg mdiFormatListChecks-192x192.png -h 192
rm calendar-multiselect.svg
svg2png format-list-checks.svg mdiFormatListChecks-96x96-alt.png -h 96
svg2png format-list-checks.svg mdiFormatListChecks-192x192-alt.png -h 192
rm format-list-checks.svg
