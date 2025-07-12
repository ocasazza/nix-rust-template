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
            (lib.fileset.maybeMissing ./assets)
          ];
        };

        # Arguments to be used by both the client and the server
        # When building a workspace with crane, it's a good idea
        # to set "pname" and "version".
        commonArgs = {
          inherit src;
          strictDeps = true;
          buildInputs = [] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];
        };

        # Native packages
        nativeArgs = commonArgs // {
          pname = "nix-rust-template-server";
        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly nativeArgs;


        # build just the crate as an artifact
        crateSrc = craneLib.cleanCargoSource ./.;
        myCrate = craneLib.buildPackage {
          inherit crateSrc;
          strictDeps = true;
          cargoVendorDir = craneLib.vendorMultipleCargoDeps {
            inherit (craneLib.findCargoFiles src) cargoConfigs;
            cargoLockList = [
              ./shared/Cargo.lock
              # Unfortunately this approach requires IFD (import-from-derivation)
              # otherwise Nix will refuse to read the Cargo.lock from our toolchain
              # (unless we build with `--impure`).
              #
              # Another way around this is to manually copy the rustlib `Cargo.lock`
              # to the repo and import it with `./path/to/rustlib/Cargo.lock` which
              # will avoid IFD entirely but will require manually keeping the file
              # up to date!
              "${rustToolchainFor.passthru.availableComponents.rust-src}/lib/rustlib/src/rust/library/Cargo.lock"
            ];
          };
          cargoExtraArgs = "-Z build-std --target x86_64-unknown-linux-gnu";
          buildInputs = [
            # Add additional build inputs here
          ];
        };

        # Simple JSON API that can be queried by the client
        myServer = craneLib.buildPackage (
          nativeArgs
          // {
            inherit cargoArtifacts;
            # The server needs to know where the client's dist dir is to
            # serve it, so we pass it as an environment variable at build time
            CLIENT_DIST = myClient;
          }
        );

        # Wasm packages
        # it's not possible to build the server on the
        # wasm32 target, so we only build the client.
        webWasmArgs = commonArgs // {
          pname = "nix-rust-template-web";
          cargoExtraArgs = "--package=nix-rust-template-web";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };
        cargoArtifactsWeb = craneLib.buildDepsOnly (
          webWasmArgs
          // {
            doCheck = false;
          }
        );
        myWasm = craneLib.mkCargoDerivation (webWasmArgs // {
          cargoArtifacts = cargoArtifactsWeb;
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
          ] ++ lib.optional stdenv.isLinux [
            strace
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.libiconv
          ];
        });

        # Wasm packages
        # it's not possible to build the server on the
        # wasm32 target, so we only build the client.
        wasmArgs = commonArgs // {
          pname = "nix-rust-template-client";
          cargoExtraArgs = "--package=nix-rust-template-client";
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };

        cargoArtifactsWasm = craneLib.buildDepsOnly (
          wasmArgs
          // {
            doCheck = false;
          }
        );

        # Build the frontend of the application.
        # This derivation is a directory you can put on a webserver.
        myClient = craneLib.buildTrunkPackage (
          wasmArgs
          // {
            # pname = "nix-rust-template-client";
            cargoArtifacts = cargoArtifactsWasm;
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
          inherit  myServer myClient myWasm;

          nix-rust-template-doc = craneLib.cargoDoc (
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
          server-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
              # Here we don't care about serving the frontend
              CLIENT_DIST = "./client";
            }
          );

          # Check formatting
          # my-app-fmt = craneLib.cargoFmt commonArgs;
        };


        packages.default = myCrate;
        apps.default = flake-utils.lib.mkApp {
          name = "server";
          drv = myServer;
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
          ];
        };
      }
    );
}
