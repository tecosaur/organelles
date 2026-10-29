{ accent }:

# Gatus's look in the site's own: monospace throughout, surfaces tinted
# from the accent in OKLCH exactly as the landing page's are, the accent
# for "healthy" and for anything interactive, a quiet red beside it.
# Gatus wraps each colour token as hsl(var(--token)), so a token holding
# relative colour syntax leaves the conversion to the browser. Gatus links
# this sheet before its own, which sets the same tokens on :root, so these
# sit on html:root to outrank them.

let
  tint = l: c: "from oklch(from ${accent.primary} ${l} ${c} h) h s l";
  primary = "from ${accent.primary} h s l";
  # on a dark ground the accent at full strength glares: soften and darken it
  dark-accent = "from ${accent.primary} h calc(s * 0.77) 50";
  red = "4 68% 52%";
in ''
  html:root {
    --background: ${tint "0.98" "0.025"};
    --foreground: ${tint "0.22" "0.03"};
    --card: ${tint "0.99" "0.015"};
    --card-foreground: ${tint "0.22" "0.03"};
    --popover: ${tint "0.99" "0.015"};
    --popover-foreground: ${tint "0.22" "0.03"};
    --primary: ${primary};
    --primary-foreground: 0 0% 100%;
    --secondary: ${tint "0.95" "0.03"};
    --secondary-foreground: ${tint "0.25" "0.03"};
    --muted: ${tint "0.95" "0.02"};
    --muted-foreground: ${tint "0.5" "0.02"};
    --accent: ${tint "0.93" "0.035"};
    --accent-foreground: ${tint "0.25" "0.03"};
    --destructive: ${red};
    --destructive-foreground: 0 0% 100%;
    --border: ${tint "0.9" "0.03"};
    --input: ${tint "0.9" "0.03"};
    --ring: ${primary};
    --radius: 0.38rem;
  }
  html:root.dark {
    --background: ${tint "0.21" "0.025"};
    --foreground: 0 0% 96%;
    --card: ${tint "0.245" "0.025"};
    --card-foreground: 0 0% 96%;
    --popover: ${tint "0.245" "0.025"};
    --popover-foreground: 0 0% 96%;
    --primary: ${dark-accent};
    --primary-foreground: ${tint "0.17" "0.03"};
    --secondary: ${tint "0.29" "0.025"};
    --secondary-foreground: 0 0% 96%;
    --muted: ${tint "0.29" "0.025"};
    --muted-foreground: ${tint "0.72" "0.02"};
    --accent: ${tint "0.31" "0.03"};
    --accent-foreground: 0 0% 96%;
    --destructive: ${red};
    --destructive-foreground: 0 0% 100%;
    --border: ${tint "0.33" "0.025"};
    --input: ${tint "0.33" "0.025"};
    --ring: ${dark-accent};
  }
  body, button, input, select, textarea, code {
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  }
  ::selection { background: hsl(var(--primary) / 0.33); }
  .bg-green-500, .bg-green-600 { background-color: hsl(var(--primary)) !important; }
  .text-green-500, .text-green-600 { color: hsl(var(--primary)) !important; }
  .bg-red-500, .bg-red-600 { background-color: hsl(${red}) !important; }
  .text-red-500, .text-red-600 { color: hsl(${red}) !important; }
  /* the announcement as a line of text, without its banner */
  .announcement-header { display: none; }
  .announcement-content { padding: 0; }
  .announcement-container > .border { border: none; box-shadow: none; }
  .announcement-container > .bg-card { background: none; }
  .announcement-content > div > div > div > div.items-center > div { background: hsl(var(--card)); }
  #social { display: none; }
  /* names in the announcement link to their rows, quietly */
  .announcement-content a { color: inherit !important; font-weight: inherit !important; text-decoration: none !important; }
  .announcement-content a:hover { text-decoration: underline !important; }
''
