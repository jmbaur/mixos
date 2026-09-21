{
  buildPackages,
  documentation-highlighter,
  lib,
  path,
  pkgs,
  runCommand,

  options ?
    (lib.evalModules {
      modules = [
        ../module.nix
        { nixpkgs.pkgs = pkgs; }
      ];
    }).options,

  version ? import ../version.nix,

  # Used for the "declared by" links
  revision ? "main",

  # Everything under here is stripped from declaration sites so that the
  # rendered manual never names a /nix/store path.
  prefix ? ../.,
}:

let
  outputPath = "share/doc/mixos";

  stripDeclaration =
    decl:
    let
      declStr = toString decl;
      subpath = lib.removePrefix "/" (lib.removePrefix (toString prefix) declStr);
    in
    if lib.hasPrefix (toString prefix) declStr then
      {
        name = subpath;
        url = "https://github.com/jmbaur/mixos/blob/${revision}/${subpath}";
      }
    else
      decl;

  optionsDoc = buildPackages.nixosOptionsDoc {
    inherit options revision;
    transformOptions = opt: opt // { declarations = map stripDeclaration opt.declarations; };
  };
in
runCommand "mixos-manual-${version}"
  {
    nativeBuildInputs = [ buildPackages.nixos-render-docs ];

    meta = {
      description = "The MixOS manual in HTML format";
      license = lib.licenses.gpl2Only;
    };

    allowedReferences = [ "out" ];

    passthru = {
      inherit (optionsDoc) optionsJSON optionsNix;
    };
  }
  ''
    dst=$out/${outputPath}
    mkdir -p $dst

    cp ${path}/doc/style.css $dst/style.css
    cp ${path}/doc/anchor.min.js $dst/anchor.min.js
    cp ${path}/doc/anchor-use.js $dst/anchor-use.js
    cp -r ${documentation-highlighter} $dst/highlightjs

    cp --no-preserve=all ${./manual.md} manual.md
    cp --no-preserve=all ${./preface.md} preface.md
    cp --no-preserve=all ${./kernel-parameters.md} kernel-parameters.md
    cp --no-preserve=all ${./options.md} options.md

    substituteInPlace manual.md --replace-fail '@MIXOS_VERSION@' ${lib.escapeShellArg version}
    substituteInPlace options.md \
      --replace-fail '@MIXOS_OPTIONS_JSON@' ${optionsDoc.optionsJSON}/share/doc/nixos/options.json

    nixos-render-docs -j $NIX_BUILD_CORES manual html \
      --manpage-urls ${path}/doc/manpage-urls.json \
      --revision ${lib.escapeShellArg revision} \
      --generator "nixos-render-docs ${lib.version}" \
      --stylesheet style.css \
      --stylesheet highlightjs/mono-blue.css \
      --script ./highlightjs/highlight.pack.js \
      --script ./highlightjs/loader.js \
      --script ./anchor.min.js \
      --script ./anchor-use.js \
      --sidebar-depth 2 \
      ./manual.md \
      $dst/index.html

    mkdir -p $out/nix-support
    echo "doc manual $dst" >> $out/nix-support/hydra-build-products
  ''
