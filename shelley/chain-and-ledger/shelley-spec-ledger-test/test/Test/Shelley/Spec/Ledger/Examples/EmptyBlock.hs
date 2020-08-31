{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Test.Shelley.Spec.Ledger.Examples.EmptyBlock
  ( exEmptyBlock,
  )
where

import Cardano.Ledger.Era (Crypto (..))
import qualified Data.Map.Strict as Map
import GHC.Stack (HasCallStack)
import Shelley.Spec.Ledger.BaseTypes (Nonce)
import Shelley.Spec.Ledger.BlockChain (Block)
import Shelley.Spec.Ledger.OCert (KESPeriod (..))
import Shelley.Spec.Ledger.STS.Chain (ChainState (..))
import Shelley.Spec.Ledger.Slot
  ( BlockNo (..),
    SlotNo (..),
  )
import Shelley.Spec.Ledger.UTxO (UTxO (..))
import Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (ExMock)
import Test.Shelley.Spec.Ledger.Examples (CHAINExample (..))
import Test.Shelley.Spec.Ledger.Examples.Combinators
  ( evolveNonceUnfrozen,
    newLab,
  )
import Test.Shelley.Spec.Ledger.Examples.Federation (coreNodeKeysBySchedule)
import Test.Shelley.Spec.Ledger.Examples.Init
  ( initSt,
    lastByronHeaderHash,
    nonce0,
    ppEx,
  )
import Test.Shelley.Spec.Ledger.Generator.Core
  ( NatNonce (..),
    mkBlockFakeVRF,
    mkOCert,
    zero,
  )
import Test.Shelley.Spec.Ledger.Utils (getBlockNonce)

initStEx1 :: forall era. Era era => ChainState era
initStEx1 = initSt (UTxO Map.empty)

blockEx1 ::
  forall era.
  ( HasCallStack,
    Era era,
    ExMock (Crypto era)
  ) =>
  Block era
blockEx1 =
  mkBlockFakeVRF
    lastByronHeaderHash
    (coreNodeKeysBySchedule ppEx 10)
    []
    (SlotNo 10)
    (BlockNo 1)
    (nonce0 @era)
    (NatNonce 1)
    zero
    0
    0
    (mkOCert (coreNodeKeysBySchedule ppEx 10) 0 (KESPeriod 0))

blockNonce :: forall era. (HasCallStack, Era era, ExMock (Crypto era)) => Nonce
blockNonce = getBlockNonce (blockEx1 @era)

expectedStEx1 :: forall era. (Era era, ExMock (Crypto era)) => ChainState era
expectedStEx1 =
  (evolveNonceUnfrozen (blockNonce @era))
    . (newLab blockEx1)
    $ initStEx1

-- | = Empty Block Example
--
-- This is the most minimal example of using the CHAIN STS transition.
-- It applies an empty block to an initial shelley chain state.
--
-- The only things that change in the chain state are the
-- evolving and candidate nonces, and the last applied block.
exEmptyBlock :: (Era era, ExMock (Crypto era)) => CHAINExample era
exEmptyBlock = CHAINExample initStEx1 blockEx1 (Right expectedStEx1)
