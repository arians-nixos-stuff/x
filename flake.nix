{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        # nixpkgs lags behind; we need >= r26.06.11 for jj change-id support
        # and the `josh link` / `josh changes` commands.
        josh = pkgs.josh.overrideAttrs (
          finalAttrs: _: {
            version = "26.08.28";
            src = pkgs.fetchFromGitHub {
              owner = "josh-project";
              repo = "josh";
              rev = "r${finalAttrs.version}";
              hash = "sha256-9n4SO275NK3ioQVOW+mhTLr9UXnjsmqxjYV2trmlOp4=";
            };
            cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
              inherit (finalAttrs) pname version src;
              hash = "sha256-rUL7GJmHTmOGAybSSoWFPeulDds/9GgYoEDg3nJ5O48=";
            };
            nativeCheckInputs = [ pkgs.git ];
            # Assumes stderr is not a TTY, but the nix builder runs under a pty.
            checkFlags = [ "--skip=display::tests::hyperlink_is_plain_text_when_not_a_tty" ];
            env.JOSH_VERSION = "r${finalAttrs.version}";
          }
        );
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            self.packages.${pkgs.stdenv.hostPlatform.system}.josh
            # The buck2 release that upstream pins for building the vendored tree,
            # so that it always matches the vendored prelude.
            (pkgs.writeShellScriptBin "buck2" ''
              root=$PWD
              until [ -e "$root/.buckroot" ] || [ "$root" = / ]; do root=$(dirname "$root"); done
              exec ${pkgs.dotslash}/bin/dotslash "$root/third-party/buck2/bootstrap/buck2" "$@"
            '')
            pkgs.cargo
            pkgs.go
            # The go toolchain bootstraps its tools through a python wrapper.
            pkgs.python3
            pkgs.reindeer
            # reindeer evaluates cfg() platform predicates with rustc; without it
            # platform-specific dependencies are silently left out.
            pkgs.rustc
          ];
          # `nix develop` always runs bash; `--command` runs it non-interactively.
          shellHook = ''
            if [[ $- == *i* ]]; then
              source <(buck2 completion bash)
            fi
          '';
        };
      });
    };
}
