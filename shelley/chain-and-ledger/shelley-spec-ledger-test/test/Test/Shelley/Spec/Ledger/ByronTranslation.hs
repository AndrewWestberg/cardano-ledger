{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Shelley.Spec.Ledger.ByronTranslation (testGroupByronTranslation) where

import qualified Cardano.Chain.Common as Byron
import qualified Cardano.Chain.UTxO as Byron
import qualified Cardano.Ledger.Crypto as CryptoClass
import Cardano.Ledger.Shelley (Shelley)
import Data.Proxy
import Shelley.Spec.Ledger.API.ByronTranslation
import Shelley.Spec.Ledger.Address
import Shelley.Spec.Ledger.Coin
import Shelley.Spec.Ledger.TxBody
import Test.Cardano.Chain.UTxO.Gen (genCompactTxOut)
import Test.QuickCheck.Hedgehog (hedgehog)
import Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (C_Crypto)
import Test.Tasty
import Test.Tasty.QuickCheck

{------------------------------------------------------------------------------
  Top-level tests
------------------------------------------------------------------------------}

testGroupByronTranslation :: forall era. Era era => Proxy era -> TestTree
testGroupByronTranslation proxy =
  testGroup
    "Translation from Byron to Shelley"
    [ testProperty "translateTxOut correctness" (prop_translateTxOut_correctness proxy)
    ]

{------------------------------------------------------------------------------
  Properties
------------------------------------------------------------------------------}

prop_translateTxOut_correctness :: forall era. Era era => Proxy era -> Byron.CompactTxOut -> Property
prop_translateTxOut_correctness _proxy compactTxOut =
  translateTxOutByronToShelley
    @C_Crypto
    (Byron.fromCompactTxOut compactTxOut)
    === translateCompactTxOutByronToShelley compactTxOut

{------------------------------------------------------------------------------
  Reference implementation
------------------------------------------------------------------------------}

translateTxOutByronToShelley ::
  forall crypto.
  CryptoClass.Crypto crypto =>
  Byron.TxOut ->
  TxOut (Shelley crypto)
translateTxOutByronToShelley (Byron.TxOut addr amount) =
  TxOut (translateAddr addr) (translateAmount amount)
  where
    translateAmount :: Byron.Lovelace -> Coin
    translateAmount = Coin . Byron.lovelaceToInteger

    translateAddr :: Byron.Address -> Addr era
    translateAddr = AddrBootstrap . BootstrapAddress

{------------------------------------------------------------------------------
  Generators
------------------------------------------------------------------------------}

instance Arbitrary Byron.CompactTxOut where
  arbitrary = hedgehog genCompactTxOut
