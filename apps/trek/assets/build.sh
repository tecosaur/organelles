# TREK
mkdir -p icons
svgfmt logo.svg
cp logo.svg icons/icon.svg
svg2png logo.svg icons/icon-192x192.png -h 192
svg2png logo.svg icons/icon-512x512.png -h 512
svg2png logo.svg icons/apple-touch-icon-180x180.png -h 180
