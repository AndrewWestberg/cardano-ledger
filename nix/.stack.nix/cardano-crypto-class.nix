{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = { development = false; };
    package = {
      specVersion = "1.10";
      identifier = { name = "cardano-crypto-class"; version = "2.0.0"; };
      license = "MIT";
      copyright = "2019 IOHK";
      maintainer = "operations@iohk.io";
      author = "IOHK";
      homepage = "";
      url = "";
      synopsis = "Type classes abstracting over cryptography primitives for Cardano";
      description = "Type classes abstracting over cryptography primitives for Cardano";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.base16-bytestring)
          (hsPkgs.bytestring)
          (hsPkgs.cardano-binary)
          (hsPkgs.cardano-prelude)
          (hsPkgs.cryptonite)
          (hsPkgs.deepseq)
          (hsPkgs.memory)
          (hsPkgs.reflection)
          (hsPkgs.vector)
          ];
        };
      tests = {
        "test-crypto" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.bytestring)
            (hsPkgs.cardano-binary)
            (hsPkgs.cardano-crypto-class)
            (hsPkgs.cborg)
            (hsPkgs.cryptonite)
            (hsPkgs.QuickCheck)
            (hsPkgs.tasty)
            (hsPkgs.tasty-quickcheck)
            ];
          };
        };
      };
    } // {
    src = (pkgs.lib).mkDefault (pkgs.fetchgit {
      url = "https://github.com/input-output-hk/cardano-base";
      rev = "53d773907edea2fdcf65cebeb81ab5e47eeab805";
      sha256 = "1x3jacfggim9ynnw8rzaswhbvmhk13hid44k91a8137fv0jg6l14";
      });
    postUnpack = "sourceRoot+=/cardano-crypto-class; echo source root reset to \$sourceRoot";
    }