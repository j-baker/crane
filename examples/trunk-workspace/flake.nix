{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        inherit (pkgs) lib;

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          # Set the build targets supported by the toolchain,
          # wasm32-unknown-unknown is required for trunk.
          targets = [ "wasm32-unknown-unknown" ];
        };
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # When filtering sources, we want to allow assets other than .rs files
        src = lib.cleanSourceWith {
          src = ./.; # The original, unfiltered source
          filter = path: type:
            (lib.hasSuffix "\.html" path) ||
            (lib.hasSuffix "\.scss" path) ||
            # Example of a folder for images, icons, etc
            (lib.hasInfix "/assets/" path) ||
            # Default filter from crane (allow .rs files)
            (craneLib.filterCargoSources path type)
          ;
        };


        # Arguments to be used by both the client and the server
        # When building a workspace with crane, it's a good idea
        # to set "pname" and "version".
        commonArgs = {
          inherit src;
          pname = "trunk-workspace";
          version = "0.1.0";
        };

        # Native packages

        nativeArgs = commonArgs // {
          pname = "trunk-workspace-native";
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly nativeArgs;

        # Simple JSON API that can be queried by the client
        myServer = craneLib.buildPackage (nativeArgs // {
          inherit cargoArtifacts;
          # The server needs to know where the client's dist dir is to
          # serve it, so we pass it as an environment variable at build time
          CLIENT_DIST = myClient;
        });

        # Wasm packages

        # it's not possible to build the server on the
        # wasm32 target, so we only build the client.
        wasmArgs = commonArgs // {
          pname = "trunk-workspace-wasm";
          cargoExtraArgs = "--package=client";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };

        cargoArtifactsWasm = craneLib.buildDepsOnly (wasmArgs // {
          doCheck = false;
        });

        # Build the frontend of the application.
        # This derivation is a directory you can put on a webserver.
        myClient = craneLib.buildTrunkPackage (wasmArgs // {
          pname = "trunk-workspace-client";
          cargoArtifacts = cargoArtifactsWasm;
          trunkIndexPath = "client/index.html";
        });
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit myServer myClient;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-app-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            # Here we don't care about serving the frontend
            CLIENT_DIST = "";
          });

          # Check formatting
          my-app-fmt = craneLib.cargoFmt commonArgs;
        };

        apps.default = flake-utils.lib.mkApp {
          name = "server";
          drv = myServer;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = builtins.attrValues self.checks;

          shellHook = ''
            export CLIENT_DIST=$PWD/client/dist;
          '';

          # Extra inputs can be added here
          nativeBuildInputs = with pkgs; [
            cargo
            rustc
            trunk
          ];
        };
      });
}
