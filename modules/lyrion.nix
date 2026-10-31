{ config, lib, pkgs, ... }:

let
  lyrion-domains = [ "music.lan" "local.music" ];
  music-dir = "/data/media/music";
  inherit (config.site) ports;
  # GCC 16 vectorises Image::Scale's cos() into libmvec calls, but the module
  # links without -lm, so it fails to load with an undefined _ZGVbN2v_cos.
  perlPackages = pkgs.perlPackages.overrideScope (_: super: {
    ImageScale = super.ImageScale.overrideAttrs { NIX_LDFLAGS = "-lm"; };
  });
  patched-slimserver = (pkgs.slimserver.override { inherit perlPackages; }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Temporary workaround for SQLite/FTS corruption.
      rm -rf Slim/Plugin/FullTextSearch
    '';
  });
in {
  services.slimserver = {
    enable = true;
    package = patched-slimserver;
  };

  systemd.services.slimserver = {
    path = [ pkgs.yt-dlp pkgs.deno ];
    serviceConfig = {
      # players reach slimproto on 3483 regardless, so only these two are settable
      ExecStart = lib.mkForce (lib.escapeShellArgs [
        (lib.getExe patched-slimserver)
        "--logdir" "${config.services.slimserver.dataDir}/logs"
        "--prefsdir" "${config.services.slimserver.dataDir}/prefs"
        "--cachedir" "${config.services.slimserver.dataDir}/cache"
        "--noimage" "--novideo"
        "--httpport" (toString ports.lyrion-web.port)
        "--cliport" (toString ports.lyrion-cli.port)
      ]);
      NoNewPrivileges = true;
      LockPersonality = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateUsers = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      ProtectClock = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RemoveIPC = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = true;
      StateDirectory = "slimserver";
      ReadOnlyPaths = [ music-dir "/nix" ];
      ReadWritePaths = [ "/var/lib/slimserver" ];
      UMask = "0077";
      DevicePolicy = "closed";
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        " " # This is needed to clear the SystemCallFilter existing definitions
        "~@reboot"
        "~@swap"
        "~@obsolete"
        "~@mount"
        "~@module"
        "~@debug"
        "~@cpu-emulation"
        "~@clock"
        "~@raw-io"
        "~@privileged"
      ];
      CapabilityBoundingSet = [ " " "CAP_NET_BROADCAST" ];
    };
  };

  services.caddy.virtualHosts = lib.mkMerge (map (domain: {
    "http://${domain}".extraConfig =
      ''
      handle /html/images/icon* {
          uri strip_prefix /html/images/
          root ${config.site.assets}/lyrion
          file_server
      }
      reverse_proxy :${toString ports.lyrion-web.port}
      '';
  }) lyrion-domains);
}
