{ accent }:

# The web vault's blues re-derived from the site's accent in OKLCH, its
# slate greys tinted the same way. The newer tokens read hex palettes by
# var(); the older ones are bare "r g b" triplets read as rgb(var(--x) / a),
# so they hold "from <colour> r g b" and the browser converts. html:root and
# html.theme_dark outrank the vault's own :root and .theme_dark.

let
  shade = l: c: "oklch(from ${accent.primary} ${l} calc(c * ${c}) h)";
  tint = l: c: "oklch(from ${accent.primary} ${l} ${c} h)";
  rgb = colour: "from ${colour} r g b";
  palette = name: steps: builtins.concatStringsSep "\n  " (map (s: "--color-${name}-${s.n}: ${s.v};") steps);
  brand = palette "brand" [
    { n = "050"; v = shade "0.97" "0.15"; }
    { n = "100"; v = shade "0.93" "0.3"; }
    { n = "200"; v = shade "0.88" "0.45"; }
    { n = "300"; v = shade "0.81" "0.65"; }
    { n = "400"; v = shade "0.74" "0.85"; }
    { n = "500"; v = shade "0.64" "1"; }
    { n = "600"; v = shade "0.57" "1"; }
    { n = "700"; v = shade "0.47" "0.9"; }
    { n = "800"; v = shade "0.41" "0.85"; }
    { n = "900"; v = shade "0.34" "0.7"; }
    { n = "950"; v = shade "0.28" "0.55"; }
  ];
  gray = palette "gray" [
    { n = "050"; v = tint "0.985" "0.004"; }
    { n = "100"; v = tint "0.94" "0.01"; }
    { n = "200"; v = tint "0.9" "0.012"; }
    { n = "300"; v = tint "0.82" "0.015"; }
    { n = "400"; v = tint "0.68" "0.018"; }
    { n = "500"; v = tint "0.55" "0.02"; }
    { n = "600"; v = tint "0.45" "0.02"; }
    { n = "700"; v = tint "0.37" "0.02"; }
    { n = "800"; v = tint "0.28" "0.02"; }
    { n = "900"; v = tint "0.21" "0.02"; }
    { n = "950"; v = tint "0.13" "0.015"; }
  ];
in ''
  html:root {
    ${brand}
    ${gray}
    --color-primary-100: ${rgb (shade "0.93" "0.3")};
    --color-primary-600: ${rgb (shade "0.47" "0.9")};
    --color-primary-700: ${rgb (shade "0.38" "0.8")};
    --color-background-alt: ${rgb (tint "0.97" "0.008")};
    --color-background-alt2: ${rgb (shade "0.47" "0.9")};
    --color-secondary-100: ${rgb (tint "0.93" "0.01")};
    --color-secondary-300: ${rgb (tint "0.76" "0.015")};
    --color-secondary-500: ${rgb (tint "0.53" "0.02")};
    --color-secondary-600: ${rgb (tint "0.48" "0.02")};
    --color-secondary-700: ${rgb (tint "0.4" "0.02")};
    --color-text-main: ${rgb (tint "0.24" "0.015")};
    --color-text-muted: ${rgb (tint "0.52" "0.02")};
    --color-shadow: ${rgb (tint "0.76" "0.015")};
    --color-hover-default: rgb(${rgb (shade "0.47" "0.9")} / 0.1);
    --color-bw-blue: ${rgb (shade "0.5" "1")};
    --color-illustration-outline: ${rgb (shade "0.28" "0.55")};
    --color-illustration-bg-primary: ${rgb (shade "0.93" "0.3")};
    --color-illustration-bg-secondary: ${rgb (shade "0.84" "0.55")};
    --color-illustration-logo: ${rgb (shade "0.5" "1")};
  }
  html.theme_dark {
    --color-background: ${rgb (tint "0.25" "0.02")};
    --color-background-alt: ${rgb (tint "0.2" "0.02")};
    --color-background-alt2: ${rgb (tint "0.31" "0.02")};
    --color-background-alt3: ${rgb (tint "0.33" "0.02")};
    --color-background-alt4: ${rgb (tint "0.2" "0.02")};
    --color-primary-100: ${rgb (shade "0.3" "0.45")};
    --color-primary-300: ${rgb (shade "0.45" "0.8")};
    --color-primary-600: ${rgb (shade "0.74" "0.75")};
    --color-primary-700: ${rgb (shade "0.85" "0.45")};
    --color-secondary-100: ${rgb (tint "0.33" "0.02")};
    --color-secondary-300: ${rgb (tint "0.45" "0.02")};
    --color-secondary-500: ${rgb (tint "0.6" "0.018")};
    --color-secondary-600: ${rgb (tint "0.67" "0.016")};
    --color-secondary-700: ${rgb (tint "0.72" "0.014")};
    --color-text-main: ${rgb (tint "0.96" "0.006")};
    --color-text-muted: ${rgb (tint "0.68" "0.018")};
    --color-text-contrast: ${rgb (tint "0.2" "0.02")};
    --color-hover-default: rgb(${rgb (shade "0.85" "0.45")} / 0.1);
    --color-bw-blue: ${rgb (shade "0.5" "1")};
    --color-illustration-outline: ${rgb (shade "0.5" "1")};
    --color-illustration-bg-primary: ${rgb (shade "0.85" "0.45")};
    --color-illustration-bg-secondary: ${rgb (shade "0.74" "0.75")};
  }
''
