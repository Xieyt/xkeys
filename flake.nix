{
  description = "xkeys - driver-level key swaps, external keyboard replay, and modifier chords for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # Config file, launch agent, and eval-time validation of every key name.
      homeManagerModules.xkeys = import ./nix/home-manager.nix;
      homeManagerModules.default = self.homeManagerModules.xkeys;

      # The stable code-signing identity, created once at activation. Separate
      # because it needs root, which a home-manager activation does not have.
      darwinModules.xkeys = import ./nix/darwin.nix;
      darwinModules.default = self.darwinModules.xkeys;
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        # Built with nixpkgs' own Swift 6.2.4 against apple-sdk-26.5, so the
        # package and the dev shell share one toolchain. An earlier reading
        # of Swift 5.10 came from a stale channel and was wrong.
        packages.default = self.packages.${system}.xkeys;
        packages.xkeys = pkgs.callPackage ./nix/package.nix { };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.just pkgs.swift pkgs.swiftpm ];

          # `just dev-install` compiles in here, incrementally, with the same
          # compiler `nix build` uses. Two toolchains producing the shipped
          # binary is how a bug appears only after a switch.
          shellHook = ''
            echo "xkeys dev shell. Build: nix build | Fast loop: just dev-install | Checks: just test"
          '';
        };
      });
}
