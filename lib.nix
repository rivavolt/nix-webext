{ nixpkgs, nix-crx }:
let
  # Firefox's add-on dir is keyed by the application UUID, not the extension's.
  firefoxAppDir = "share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  # One extension's distributable release assets, collected flat for a GitHub Release: <pname>-<version>-chrome.zip (the Chrome Web Store UPLOAD format — the Store signs on publish, so CI never mints a CRX and the identity key stays in sops/host activation) and <pname>-<version>-unsigned.xpi (the AMO upload). The build stays pure: AMO signing is a service interaction, so it lives in the release workflow (rivavolt/ci webext-release.yml), never here.
  # Standalone (not only a mkBrowserExtension output) so flakes that compose their own package set — copy-urls and translate-selection zip their own WXT firefox bundle — can emit the same asset convention from their own parts.
  mkReleaseAssets =
    {
      pkgs,
      pname,
      version,
      # Derivation with the Chrome-ready unpacked content at $out/share/chromium-extension (mkBrowserExtension's chromeContent passthru), or null for Firefox-only extensions.
      chromeContent ? null,
      # Path to the unsigned XPI file, or null for Chrome-only extensions.
      xpi ? null,
    }:
    pkgs.runCommand "${pname}-release-${version}" { nativeBuildInputs = [ pkgs.zip ]; } ''
      mkdir -p $out
      ${pkgs.lib.optionalString (chromeContent != null) ''
        (cd ${chromeContent}/share/chromium-extension && zip -r -X $out/${pname}-${version}-chrome.zip .)
      ''}
      ${pkgs.lib.optionalString (xpi != null) ''
        cp ${xpi} $out/${pname}-${version}-unsigned.xpi
      ''}
    '';
