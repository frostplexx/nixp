{
  description = "yuki - A meta package manager for Nix and Homebrew";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, rust-overlay, crane, flake-utils, ... }:
    let
      # Define the module that can be imported by NixOS and nix-darwin
      yukiModule = { config, lib, pkgs, ... }: with lib; {
        options.programs.yuki = {
          enable = mkEnableOption "yuki package manager";
          settings = mkOption {
            type = types.submodule {
              options = {
                darwin_packages_path = mkOption {
                  type = types.str;
                  default = "~/dotfiles/hosts/darwin/apps.nix";
                  description = "Path to Darwin packages configuration";
                };
                linux_packages_path = mkOption {
                  type = types.str;
                  default = "~/dotfiles/hosts/nixos/apps.nix";
                  description = "Path to Linux packages configuration";
                };
                homebrew_packages_path = mkOption {
                  type = types.str;
                  default = "~/dotfiles/hosts/darwin/apps.nix";
                  description = "Path to Homebrew packages configuration";
                };
                auto_commit = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Automatically commit changes";
                };
                auto_push = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Automatically push changes";
                };
                install_message = mkOption {
                  type = types.str;
                  default = "installed <package>";
                  description = "Git commit message for package installation";
                };
                uninstall_message = mkOption {
                  type = types.str;
                  default = "removed <package>";
                  description = "Git commit message for package removal";
                };
                install_command = mkOption {
                  type = types.str;
                  default = "make";
                  description = "Command to run after package installation";
                };
                uninstall_command = mkOption {
                  type = types.str;
                  default = "make";
                  description = "Command to run after package removal";
                };
                update_command = mkOption {
                  type = types.str;
                  default = "make update";
                  description = "Command to run for updating packages";
                };
              };
            };
            default = {};
          };
        };

        config = mkIf config.programs.yuki.enable {
          environment.systemPackages = let
            system = pkgs.system;
          in [
            (pkgs.callPackage self.packages.${system}.default { inherit (config.programs.yuki) settings; })
          ];
        };
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        
        # Common dependencies for building and development
        commonDeps = with pkgs; [
          pkg-config
          openssl
          git
          nix
        ] ++ lib.optionals stdenv.isDarwin [
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.SystemConfiguration
        ];
        
        src = craneLib.cleanCargoSource ./.;
        
        # Setup crane with stable rust
        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Create a derivation for Yuki
        mkYuki = { settings ? {} }: craneLib.buildPackage {
          inherit src;
          inherit settings;
          
          buildInputs = commonDeps;
          
          # Pass configuration as environment variables
          YUKI_LINUX_PACKAGES_PATH = settings.linux_packages_path or "~/dotfiles/hosts/nixos/apps.nix";
          YUKI_DARWIN_PACKAGES_PATH = settings.darwin_packages_path or "~/dotfiles/hosts/darwin/apps.nix";
          YUKI_HOMEBREW_PACKAGES_PATH = settings.homebrew_packages_path or "~/dotfiles/hosts/darwin/apps.nix";
          YUKI_AUTO_COMMIT = toString (settings.auto_commit or true);
          YUKI_AUTO_PUSH = toString (settings.auto_push or false);
          YUKI_UNINSTALL_MESSAGE = settings.uninstall_message or "removed <package>";
          YUKI_INSTALL_MESSAGE = settings.install_message or "installed <package>";
          YUKI_INSTALL_COMMAND = settings.install_command or "make";
          YUKI_UNINSTALL_COMMAND = settings.uninstall_command or "make";
          YUKI_UPDATE_COMMAND = settings.update_command or "make update";
          
          cargoArtifacts = craneLib.buildDepsOnly {
            inherit src;
            buildInputs = commonDeps;
          };
        };

        defaultPackage = pkgs.callPackage ({ settings ? {} }: mkYuki { inherit settings; }) {};
      in {
        packages.default = defaultPackage;

        checks = {
          inherit defaultPackage;
          clippy = craneLib.cargoClippy {
            inherit src;
            cargoArtifacts = craneLib.buildDepsOnly {
              inherit src;
              buildInputs = commonDeps;
            };
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };
          test = craneLib.cargoTest {
            inherit src;
            cargoArtifacts = craneLib.buildDepsOnly {
              inherit src;
              buildInputs = commonDeps;
            };
          };
        };
        
        apps.default = flake-utils.lib.mkApp {
          drv = defaultPackage;
        };
        
        devShells.default = pkgs.mkShell {
          inputsFrom = [ defaultPackage ];  # Changed from packages.default
          buildInputs = with pkgs; [
            rustToolchain
            rust-analyzer
            cargo-watch
            cargo-edit
          ] ++ commonDeps;
        };
      }
    ) // {
      nixosModules.default = yukiModule;
      darwinModules.default = yukiModule;
    };
}
