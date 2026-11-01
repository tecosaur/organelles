{ config, lib, pkgs, ... }:

let
  immich-domain = "${config.site.apps.immich.subdomain}.${config.site.domain}";
  immich-data = "/data/immich";
  ml-port = config.site.apps.immich.ports.machine-learning.port;
in {
  site.apps.immich.enabled = true;

  age.secrets = {
    immich-oidc = {
      owner = "immich";
      file = config.site.apps.immich.auth.clients.immich.secret.file;
    };
  };

  services.immich = {
    enable = true;
    openFirewall = false;
    host = "0.0.0.0";
    port = config.site.apps.immich.port;
    mediaLocation = immich-data;
    settings = {
      oauth = {
        enabled = true;
        autoLaunch = true;
        autoRegister = true;
        buttonText = "Login";
        clientId = "immich";
        clientSecret._secret = config.age.secrets.immich-oidc.path;
        issuerUrl = "https://${config.site.apps.authelia.subdomain}.${config.site.domain}/.well-known/openid-configuration";
        scope = "openid email profile";
        signingAlgorithm = "RS256";
        profileSigningAlgorithm = "none";
        storageLabelClaim = "preferred_username";
        storageQuotaClaim = "immich_quota";
      };
      passwordLogin = {
        enabled = false;
      };
      server = {
        externalDomain = "https://${immich-domain}";
      };
      storageTemplate = {
        enabled = true;
        hashVerificationEnabled = true;
        template = "{{#if album}}{{{album}}}{{else}}Unsorted{{/if}}/{{y}}/{{MM}}-{{MMM}}/{{y}}-{{MM}}-{{dd}}-{{filename}}";
      };
      machineLearning = {
        clip = {
          enabled = true;
          modelName = "ViT-B-16-SigLIP2__webli";
        };
        duplicateDetection.maxDistance = 0.02;
        ocr.modelName = "PP-OCRv6_small";
        facialRecognition = {
          minScore = 0.4;
          maxDistance = 0.55;
          minFaces = 8;
        };
      };
      notifications.smtp = {
        enabled = true;
        from = "Immich on ${config.site.domain} <${config.site.mail.connections.immich.from}>";
        replyTo = lib.mkIf (config.site.mail.connections.immich.reply-to != null) config.site.mail.connections.immich.reply-to;
        transport = {
          ignoreCert = false;
          inherit (config.site.mail.connections.immich) host port;
        };
      };
    };
    # nixpkgs fixes the machine-learning port
    environment.IMMICH_MACHINE_LEARNING_URL = lib.mkForce "http://localhost:${toString ml-port}";
    machine-learning = {
      enable = true;
      environment = {
        IMMICH_PORT = lib.mkForce (toString ml-port);
        # HSA_OVERRIDE_GFX_VERSION = "11.0.0";
        # HSA_USE_SVM = "0";
        # MACHINE_LEARNING_DEVICE_IDS = "0";
        MACHINE_LEARNING_MODEL_TTL = "0"; # Never expire
        MACHINE_LEARNING_MODEL_REVISION = "v2";
        MACHINE_LEARNING_PRELOAD__CLIP__VISUAL =
          let clip = config.services.immich.settings.machineLearning.clip; in
          if clip.enabled then clip.modelName else "";
        MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL =
          let clip = config.services.immich.settings.machineLearning.clip; in
          if clip.enabled then clip.modelName else "";
      };
    };
    accelerationDevices = null;
  };

  systemd.services.immich-server = {
    serviceConfig.UMask = lib.mkForce "0027";
  };

  # FIXME: Workaround for <https://github.com/NixOS/nixpkgs/issues/418799>
  users.users.immich = {
    home = "/var/lib/immich";
    createHome = true;
  };

  systemd.tmpfiles.rules = [
    "d ${immich-data} 0750 immich immich"
  ];

  services.caddy.virtualHosts."${immich-domain}".extraConfig =
    ''reverse_proxy :${toString config.site.apps.immich.port}'';
}
