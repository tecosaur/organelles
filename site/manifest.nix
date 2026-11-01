# The site's metadata without any machine: the site layer, the settings in ../site.nix, and
# every app's and module's site.nix, evaluated alone with the flake's locked nixpkgs library, for what reads it outside
# a NixOS evaluation, such as secrets/secrets.nix and the scripts beside it. A site.nix reads
# only config.site, which is what makes this possible.

let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  lib = import "${fetchTarball {
    url = "https://github.com/${nixpkgs.owner}/${nixpkgs.repo}/archive/${nixpkgs.rev}.tar.gz";
    sha256 = nixpkgs.narHash;
  }}/lib";
  site-lib = import ./lib.nix { inherit lib; };
  evaluated = lib.evalModules {
    specialArgs = { inherit site-lib; };
    modules = [ ./default.nix { site = import ../site.nix; } {
      # what the site layer sets of the system goes unread
      _module.check = false;
      _module.args.pkgs = throw "site/manifest.nix: the metadata needs no packages";
    } ] ++ site-lib.site-modules [ ../apps ../modules ];
  };
in {
  inherit lib;
  inherit (evaluated.config) site;
}
