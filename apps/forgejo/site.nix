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
    # git over SSH calls its internal API from sshd's sessions
    clients = [ "sshd" ];
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
  };
  config.site.apps.forgejo = {
    groups.primary = "forge";
    site-name = "Code by TEC";
    site-description = "The personal Forgejo instance of TEC";
    qa-captcha = {
      enabled = true;
      questions = [
        "What is my first name?"
        "What is the thing I use as my avatar?"
        "What is the mononym I often go by online?"
        "What community do you know me from?"
      ];
      answers = [
        "timothy"
        "tec"
        "tree"
        "tecosaur"
        "julia"
        "julialang"
        "emacs"
        "org"
        "doom"
      ];
    };
    default-user-redirect = "tec";
    served-repositories = [
      {
        repo = "tec/this-month-in-org";
        rev = "html";
        subdomain = "blog";
        path = "tmio";
      }
    ];
  };
}
