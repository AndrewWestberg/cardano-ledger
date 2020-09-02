{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Shelley.Spec.Ledger.STS.Ledger
  ( LEDGER,
    LedgerEnv (..),
    PredicateFailure (..),
  )
where

import Cardano.Binary
  ( FromCBOR (..),
    ToCBOR (..),
    encodeListLen,
  )
import Cardano.Ledger.Era (Era(..))
import Cardano.Prelude (NoUnexpectedThunks (..))
import Control.State.Transition
  ( Assertion (..),
    AssertionViolation (..),
    Embed (..),
    STS (..),
    TRC (..),
    TransitionRule,
    judgmentContext,
    trans,
  )
import qualified Data.Sequence.Strict as StrictSeq
import Data.Typeable (Typeable)
import Data.Word (Word8)
import GHC.Generics (Generic)
import Shelley.Spec.Ledger.BaseTypes (ShelleyBase, invalidKey)
import Shelley.Spec.Ledger.EpochBoundary (obligation)
import Shelley.Spec.Ledger.Keys (DSignable, Hash)
import Shelley.Spec.Ledger.LedgerState
  ( AccountState,
    DPState (..),
    DState (..),
    Ix,
    PState (..),
    UTxOState (..),
  )
import Shelley.Spec.Ledger.PParams (PParams)
import Shelley.Spec.Ledger.STS.Delegs (DELEGS, DelegsEnv (..))
import Shelley.Spec.Ledger.STS.Utxo
  ( UtxoEnv (..),
    pattern BadInputsUTxO,
    pattern ExpiredUTxO,
    pattern FeeTooSmallUTxO,
    pattern InputSetEmptyUTxO,
    pattern MaxTxSizeUTxO,
    pattern OutputTooSmallUTxO,
    pattern UpdateFailure,
    pattern ValueNotConservedUTxO,
  )
import Shelley.Spec.Ledger.STS.Utxow (PredicateFailure (..), UTXOW)
import Shelley.Spec.Ledger.Serialization (decodeRecordSum)
import Shelley.Spec.Ledger.Slot (SlotNo)
import Shelley.Spec.Ledger.Tx (Tx (..))
import Shelley.Spec.Ledger.TxData(Body(..))

data LEDGER era

data LedgerEnv = LedgerEnv
  { ledgerSlotNo :: SlotNo,
    ledgerIx :: Ix,
    ledgerPp :: PParams,
    ledgerAccount :: AccountState
  }
  deriving (Show)

instance
  ( Era era,
    Body era,
    DSignable era (Hash era (TxBody era))
  ) =>
  STS (LEDGER era)
  where
  type
    State (LEDGER era) =
      (UTxOState era, DPState era)
  type Signal (LEDGER era) = Tx era
  type Environment (LEDGER era) = LedgerEnv
  type BaseM (LEDGER era) = ShelleyBase
  data PredicateFailure (LEDGER era)
    = UtxowFailure (PredicateFailure (UTXOW era)) -- Subtransition Failures
    | DelegsFailure (PredicateFailure (DELEGS era)) -- Subtransition Failures
    deriving (Show, Eq, Generic)

  initialRules = []
  transitionRules = [ledgerTransition]

  renderAssertionViolation AssertionViolation {avSTS, avMsg, avCtx, avState} =
    "AssertionViolation (" <> avSTS <> "): " <> avMsg
      <> "\n"
      <> show avCtx
      <> "\n"
      <> show avState

  assertions =
    [ PostCondition
        "Deposit pot must equal obligation"
        ( \(TRC (LedgerEnv {ledgerPp}, _, _))
           (utxoSt, DPState {_dstate, _pstate}) ->
              obligation ledgerPp (_rewards _dstate) (_pParams _pstate)
                == _deposited utxoSt
        )
    ]

instance (Era era) => NoUnexpectedThunks (PredicateFailure (LEDGER era))

instance
  (Typeable era, Era era) =>
  ToCBOR (PredicateFailure (LEDGER era))
  where
  toCBOR = \case
    (UtxowFailure a) -> encodeListLen 2 <> toCBOR (0 :: Word8) <> toCBOR a
    (DelegsFailure a) -> encodeListLen 2 <> toCBOR (1 :: Word8) <> toCBOR a

instance
  (Era era) =>
  FromCBOR (PredicateFailure (LEDGER era))
  where
  fromCBOR =
    decodeRecordSum "PredicateFailure (LEDGER era)" $
      ( \case
          0 -> do
            a <- fromCBOR
            pure (2, UtxowFailure a)
          1 -> do
            a <- fromCBOR
            pure (2, DelegsFailure a)
          k -> invalidKey k
      )

ledgerTransition :: forall era.
  ( Era era,
    Body era,
    DSignable era (Hash era (TxBody era))
  ) =>
  TransitionRule (LEDGER era)
ledgerTransition = do
  TRC (LedgerEnv slot txIx pp account, (utxoSt, dpstate), tx) <- judgmentContext

  dpstate' <-
    trans @(DELEGS era) $
      TRC
        ( DelegsEnv slot txIx pp tx account,
          dpstate,
          StrictSeq.getSeq $ (certsB @ era) $ _body tx
        )

  let DPState dstate pstate = dpstate
      genDelegs = _genDelegs dstate
      stpools = _pParams pstate

  utxoSt' <-
    trans @(UTXOW era) $
      TRC
        ( UtxoEnv slot pp stpools genDelegs,
          utxoSt,
          tx
        )
  pure (utxoSt', dpstate')

instance
  ( Era era,
    Body era,
    DSignable era (Hash era (TxBody era))
  ) =>
  Embed (DELEGS era) (LEDGER era)
  where
  wrapFailed = DelegsFailure

instance
  ( Era era,
    Body era,
    DSignable era (Hash era (TxBody era))
  ) =>
  Embed (UTXOW era) (LEDGER era)
  where
  wrapFailed = UtxowFailure
