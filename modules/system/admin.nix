{ config, pkgs, ... }:

{
  services.openssh = {
    enable = true;
    ports = [ config.site.ports.ssh.port ];
    openFirewall = false;
  };

  users.users.admin = {
    name = "admin";
    hashedPassword = config.site.server.admin.hashedPassword;
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = config.site.server.admin.authorizedKeys;
  };
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [ "@wheel" ]; # https://github.com/serokell/deploy-rs/issues/25
}
