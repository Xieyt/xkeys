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
        # No `packages.default`, deliberately. nixpkgs ships Swift 5.10 on
        # darwin and xkeys is swift-tools 6.0 using Swift 6 language
        # features, so there is nothing in nixpkgs that can compile it.
        # Build with the system toolchain: `just install`.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.just ];

          # The whole point of this shell. A darwin devShell normally exports
          # SDKROOT and DEVELOPER_DIR pointing at nixpkgs' Apple SDK, which
          # the system Swift 6 compiler rejects outright:
          #   "SDK is built with Apple Swift 5.10 ... select a toolchain
          #    which matches the SDK"
          # Clearing them falls back to the Command Line Tools SDK, which
          # matches, so `swift build` works in here with no env juggling.
          shellHook = ''
            unset SDKROOT DEVELOPER_DIR LIBRARY_PATH
            echo "xkeys dev shell. Build: just build | Install: just install | Checks: just test"
            if ! /usr/bin/xcrun --sdk macosx --find swiftc >/dev/null 2>&1; then
              echo "!! no usable Swift toolchain: xcode-select --install"
            fi
          '';
        };
      });
}
