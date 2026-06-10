{
  description = "Unified Nix builder for browser WebExtensions: one source → standardized {chrome, firefox, default} (CRX3 + external-extension manifest + Firefox XPI + per-browser MV3 transform), composing nix-crx for CRX3 signing. Signing keys stay out of the build (sops + activation-time signing).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-crx = {
      url = "github:rivavolt/nix-crx";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, nix-crx }:
    let
      builderLib = import ./lib.nix { inherit nixpkgs nix-crx; };
    in
    {
      lib = builderLib // {
        # Derive a Chrome extension ID from an RSA private key (PEM). Useful at
        # porting time to recover the extId a previously-committed key produced,
        # which then becomes the `extId` passed to mkBrowserExtension so the pure
        # build needs no key. Pure: runs in a build sandbox.
        idFromKey =
          { pkgs, key }:
          builtins.readFile (
            pkgs.runCommand "crx-ext-id" { nativeBuildInputs = [ pkgs.python3 pkgs.openssl ]; } ''
              python3 ${nix-crx}/crx-id.py ${key} > $out
            ''
          );
      };

      # Activation-time CRX signer. The pure builds carry no key and no CRX; this
      # module signs each extension's Chrome content from a sops secret into a
      # host dir chromium reads, and writes the external-extension manifest there.
      nixosModules.default = import ./module.nix { inherit self nix-crx; };

      # The MV3 transform + a tiny example, exercised by `nix flake check`.
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          example = builderLib.mkBrowserExtension {
            inherit pkgs;
            pname = "example";
            version = "1.0";
            extId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            src = ./example;
            files = [
              "manifest.json"
              "background.js"
            ];
          };
        in
        {
          # The Chrome manifest must keep only service_worker; Firefox only scripts.
          mv3-transform = pkgs.runCommand "mv3-transform-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
            chromeBg=$(jq -c '.background' ${example.chromeContent}/share/chromium-extension/manifest.json)
            [ "$chromeBg" = '{"service_worker":"background.js"}' ] || { echo "chrome bg wrong: $chromeBg"; exit 1; }
            ${pkgs.unzip}/bin/unzip -o ${example.firefox}/${builderLib.firefoxAppDir}/*.xpi manifest.json -d ff >/dev/null
            ffBg=$(jq -c '.background' ff/manifest.json)
            [ "$ffBg" = '{"scripts":["background.js"]}' ] || { echo "firefox bg wrong: $ffBg"; exit 1; }
            touch $out
          '';
        }
      );
    };
}