in
{
  inherit firefoxAppDir mkReleaseAssets;

  # Build the standardized {chrome, firefox, default} package set for one
  # WebExtension. The pure Nix outputs carry NO signing key: Chrome gets the
  # content plus an external-extension manifest keyed by the (caller-supplied)
  # extId, and Firefox gets an unsigned XPI. The CRX itself is signed later, at
  # NixOS/home activation, from the key in sops (see nixosModules.default) —
  # because the build sandbox can't read run-time secrets. extId is therefore
  # required: it's the stable Chrome ID the committed key used to derive, so the
  # build stays hermetic while preserving the ID. Pass it from the value
  # nix-webext.lib.idFromKey printed for the old key, or the literal already
  # recorded in the repo.
  mkBrowserExtension =
    {
      pkgs,
      pname,
      version,
      # The extension's stable Chrome ID (16-char a-p). Required when `chrome` is
      # true — see above. Unused (and may be omitted) for Firefox-only extensions.
      extId ? null,
      # Firefox gecko id. Defaults to manifest.browser_specific_settings.gecko.id.
      geckoId ? null,
      # Either a pre-assembled derivation exposing the unpacked extension at
      # $out/share/chromium-extension (e.g. a WXT/npm build), …
      extension ? null,
      # … or a raw source tree plus the files to copy out of it.
      src ? null,
      files ? null,
      # Whether this extension ships a Chrome half / a Firefox half. A few are
      # one-browser-only (chrome-new-tab-next is Chrome-only; firefox-block-js is
      # Firefox-only).
      chrome ? true,
      firefox ? true,
      # Apply the per-browser MV3 background transform (Chrome keeps only
      # background.service_worker, Firefox keeps only the background.scripts
      # event page). Off for extensions whose toolchain (WXT) already emits the
      # right per-target manifest.
      transformManifest ? true,
      # Extra store paths to fold into `default` (native-messaging hosts, CLIs).
      extraPaths ? [ ],
    }:
    let
      lib = pkgs.lib;

      assertMsg = c: m: if c then true else throw m;

      # The unpacked content, normalized to $out/share/chromium-extension.
      content =
        if extension != null then
          extension
        else
          assert assertMsg (src != null && files != null)
            "mkBrowserExtension: pass either `extension` or both `src` and `files`";
          pkgs.runCommand "${pname}-content-${version}" { } ''
            mkdir -p $out/share/chromium-extension
            cd ${src}
            cp -r ${lib.concatStringsSep " " files} $out/share/chromium-extension/
          '';

      manifest = builtins.fromJSON (builtins.readFile "${content}/share/chromium-extension/manifest.json");

      # extId is only meaningful for the Chrome half; require it there.
      _extIdOk = assertMsg (!chrome || extId != null)
        "mkBrowserExtension: `extId` is required when `chrome` is true (pass the stable Chrome ID the signing key derives)";

      # Resolved lazily: a Firefox-less extension never forces this, so a missing
      # gecko id is only an error for extensions that actually emit a Firefox XPI.
      geckoId' =
        if geckoId != null then
          geckoId
        else
          (manifest.browser_specific_settings.gecko.id or (throw
            "mkBrowserExtension: no geckoId and manifest has no browser_specific_settings.gecko.id"));

      # Rewrite the manifest's background block for one browser. Chrome MV3 wants
      # a single service_worker; Firefox MV3 runs the same code as an event-page
      # background.scripts. The house manifests carry both keys, so the transform
      # is a projection: keep the one this browser reads, drop the other. Done
      # with jq at build time so it survives whatever else is in the manifest.
      transformedContent =
        target:
        if !transformManifest || !(manifest ? background) then
          content
        else
          pkgs.runCommand "${pname}-content-${target}-${version}" {
            nativeBuildInputs = [ pkgs.jq ];
          } ''
            mkdir -p $out/share/chromium-extension
            cp -r ${content}/share/chromium-extension/. $out/share/chromium-extension/
            chmod -R u+w $out/share/chromium-extension
            cd $out/share/chromium-extension
            ${
              if target == "chrome" then
                # Chrome: a service_worker key, derived from scripts[0] if the
                # source only had the Firefox form. Drop background.scripts.
                ''
                  jq '
                    (.background.service_worker) as $sw
                    | .background = { service_worker: ($sw // .background.scripts[0]) }
                    + (if .background.type then { type: .background.type } else {} end)
                  ' manifest.json > manifest.json.new
                ''
              else
                # Firefox: an event-page scripts array, derived from
                # service_worker if the source only had the Chrome form. Drop
                # background.service_worker.
                ''
                  jq '
                    (.background.scripts) as $sc
                    | .background = { scripts: ($sc // [ .background.service_worker ]) }
                  ' manifest.json > manifest.json.new
                ''
            }
            mv manifest.json.new manifest.json
          '';

      chromeContent = transformedContent "chrome";

      # The external-extension manifest Chromium reads from
      # share/chromium/extensions/<id>.json. The CRX itself is produced at
      # activation by nixosModules.default (the build carries no key), so
      # external_crx points at the stable activation-time path, NOT a store path.
      # This is the one place the build and the signer agree on a filesystem
      # contract; crxDir mirrors module.nix's crxDir.
      crxDir = "/var/lib/chromium-crx";
      chromeExternalJson = assert _extIdOk; pkgs.writeText "${extId}.json" (builtins.toJSON {
        external_crx = "${crxDir}/${extId}.crx";
        external_version = version;
      });

      # The Chrome package is just the external-extension manifest (delivered via
      # systemPackages → /run/current-system/sw/share/chromium/extensions). The
      # unpacked content that gets signed into a CRX is exposed as the
      # `chromeContent` passthru below, which the signer module reads directly
      # from the store — it never needs to ship in the system profile.
      chromePkg = pkgs.linkFarm "${pname}-chrome" [
        {
          name = "share/chromium/extensions/${extId}.json";
          path = chromeExternalJson;
        }
      ];

      firefoxXpi = pkgs.stdenv.mkDerivation {
        pname = "${pname}-firefox-xpi";
        inherit version;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.zip ];
        buildPhase = ''
          cd ${transformedContent "firefox"}/share/chromium-extension
          zip -r -X $TMPDIR/extension.xpi .
        '';
        installPhase = ''
          mkdir -p $out/${firefoxAppDir}
          cp $TMPDIR/extension.xpi $out/${firefoxAppDir}/${geckoId'}.xpi
        '';
      };

      outputs =
        (lib.optionalAttrs chrome { chrome = chromePkg; })
        // (lib.optionalAttrs firefox { firefox = firefoxXpi; });

      defaultPaths =
        (lib.optional chrome chromePkg)
        ++ (lib.optional firefox firefoxXpi)
        ++ extraPaths;
    in
    outputs
    // {
      # Metadata other code (the signing module, native-messaging wiring) needs.
      inherit extId;
      geckoId = geckoId';
      inherit version;
      # The Chrome-transformed unpacked content as a DERIVATION (files at
      # $out/share/chromium-extension). The signer module references this so it
      # lands in the system closure — guaranteeing the content is built /
      # substituted on the host before activation signs it. (A bare string path
      # would not pull the derivation into any closure, so the path could be
      # absent at sign time.)
      inherit chromeContent;

      # The flat release-asset directory webext-release.yml publishes to a GitHub Release (see mkReleaseAssets above). Per-browser gating mirrors the package set; the gecko id is only forced for extensions that actually emit an XPI.
      release = mkReleaseAssets {
        inherit pkgs pname version;
        chromeContent = if chrome then chromeContent else null;
        xpi = if firefox then "${firefoxXpi}/${firefoxAppDir}/${geckoId'}.xpi" else null;
      };

      default =
        if builtins.length defaultPaths == 1 then
          builtins.head defaultPaths
        else
          pkgs.symlinkJoin {
            name = pname;
            paths = defaultPaths;
          };
    };
}
