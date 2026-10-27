# An Oracle Cloud Always Free x86 micro (`VM.Standard.E2.1.Micro`: an eighth
# of an OCPU, 1 GB), installed from Oracle's Ubuntu image by `nixos-infect`.
# Its disks keep that image's labels, the same on every instance made from it.
#
# Oracle offers no NixOS image. On a fresh Ubuntu instance, as root, the
# script below installs one. `nixos-infect` alone leaves an unbootable system:
# it relies on stage 1 honouring `/etc/NIXOS_LUSTRATE`, which only the
# scripted stage 1 (removed in 26.11) does, so the script adds a systemd
# stage 1 unit doing the same; and Ubuntu's in-memory `/tmp` starves it of
# swap. Run it from this checkout, inside `tmux` so a dropped connection
# doesn't end a long install:
#
# Copy this install script with:
#  `sed -n -e 's/^#   //p' -e 's/^#$//p' modules/hardware-oracle.nix | ssh ubuntu@<ip> 'cat > install.sh'`
# Then `ssh` to the instance, run `sudo -i`, and then `bash /home/ubuntu/install.sh`.
#
#   #!/usr/bin/env bash
#   # Turn a fresh Oracle Cloud Ubuntu instance into NixOS 26.05, as root.
#   # Set REBOOT=0 to stop before rebooting.
#   set -euo pipefail
#
#   CHANNEL=nixos-26.05
#   SWAP_SIZE=2G
#
#   [ "$(id -u)" -eq 0 ] || { echo "run as root (sudo -i)" >&2; exit 1; }
#
#   echo "== /tmp onto the disk: Ubuntu mounts it in RAM, where swap is useless"
#   systemctl mask tmp.mount
#   if [ "$(findmnt -no FSTYPE /tmp || true)" = tmpfs ]; then
#     umount /tmp || umount -l /tmp
#   fi
#
#   echo "== swap on the disk, so evaluating NixOS fits in 1 GB"
#   if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
#     [ -e /swapfile ] || { fallocate -l "$SWAP_SIZE" /swapfile && chmod 600 /swapfile && mkswap /swapfile; }
#     swapon /swapfile
#   fi
#   free -m
#
#   echo "== nixos-infect, without its reboot"
#   curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect \
#     | NO_REBOOT=1 NIX_CHANNEL="$CHANNEL" bash -x 2>&1 | tee /root/infect.log
#   # nixos-infect ends with `swapoff -a`, taking ours down with its own
#   swapon /swapfile
#
#   echo "== lustration in the systemd stage 1"
#   # nixos-infect leaves /etc/NIXOS_LUSTRATE for stage 1 to move Ubuntu aside
#   # on the first boot, but only the scripted stage 1 (removed in 26.11) does;
#   # this unit does the same in the systemd one
#   cat > /etc/nixos/lustrate.nix <<'EOF'
#   {
#     boot.initrd.systemd.services.lustrate-root = {
#       description = "Move the previous system's root into /old-root";
#       unitConfig = {
#         DefaultDependencies = false;
#         ConditionPathExists = "/sysroot/etc/NIXOS_LUSTRATE";
#       };
#       # straight after the root mounts, before anything mounts beneath it or
#       # reads its /etc
#       after = [ "sysroot.mount" ];
#       before = [ "initrd-root-fs.target" "initrd-parse-etc.service" "sysroot-run.mount" ];
#       requiredBy = [ "initrd-root-fs.target" ];
#       serviceConfig.Type = "oneshot";
#       script = ''
#         set -eu
#         root=/sysroot
#         echo "lustrating the root filesystem: cruft goes to /old-root"
#         mkdir -m 0755 -p $root/old-root.tmp
#         for d in $root/*; do
#           case $d in
#             $root/nix | $root/boot | $root/swapfile | $root/old-root.tmp) ;;
#             *) mv "$d" $root/old-root.tmp/ ;;
#           esac
#         done
#         mv $root/old-root.tmp $root/old-root
#         mkdir -m 0755 -p $root/etc
#         touch $root/etc/NIXOS
#         while read -r keeper; do
#           [ -n "$keeper" ] || continue
#           mkdir -m 0755 -p "$root/$(dirname "$keeper")"
#           cp -a "$root/old-root/$keeper" "$root/$keeper"
#         done < $root/old-root/etc/NIXOS_LUSTRATE
#       '';
#     };
#   }
#   EOF
#
#   echo "== hardware configuration from the live disks"
#   uuid() { findmnt -no UUID "$1"; }
#   ROOT_UUID=$(uuid /)
#   EFI_UUID=$(uuid /boot/efi)
#   BOOT_FS=""
#   if mountpoint -q /boot; then
#     BOOT_FS="fileSystems.\"/boot\" = { device = \"/dev/disk/by-uuid/$(uuid /boot)\"; fsType = \"$(findmnt -no FSTYPE /boot)\"; };"
#   fi
#   cat > /etc/nixos/hardware-configuration.nix <<EOF
#   { modulesPath, ... }:
#   {
#     imports = [ (modulesPath + "/profiles/qemu-guest.nix") ./lustrate.nix ];
#     boot.loader = {
#       efi.efiSysMountPoint = "/boot/efi";
#       grub = {
#         efiSupport = true;
#         efiInstallAsRemovable = true;
#         device = "nodev";
#         # the menu on the serial console too, where Oracle's console shows it
#         extraConfig = ''
#           serial --unit=0 --speed=115200
#           terminal_input serial console
#           terminal_output serial console
#         '';
#       };
#     };
#     boot.kernelParams = [ "console=tty1" "console=ttyS0,115200" ];
#     boot.initrd.availableKernelModules = [ "virtio_scsi" "sd_mod" "ata_piix" "uhci_hcd" ];
#     fileSystems."/" = { device = "/dev/disk/by-uuid/${ROOT_UUID}"; fsType = "$(findmnt -no FSTYPE /)"; };
#     ${BOOT_FS}
#     fileSystems."/boot/efi" = { device = "/dev/disk/by-uuid/${EFI_UUID}"; fsType = "vfat"; };
#     swapDevices = [ { device = "/swapfile"; } ];
#   }
#   EOF
#   sed -i -E 's/system\.stateVersion = "[0-9.]+";/system.stateVersion = "26.05";/' /etc/nixos/configuration.nix
#
#   [ -f /etc/NIXOS_LUSTRATE ] || { echo "nixos-infect left no /etc/NIXOS_LUSTRATE" >&2; exit 1; }
#
#   echo "== build the boot configuration"
#   export PATH=/nix/var/nix/profiles/system/sw/bin:/root/.nix-profile/bin:$PATH
#   export NIX_PATH=nixpkgs=/root/.nix-defexpr/channels/nixos:nixos-config=/etc/nixos/configuration.nix
#   nixos-rebuild boot --option max-jobs 1 --option cores 1 --option http-connections 4
#
#   cat /etc/nixos/hardware-configuration.nix
#   echo "== ready: the first boot moves Ubuntu into /old-root"
#   if [ "${REBOOT:-1}" = 1 ]; then
#     echo "rebooting in 10 s (Ctrl-C to stop)"; sleep 10; reboot
#   fi
#
# Once it boots, the first deploy from this flake replaces that bootstrap
# configuration with this module; lustration only ever happens once. Make
# that deploy by address, as root, without rollback:
#
#   deploy .#<host> --hostname <ip> --ssh-user root --magic-rollback false --auto-rollback false
#
# The host's record doesn't exist until its dns-pooler first runs, and its
# admin user until this deploy creates it. Rollback can't work yet either:
# it re-activates the previous generation through deploy-rs's wrapper, which
# the bootstrap generation lacks, and an eighth of an OCPU can miss the
# confirmation timeout on the first switch. Later deploys run as usual.
# `/old-root` then holds Ubuntu, to delete. For a later release, change
# `CHANNEL`.

