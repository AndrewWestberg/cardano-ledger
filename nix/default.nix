{ system ? builtins.currentSystem
, crossSystem ? null
, config ? {}
, sourcesOverride ? {}
}:
let
  sources = import ./sources.nix { inherit pkgs; }
    // sourcesOverride;
  iohKNix = import sources.iohk-nix {};
  haskellNix = import sources."haskell.nix";
  # use our own nixpkgs if it exists in our sources,
  # otherwise use iohkNix default nixpkgs.
  nixpkgs = if (sources ? nixpkgs)
    then (builtins.trace "Not using IOHK default nixpkgs (use 'niv drop nixpkgs' to use default for better sharing)"
      sources.nixpkgs)
    else (builtins.trace "Using IOHK default nixpkgs"
      iohKNix.nixpkgs);

  # for inclusion in pkgs:
  overlays =
    # Haskell.nix (https://github.com/input-output-hk/haskell.nix)
    haskellNix.overlays
    # haskell-nix.haskellLib.extra: some useful extra utility functions for haskell.nix
    ++ iohKNix.overlays.haskell-nix-extra
    # iohkNix: nix utilities and niv:
    ++ iohKNix.overlays.iohkNix
    # our own overlays:
    ++ [
      (pkgs: _: {

        # commonLib: mix pkgs.lib with iohk-nix utils and our own:
        commonLib = pkgs.lib // pkgs.iohkNix
        // import ./util.nix { inherit (pkgs) haskell-nix; }
          # also expose our sources and overlays
        // { inherit (pkgs) sources; inherit overlays; };
      })
      (import ./pkgs.nix)
      (self: super: let
        baseSrc = super.cardanoLedgerSpecsHaskellPackages.cardano-crypto-class.src + "/..";
      in {
        kes_mmm_sumed25519_c = self.callPackage (baseSrc + "/nix/kes_mmm_sumed25519_c.nix") {};
      })
      # And, of course, our haskell-nix-ified cabal project:
    ];

  pkgs = import nixpkgs {
    inherit system crossSystem overlays;
    config = haskellNix.config // config;
  };

in pkgs
