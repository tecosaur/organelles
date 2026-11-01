# The site's metadata without any machine: the site layer and every app's and module's
# site.nix, evaluated alone with the flake's locked nixpkgs library, for what reads it outside
# a NixOS evaluation, such as secrets/secrets.nix and the scripts beside it. A site.nix reads
# only config.site, which is what makes this possible.

let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  lib = import "${fetchTarball {
    url = "https://github.com/${nixpkgs.owner}/${nixpkgs.repo}/archive/${nixpkgs.rev}.tar.gz";
    sha256 = nixpkgs.narHash;
  }}/lib";
  metadata = lib.concatMap (root: lib.concatMap (name:
      lib.optional (builtins.pathExists (root + "/${name}/site.nix")) (root + "/${name}/site.nix"))
    (lib.attrNames (builtins.readDir root))) [ ../apps ../modules ];
  evaluated = lib.evalModules {
    specialArgs.site-lib = import ./lib.nix { inherit lib; };
    modules = [ ./default.nix {
      # what the site layer sets of the system goes unread
      _module.check = false;
      _module.args.pkgs = throw "site/manifest.nix: the metadata needs no packages";
    } ] ++ metadata;
  };
in {
  inherit lib;
  inherit (evaluated.config) site;
}
