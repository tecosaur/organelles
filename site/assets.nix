{ lib, pkgs, stdenvNoCC, primary, secondary }:

# TODO: Investigate using <https://github.com/jtippet/IcoTools> for
# smaller .ico files. See: <https://github.com/oxipng/oxipng/issues/440>.

let
  primary-standin = "#e66100";
  secondary-standin = "#1c71d8";
  theme-envs = lib.concatStringsSep " " [
    "PRIMARY_STANDIN='${primary-standin}'"
    "SECONDARY_STANDIN='${secondary-standin}'"
    "PRIMARY_COLOR='${primary}'"
    "SECONDARY_COLOR='${secondary}'"
  ];
  # Every app's and module's assets/, each under its folder's name, built by its own build.sh;
  # a favicon.svg beside an app's default.nix counts as one in its assets/
  owners = lib.concatMap (root: let entries = builtins.readDir root; in
    lib.concatMap (name: let
      dir = root + "/${name}";
      assets = lib.optional (builtins.pathExists (dir + "/assets")) (dir + "/assets");
      favicon = lib.optional (builtins.pathExists (dir + "/favicon.svg")) (dir + "/favicon.svg");
    in if favicon != [ ] && builtins.pathExists (dir + "/assets/favicon.svg")
      then throw "site-assets: ${name} has both favicon.svg and assets/favicon.svg; keep one"
      else lib.optional (assets != [ ] || favicon != [ ]) { inherit name assets favicon; })
      (lib.filter (name: entries.${name} == "directory") (lib.attrNames entries)))
    [ ../apps ../modules ];
  build = pkgs.writeText "build-assets.sh" ''
    ${builtins.readFile ./assets.sh}
    for dir in */; do
      if [ -f "$dir/build.sh" ]; then
        (cd "$dir" && source ./build.sh)
        rm "$dir/build.sh"
      fi
    done
  '';
in stdenvNoCC.mkDerivation {
  name = "site-assets";
  version = "1.0";

  dontUnpack = true;

  nativeBuildInputs = with pkgs; [ bash gnused svgo librsvg libwebp pngquant oxipng python313Packages.pillow ];

  buildPhase = ''
    mkdir tree && cd tree
    ${lib.concatMapStrings (owner: ''
      mkdir -p ${owner.name}
      ${lib.concatMapStrings (path: "cp -r ${path}/. ${owner.name}/\n") owner.assets}
      ${lib.concatMapStrings (path: "cp ${path} ${owner.name}/favicon.svg\n") owner.favicon}
    '') owners}
    chmod -R u+w .
    ${theme-envs} bash ${build}
  '';

  installPhase = ''
    mkdir -p $out
    cp -r "$NIX_BUILD_TOP/tree/." $out
  '';
}
