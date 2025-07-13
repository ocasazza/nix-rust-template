{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      rust-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib;
        rustToolchainFor =
          p:
          p.rust-bin.stable.latest.default.override {
            # Set the build targets supported by the toolchain,
            # wasm32-unknown-unknown is required for trunk.
            targets = [ "wasm32-unknown-unknown" ];
          };
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchainFor;
        # When filtering sources, we want to allow assets other than .rs files
        unfilteredRoot = ./.; # The original, unfiltered source
        src = lib.fileset.toSource {
          root = unfilteredRoot;
          fileset = lib.fileset.unions [
            # Default files from crane (Rust and cargo files)
            (craneLib.fileset.commonCargoSources unfilteredRoot)
            (lib.fileset.fileFilter (
              file:
              lib.any file.hasExt [
                "html"
                "scss"
              ]
            ) unfilteredRoot)
            # Example of a folder for images, icons, etc
            # (lib.fileset.maybeMisssing ./assets)
          ];
        };

        commonArgs = {
          # ! this can be optimized
          inherit src;
          strictDeps = true;
          buildInputs = [
            pkgs.cacert
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            pkgs.libiconv
            pkgs.openssl
            # Additional darwin specific inputs can be set here
          ];
          # Set SSL certificate environment variables
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };

        # ---------------------------------------
        # build the native packages
        # i.e. non-wasm / non-browser stuff first
        # ---------------------------------------
        nativeArgs = commonArgs // {
          pname = "nix-rust-template-shared";
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly nativeArgs;

        # ---------------------------------
        # build the library / shared rust crate
        # that can be published to crates.io
        # ---------------------------------
        myShared = craneLib.buildPackage (
          nativeArgs
          // {
            inherit cargoArtifacts;
            cargoVendorDir = null;
          }
        );

        # -----------------------------
        # build a native application
        # that uses the shared library
        # -----------------------------
        myServer = craneLib.buildPackage (
          nativeArgs
          // {
            inherit cargoArtifacts;
            # The server needs to know where the client's dist dir is to
            # serve it, so we pass it as an environment variable at build time
            CLIENT_DIST = myClient;
          }
        );

        # ----------------------------
        # build the WASM library that
        # can be published to npm
        # ----------------------------
        wasmArgs = commonArgs // {
          pname = "web";
          cargoExtraArgs = "--package=nix-rust-template-web";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };
        wasmCargoArtifacts = craneLib.buildDepsOnly (
          wasmArgs
          // {
            doCheck = false;
          }
        );
        myWeb = craneLib.mkCargoDerivation (wasmArgs // {
          cargoArtifacts = wasmCargoArtifacts;
          doCheck = false;
          buildPhaseCargoCommand = ''
            HOME=$(mktemp -d fake-homeXXXX)
            cd ./web
            wasm-pack build --target web --out-dir pkg
            cd ..
          '';
          installPhaseCommand = ''
            mkdir -p $out
            cp -r ./web/pkg $out/
          '';
          nativeBuildInputs = with pkgs; [
            binaryen
            wasm-bindgen-cli
            wasm-pack
            nodejs
            cacert
          ] ++ lib.optional stdenv.isLinux [
            pkgs.strace
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.libiconv
            pkgs.libiconv
            pkgs.openssl
          ];
        });

        # -----------------------------
        # build a in-browser client
        # that uses the shared library
        # -----------------------------
        webArgs = commonArgs // {
          pname = "client";
          cargoExtraArgs = "--package=nix-rust-template-client";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };
        webCargoArtifacts = craneLib.buildDepsOnly (
          webArgs
          // {
            doCheck = false;
          }
        );
        # # Build the frontend of the application.
        # # This derivation is a directory you can put on a webserver.
        myClient = craneLib.buildTrunkPackage (
          webArgs
          // {
            cargoArtifacts = webCargoArtifacts;
            # Trunk expects the current directory to be the crate to compile
            preBuild = ''
              cd ./client
            '';
            # After building, move the `dist` artifacts and restore the working directory
            postBuild = ''
              mv ./dist ..
              cd ..
            '';
            # The version of wasm-bindgen-cli here must match the one from Cargo.lock.
            # When updating to a new version replace the hash values with lib.fakeHash,
            # then try to do a build, which will fail but will print out the correct value
            # for `hash`. Replace the value and then repeat the process but this time the
            # printed value will be for the second `hash` below
            wasm-bindgen-cli = pkgs.buildWasmBindgenCli rec {
              src = pkgs.fetchCrate {
                pname = "wasm-bindgen-cli";
                version = "0.2.100";
                hash = "sha256-3RJzK7mkYFrs7C/WkhW9Rr4LdP5ofb2FdYGz1P7Uxog=";
                # hash = "sha256-3RJzK7mkYFrs7C/WkhW9Rr4LdP5ofb2FdYGz1P7Uxog=";
              };
              cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
                inherit src;
                inherit (src) pname version;
                hash = "sha256-qsO12332HSjWCVKtf1cUePWWb9IdYUmT+8OPj/XP2WE=";
                # hash = "sha256-qsO12332HSjWCVKtf1cUePWWb9IdYUmT+8OPj/XP2WE=";
              };
            };
          }
        );


      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit myShared myWeb myServer myClient; # myCli;

          myDocs = craneLib.cargoDoc (
            commonArgs
            // {
              inherit cargoArtifacts;
            }
          );

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          # server-clippy = craneLib.cargoClippy (
          #   commonArgs
          #   // {
          #     inherit cargoArtifacts;
          #     cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          #     # Here we don't care about serving the frontend
          #     CLIENT_DIST = "./client";
          #   }
          # );

          # Check formatting
          # my-app-fmt = craneLib.cargoFmt commonArgs;
        };


        packages.default = myShared;

        apps.server = flake-utils.lib.mkApp {
          name = "nix-rust-template-server";
          drv = myServer;
        };

        # App to copy all outpaths from result to ./dist folder
        apps.copy-outpaths = flake-utils.lib.mkApp {
          name = "copy-outpaths";
          drv = pkgs.writeShellScriptBin "copy-outpaths" ''
            set -euo pipefail

            mkdir -p artifacts
            jq -r '.result.ROOT.build.byName | to_entries[] | "\(.key):\(.value)"' result | while IFS=':' read -r name path; do
              [ -e "$path" ] && mkdir -p "artifacts/$name" && cp -r "$path" "artifacts/$name/"
            done
          '';
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};
          shellHook = ''
            export CLIENT_DIST=$PWD/client/dist;
          '';
          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            pkgs.trunk
            pkgs.wasm-pack
            pkgs.act
            pkgs.rustup
          ];
        };
      }
    );
}
