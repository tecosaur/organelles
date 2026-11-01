# The site's metadata without any machine, for what reads it outside NixOS, such as
# secrets/secrets.nix. It works because a site.nix reads only config.site.

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
