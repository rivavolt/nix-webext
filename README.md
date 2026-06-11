# nix-webext

A unified Nix builder for browser WebExtensions. One source tree → the
standardized `packages.{chrome,firefox,default}`:

- **Chrome**: the `share/chromium/extensions/<id>.json` external-extension
  manifest (CRX3 install). The CRX itself is **not** produced by the build — it
  is signed at NixOS/home activation from a key in sops (see below), so no
  signing key ever enters the build sandbox or the nix store.
- **Firefox**: the `share/mozilla/extensions/{…}/<geckoId>.xpi` unsigned XPI
  (signed separately via AMO for self-distribution).
- A per-browser **MV3 background transform**: Chrome keeps only
  `background.service_worker`, Firefox keeps only the event-page
  `background.scripts`. The house manifests carry both keys; the transform is a
  projection that hands each browser the form it reads.

It composes [`nix-crx`](https://github.com/rivavolt/nix-crx) (the generic CRX3
primitive) for the actual signing, invoked at activation by the bundled NixOS
module.

## `lib.mkBrowserExtension`

```nix
nix-webext.lib.mkBrowserExtension {
  inherit pkgs;
  pname   = "highlight";
  version = manifest.version;
  extId   = "cfbijkcjpncoflpladdmdombmhnefcek"; # the stable Chrome ID (see below)
  src     = self;
  files   = [ "manifest.json" "background.js" "content.js" "styles.css" ];
}
```

| Parameter | Description |
|-----------|-------------|
| `pkgs` | nixpkgs package set |
| `pname`, `version` | extension name / version |
| `extId` | **required** stable Chrome ID. The build is keyless, so the ID can't be derived from a key at build time — pass the literal the key produces (recover it with `lib.idFromKey` once, then commit it). |
| `geckoId` | Firefox gecko id (defaults to `manifest.browser_specific_settings.gecko.id`) |
| `src` + `files` | a raw source tree and the files to copy into the extension, **or** … |
| `extension` | … a pre-assembled derivation exposing the unpacked extension at `$out/share/chromium-extension` (WXT/npm builds) |
| `chrome`, `firefox` | whether to emit each browser's half (default both) |
| `transformManifest` | apply the MV3 background transform (default true; off for WXT, which already emits per-target manifests) |
| `extraPaths` | extra store paths to fold into `default` (native-messaging hosts, CLIs) |

Returns `{ chrome, firefox, default, release }` plus the metadata passthrus
`extId`, `geckoId`, `version`, `chromeContent` (the Chrome-transformed unpacked
content the signer reads).

## `release` — distributable assets for GitHub Releases

`release` is a flat directory of the extension's distributables, built by
`lib.mkReleaseAssets` and published by the shared
`rivavolt/ci/.github/workflows/avolt-release.yml` workflow on `v*` tags:

- `<pname>-<version>-chrome.zip` — the Chrome Web Store **upload** format (the
  Store signs on publish; CI never mints a CRX, the identity key stays in
  sops/host activation)
- `<pname>-<version>-unsigned.xpi` — the AMO upload; the release workflow signs
  it via the AMO API (`--channel unlisted`, self-distribution) **outside** the
  build, so the nix outputs stay pure

One-browser extensions emit only their half. Flakes that compose their own
package set call `lib.mkReleaseAssets { pkgs, pname, version, chromeContent?,
xpi? }` directly to produce the same convention.

## Why `extId` is required (key externalization)

A CRX's signing key determines the extension's stable Chrome ID; rotating it
would orphan every installed copy. To keep the ID **and** get the key out of the
repo, the key moves into sops and the build becomes keyless: it emits the
external-extension manifest keyed by the known `extId`, and the CRX is signed at
activation.

## NixOS module — activation-time signing

```nix
{
  imports = [ nix-webext.nixosModules.default ];

  sops.secrets."crx_keys/highlight" = { };

  programs.webext-crx = {
    enable = true;
    extensions = [
      { package = inputs.highlight.packages.${system}.default; keySecret = "crx_keys/highlight"; }
    ];
  };
}
```

At boot (after `sops-nix`), the module signs each extension's `chromeContent`
into `programs.webext-crx.crxDir` (`/var/lib/chromium-crx/<id>.crx`) with the
key from sops — byte-reproducibly (the packer fixes zip mtimes and sorts
entries, so the CRX equals what an in-store sign would produce). The
external-extension manifest shipped via `systemPackages` points `external_crx`
there. **Bind `programs.webext-crx.crxDir` read-only into any sandboxed browser**
so the sandboxed Chromium can read the signed CRX.
