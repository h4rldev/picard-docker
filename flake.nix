{
  description = "A distributed container VNC shipping Picard with a modern Wayland desktop instead of the old X11 desktop";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {inherit system;}));
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "picard-docker";

        buildInputs = with pkgs; [
          beamPackages.erlang
          beamPackages.rebar3

          file
        ];

        packages = with pkgs; [
          erlang-language-platform
          just
        ];
      };
    });
  };
}
