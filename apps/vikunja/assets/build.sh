# Vikunja
favmake public
mkdir -p public/images/icons
svg2png public/icon-maskable.svg public/images/icons/android-chrome-192x192.png -h 192
svg2png public/icon-maskable.svg public/images/icons/android-chrome-512x512.png -h 512
svg2png public/icon-maskable.svg public/images/icons/apple-touch-icon-180x180.png -h 180
ln -sr public/images/icons/apple-touch-icon-180x180.png public/images/icons/icon-maskable.png
svgfmt frontend/llama.svg
svgfmt frontend/llama-cool.svg
svgfmt frontend/logo.svg
svgfmt frontend/logo-full.svg
