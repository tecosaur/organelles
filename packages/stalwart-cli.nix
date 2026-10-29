# stalwart-cli 1.0.14, the first to read Stalwart 1.0's schema (its `sieve` field format); yields to nixpkgs once it catches up.
{ lib, stalwart-cli, fetchFromGitHub, rustPlatform }:

if lib.versionAtLeast stalwart-cli.version "1.0.14"
then lib.warn "nixpkgs' stalwart-cli has caught up: delete packages/stalwart-cli.nix and use pkgs.stalwart-cli directly." stalwart-cli
else
stalwart-cli.overrideAttrs (finalAttrs: _: {
  version = "1.0.14";
  src = fetchFromGitHub {
    owner = "stalwartlabs";
    repo = "cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-3SotRkEDIrI3hgYFjAkkKhCZoD/woXreLshBaLr0Y2c=";
  };
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-/vYb083UVPDZQpDWh16XkMWk+n9081OiV9S1i1om5zQ=";
  };
})