{ config, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  boot = {
    initrd.availableKernelModules = [ "virtio_scsi" "sd_mod" "ata_piix" "uhci_hcd" ];
    # Oracle's console history and serial console read ttyS0
    kernelParams = [ "console=tty1" "console=ttyS0,115200" ];
    loader = {
      efi.efiSysMountPoint = "/boot/efi";
      grub = {
        enable = true;
        efiSupport = true;
        # the firmware's one boot entry loads the removable path
        efiInstallAsRemovable = true;
        device = "nodev";
        extraConfig = ''
          serial --unit=0 --speed=115200
          terminal_input serial console
          terminal_output serial console
        '';
      };
    };
  };

  fileSystems."/" = { device = "/dev/disk/by-label/cloudimg-rootfs"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/BOOT"; fsType = "ext4"; };
  fileSystems."/boot/efi" = { device = "/dev/disk/by-label/UEFI"; fsType = "vfat"; };

  # 1 GB holds little besides a witness's daemons; activations need room
  swapDevices = [ { device = "/swapfile"; size = 2048; } ];
  zramSwap.enable = true;

  networking = {
    useNetworkd = true;
    useDHCP = true;
    dhcpcd.enable = false;
    # Oracle's metadata service answers NTP
    timeServers = [ "169.254.169.254" ];
  };

  systemd.network = {
    enable = true;
    wait-online.ignoredInterfaces =
      [ "lo" ] ++ (if config.services.tailscale.enable then [ "tailscale0" ] else []);
    # the public address is NATed onto this private one; IPv6, if the
    # virtual network has a prefix, arrives on the interface itself
    networks."10-uplink" = {
      matchConfig.Name = "ens3";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
    };
  };
}
