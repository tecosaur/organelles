{ config, lib, ... }:

{
  options.site.unfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "sftpgo" ];
    description = "Names of the unfree packages this host may install, each named by the module needing it";
  };
  config.nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) config.site.unfree;
}
