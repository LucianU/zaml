{
  description = "Flake with Zig Env";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, treefmt-nix }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
          "aarch64-darwin"
          "x86_64-darwin"
          "x86_64-linux"
          "aarch64-linux"
      ];
      perSystem = { config, self', inputs', pkgs, system, ... }: {
        devShells = {
          default = pkgs.mkShell {
            name = "zig";
            packages = with pkgs; [
              zig
            ];
          };
        };

        formatter =
          treefmt-nix.lib.mkWrapper
            pkgs
            {
              projectRootFile = "flake.nix";
              programs.nixpkgs-fmt.enable = true;
              programs.zig.enable = true;
            };
      };
    };
}
