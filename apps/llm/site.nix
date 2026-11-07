{ config, lib, site-lib, ... }:

{
  options.site.apps.llm = site-lib.mkAppOption {
    health.path = "/health";
    name = "llama-cpp";
    homepage = "https://github.com/ggml-org/llama.cpp";
    description = "LLM inference endpoint";
    usesStateDir = false;
    subdomain = "llm";
    port = 8089;
    ports.embedding = { port = 8088; unit = "llama-cpp-embedding"; clients = [ "caddy" ]; };
    extraOptions = {
      local = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run a local llama-server, and serve it as an endpoint";
      };
      local-fallback = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the local endpoint should only be used when every remote
          endpoint is unhealthy, instead of participating in load balancing.
        '';
      };
      remotes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "workstation.lan:8089" "192.168.1.20:8089" ];
        description = ''
          Remote llama-server endpoints (as host:port) to serve alongside
          any local endpoint, subject to active health checking.
        '';
      };
      embedding = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.site.apps.llm.enabled;
          defaultText = lib.literalExpression "config.site.apps.llm.enabled";
          description = ''
            Whether to run a second, local llama-server dedicated to
            embeddings, serving /v1/embeddings on the same domain.
          '';
        };
      };
    };
    secrets = {
      api-key = {
        kind = "password";
        description = "Shared secret between the llama-server and its clients";
        file-name = "llm-api-key";
        units.caddy = config.site.apps.llm.hosts;
      };
    };
  };
}
