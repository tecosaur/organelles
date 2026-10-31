# Memos
svg2png logo.svg -h 115
cwebp -preset icon -near_lossless 60 -m 6 -metadata none logo.png -o logo.webp
rm logo.png
ln -sr logo.webp full-logo.webp
