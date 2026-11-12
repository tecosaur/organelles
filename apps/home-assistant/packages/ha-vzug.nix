{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  home-assistant
}:

buildHomeAssistantComponent rec {
  owner = "siku2";
  domain = "vzug";
  version = "0.5.0";

  src = fetchFromGitHub {
    inherit owner;
    repo = "hass-vzug";
    tag = "v${version}";
    hash = "sha256-ESegI0Yw1P53Pweymm4ZvcBDrhMbeXRu2OOt4KG55kM=";
  };

  dependencies = with home-assistant.python3Packages; [ json-repair ];

  postPatch = ''
    substituteInPlace custom_components/vzug/manifest.json \
      --replace-fail \
        '"json-repair~=0.46.2"' \
        '"json-repair==${home-assistant.python3Packages.json-repair.version}"'
  '';

  meta = with lib; {
    changelog = "https://github.com/siku2/hass-vzug/releases/tag/v${version}";
    description = "V-ZUG Home Assistant integration.";
    homepage = "https://github.com/siku2/hass-vzug";
    license = licenses.mit;
  };
}
