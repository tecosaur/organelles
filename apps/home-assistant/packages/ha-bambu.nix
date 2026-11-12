{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  home-assistant
}:

buildHomeAssistantComponent rec {
  owner = "greghesp";
  domain = "bambu_lab";
  version = "2.4.0";

  src = fetchFromGitHub {
    inherit owner;
    repo = "ha-bambulab";
    tag = "v${version}";
    hash = "sha256-en/2UJ19JJ7HRNHIft7QMN8cQVVJ3tFpmyTjnsZRD5I=";
  };

  dependencies = with home-assistant.python3Packages; [ beautifulsoup4 paho-mqtt ];

  meta = with lib; {
    changelog = "https://github.com/greghesp/ha-bambulab/releases/tag/v${version}";
    description = "Bambu Lab 3D printer integration";
    homepage = "https://github.com/greghesp/ha-bambulab";
    license = licenses.mit;
  };
}
