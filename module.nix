{ self, nix-crx }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.webext-crx;

  crxTools = nix-crx.packages.${pkgs.stdenv.hostPlatform.system}.crx-tools;

  # Where activation-signed CRXs land. Stable, world-readable (the CRX is not
  # secret — only the private key is), and bound RO into the chromium sandbox by
  # the consumer. Each extension's external-extension manifest (shipped in the
  # nix store via systemPackages) points its external_crx here.
  crxDir = "/var/lib/chromium-crx";

  extModule = lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.attrs;
        description = "A nix-webext mkBrowserExtension result (needs .extId, .version, .chromeContent).";
      };
      keySecret = lib.mkOption {
        type = lib.types.str;
        description = "sops.secrets key whose .path holds the RSA signing key (PEM) for this extension.";
      };
    };
  };
in
{
  options.programs.webext-crx = {
    enable = lib.mkEnableOption "activation-time CRX signing for nix-webext extensions";

    crxDir = lib.mkOption {
      type = lib.types.str;
      default = crxDir;
      readOnly = true;
      description = "Directory the signed CRXs are written to (bind this RO into any extension-reading browser sandbox).";
    };

    extensions = lib.mkOption {
      type = lib.types.listOf extModule;
      default = [ ];
      description = "Extensions to sign at activation, each pairing a nix-webext package with its sops key secret.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.extensions != [ ]) {
    # Sign every extension's Chrome content into crxDir at boot, after sops has
    # materialized the keys. Deterministic: nix-crx's packer fixes zip mtimes and
    # sorts entries, so the CRX (hence the ID Chrome derives) is byte-stable and
    # equals what an in-store sign would have produced.
    systemd.services.chromium-crx-sign = {
      description = "Sign nix-webext CRX3 packages from sops keys";
      wantedBy = [ "multi-user.target" ];
      after = [ "sops-nix.service" ];
      wants = [ "sops-nix.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ crxTools ];
      script = ''
        set -euo pipefail
        install -d -m 0755 ${crxDir}
        # Drop CRXs for extensions no longer configured.
        keep=""
        ${lib.concatMapStringsSep "\n" (e: ''keep="$keep ${e.package.extId}"'') cfg.extensions}
        for f in ${crxDir}/*.crx; do
          [ -e "$f" ] || continue
          id=$(basename "$f" .crx)
          case " $keep " in *" $id "*) ;; *) rm -f "$f" ;; esac
        done
        ${lib.concatMapStringsSep "\n" (e: ''
          pack-crx3 ${lib.escapeShellArg e.package.chromeContent} \
            "${config.sops.secrets.${e.keySecret}.path}" \
            ${crxDir}/${e.package.extId}.crx
          chmod 0644 ${crxDir}/${e.package.extId}.crx
        '') cfg.extensions}
      '';
    };
  };
}
