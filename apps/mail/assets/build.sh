# Bulwark, at the paths it serves its own icons from
svg2png bulwark/favicon.svg bulwark/icon-192x192.png -h 192
svg2png bulwark/favicon.svg bulwark/icon-512x512.png -h 512
svg2png bulwark/favicon.svg bulwark/apple-touch-icon.png -h 180
for size in 192 512; do
    svg2maskable bulwark/favicon.svg "bulwark/icon-maskable-light-${size}x${size}.png" "$size" '#ffffff'
    svg2maskable bulwark/favicon.svg "bulwark/icon-maskable-dark-${size}x${size}.png" "$size" '#18181b'
done

# Stalwart
favmake stalwart
