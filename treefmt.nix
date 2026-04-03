{ pkgs, ... }:
let
  swiftFormatConfig = pkgs.writeText ".swift-format" ''
    {
      "lineLength": 120,
      "multiElementCollectionTrailingCommas": false
    }
  '';
in
{
  projectRootFile = "flake.nix";

  programs.gofmt.enable = true;
  programs.nixfmt.enable = true;

  settings.formatter.swift-format = {
    command = "${pkgs.swift-format}/bin/swift-format";
    includes = [ "*.swift" ];
    options = [
      "-i"
      "--configuration"
      "${swiftFormatConfig}"
    ];
  };
}
