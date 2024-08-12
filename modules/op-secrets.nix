{ lib, pkgs, config, ... }:
with lib;
let
  inherit (import ./types.nix) secretFileDeclaration;
  cfg = config.opnix;
  scripts = import ./scripts.nix;
in {
  options = {
    opBin = mkOption {
      type = types.str;
      default = "${pkgs._1password}/bin/op";
      description = "The 1Password CLI `op` executable to use";
    };
    serviceAccountTokenPath = mkOption {
      type = types.str;
      description = "Path to a file which contains your service account token.";
    };
    secretsDir = mkOption {
      type = types.path;
      default = "/run/opnix";
      description = ''
        Directory where secrets are symlinked to
      '';
    };
    secretsMountPoint = mkOption {
      type = types.addCheck types.str (s:
        (trim s) != "" # non-empty
        && (builtins.match ".+/" s) == null) # without trailing slash
        // {
          description =
            "${types.str.description} (with check: non-empty without trailing slash)";
        };
      default = "/run/op-nix.d";
    };
    secrets = mkOption {
      type = types.attrsOf secretFileDeclaration;
      description = "The secrets you want to use in your NixOS deployment";
      example = literalExpression ''
        {
          my-secret = {
            source = "{{ op://VaultName/ItemName/FieldName }}";
            user = config.services.some_service.user;
            group = config.services.some_service.group;
            mode = "0400";
          };
          another-secret.source = \'\'
            [SomeTomlHeader]
            SomeValue = "{{ op://AnotherVault/AnotherItem/AnotherField }}"
          \'\';
        }
      '';
    };
  };
  config = mkIf (cfg.secrets != { }) (mkMerge [
    (optionalAttrs (!isDarwin) {
      system = {
        activationScripts = {
          # Create a new directory full of secrets for symlinking (this helps
          # ensure removed secrets are actually removed, or at least become
          # invalid symlinks).
          opnixNewGeneration = {
            text = scripts.newGeneration;
            deps = [ "specialfs" ];
          };

          opnixInstall = {
            text = scripts.installSecrets;
            deps = [ "opnixNewGeneration" "specialfs" ];
          };

          # So user passwords can be encrypted.
          users.deps = [ "opnixInstall" ];

          # Change ownership and group after users and groups are made.
          opnixChown = {
            text = scripts.chownSecrets;
            deps = [ "users" "groups" ];
          };

          # So other activation scripts can depend on opnix being done.
          opnix = {
            text = "";
            deps = [ "opnixChown" ];
          };
        };
      };
    })
    (optionalAttrs isDarwin {
      launchd.daemons.activate-opnix = {
        script = ''
          set -e
          set -o pipefail
          export PATH="${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:@out@/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          ${scripts.newGeneration}
          ${scripts.installSecrets}
          ${scripts.chownSecrets}
          exit 0
        '';
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
        };
      };
    })
  ]);
}