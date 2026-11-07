{ config, lib, site-lib, ... }:

{
  options.site.apps.forgejo = site-lib.mkAppOption {
    health.path = "/api/healthz";
    name = "Forgejo";
    homepage = "https://forgejo.org";
    description = "personal software forge";
    simpleicon = "forgejo";
    subdomain = "code";
    port = 3002;
    # git over SSH calls its internal API from the session pam_systemd gives it, outside any unit
    client-users = [ "git" ];
    extraOptions = {
      site-name = lib.mkOption {
        type = lib.types.str;
        default = "Forgejo";
        description = "Name of the Forgejo instance";
      };
      site-description = lib.mkOption {
        type = lib.types.str;
        default = "Forgejo instance";
        description = "Description of the Forgejo instance";
      };
      default-user-redirect = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "A private user to redirect to upon visiting the root domain";
      };
      qa-captcha = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to enable the question and answer captcha for the Forgejo registration page";
        };
        questions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Question to use for the Forgejo registration captcha";
        };
        answers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "List of acceptable answers for the Forgejo registration captcha";
        };
      };
      served-repositories = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            repo = lib.mkOption {
              type = lib.types.str;
              description = "Path to the repository";
            };
            rev = lib.mkOption {
              type = lib.types.str;
              description = "Branch, tag, or commit to serve";
            };
            subdomain = lib.mkOption {
              type = lib.types.str;
              default = "pages";
              description = "Subdomain to serve the repository on";
            };
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "URL prefix to serve the repository on";
            };
          };
        });
        default = [ ];
      };
    };
    auth = {
      policy = { };
      clients.forgejo = {
        redirects = [ "user/oauth2/authelia/callback" ];
        secret.units = [ "forgejo" ];
      };
    };
    mail = { sender = "noreply"; units = [ "forgejo" ]; };
  };
}
