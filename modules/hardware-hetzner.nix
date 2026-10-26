{ config, lib, pkgs, modulesPath, ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  # Postgres state is per major version; move it with upgrade-pg-cluster
  services.postgresql.package = pkgs.postgresql_14;
  # The NixOS manual's upgrade-pg-cluster, run once as root to move the
  # cluster to Postgres 18 before the pin follows. The new cluster takes the
  # old one's locale, encoding and checksum setting, which pg_upgrade
  # requires to match; Postgres 18 would otherwise enable checksums.
  environment.systemPackages = [
    (let
      cfg = config.services.postgresql;
      newPostgres = pkgs.postgresql_18;
    in pkgs.writeShellScriptBin "upgrade-pg-cluster" ''
      set -eux
      OLDDATA="${cfg.dataDir}" OLDBIN="${cfg.finalPackage}/bin"
      NEWDATA="/var/lib/postgresql/${newPostgres.psqlSchema}" NEWBIN="${newPostgres}/bin"
      template=$(runuser -u postgres -- "$OLDBIN/psql" -tA -F ' ' -c \
        "select datcollate, datctype, pg_encoding_to_char(encoding) from pg_database where datname = 'template1'")
      read -r collate ctype encoding <<< "$template"
      systemctl stop postgresql
      checksums=--data-checksums
      if runuser -u postgres -- "$OLDBIN/pg_controldata" "$OLDDATA" | grep -q 'checksum version: *0$'; then
        checksums=--no-data-checksums
      fi
      install -d -m 0700 -o postgres -g postgres "$NEWDATA"
      cd "$NEWDATA"
      runuser -u postgres -- "$NEWBIN/initdb" -D "$NEWDATA" --encoding="$encoding" \
        --lc-collate="$collate" --lc-ctype="$ctype" "$checksums" ${lib.escapeShellArgs cfg.initdbArgs}
      runuser -u postgres -- "$NEWBIN/pg_upgrade" \
        --old-datadir "$OLDDATA" --new-datadir "$NEWDATA" \
        --old-bindir "$OLDBIN" --new-bindir "$NEWBIN" "$@"
    '')
  ];

  boot = {
    initrd = {
      availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sd_mod" "sr_mod" ];
      kernelModules = [ "nvme" ];
    };
    kernel.sysctl = {
      "vm.swappiness" = 60;
      "net.core.rmem_max" = 8388608;
      "net.core.wmem_max" = 8388608;
    };
    kernelParams = [
      "console=tty1"
      "console=ttyS0,115200"
    ];
    extraModulePackages = [ ];
    loader.grub = {
      enable = true;
      device = "/dev/sda";
    };
  };

  fileSystems."/" =
    {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "btrfs";
      options = [ "subvol=@rootfs" "noatime" "compress=zstd" ];
    };

  fileSystems."/nix" =
    {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "btrfs";
      options = [ "subvol=@nix" "noatime" "compress=zstd" ];
    };


  fileSystems."/boot" =
    {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "btrfs";
      options = [ "subvol=@boot" "noatime" "compress=zstd" ];
    };

  fileSystems."/swap" = {
    device = "/dev/disk/by-label/NIXOS";
    fsType = "btrfs";
    options = [ "subvol=@swap" "noatime" "compress=zstd:1" ];
  };

  systemd.services = {
    create-swapfile = {
      serviceConfig.Type = "oneshot";
      wantedBy = [ "swap-swapfile.swap" ];
      script = ''
        ${pkgs.coreutils}/bin/truncate -s 0 /swap/swapfile
        ${pkgs.e2fsprogs}/bin/chattr +C /swap/swapfile
        ${pkgs.btrfs-progs}/bin/btrfs property set /swap/swapfile compression none
      '';
    };
  };

  swapDevices = [{
    device = "/swap/swapfile";
    size = (1024 * 2);
  }];

  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking = {
    enableIPv6 = true;
    usePredictableInterfaceNames = true;
    useNetworkd = true;
    useDHCP = true;
    dhcpcd.enable = false;
    timeServers = [
      "ntp1.hetzner.de"
      "ntp2.hetzner.com"
      "ntp3.hetzner.net"
    ];
  };

  systemd.network = {
    enable = true;
    wait-online.ignoredInterfaces =
      [ "lo" ] ++ (if config.services.tailscale.enable then [ "tailscale0" ] else []);
    networks."10-uplink" = {
      matchConfig.Name = "enp1s0";
      domains = [ config.site.domain ];
      # TODO: Remove once Hetzner supports router advertisement
      addresses = [ { Address = "${config.site.server.ipv6}::1/64"; } ];
      routes = [ { Gateway = "fe80::1"; GatewayOnLink = true; } ];
      dns = [ "2606:4700:4700::1111" # Cloudflare
              "2606:4700:4700::1001" ];
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      # ipv6AcceptRAConfig = {
      #   Token = "static::1";
      # };
    };
  };
}
