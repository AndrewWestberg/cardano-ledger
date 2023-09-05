{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Conway.Governance (
  EraGov (..),
  GovSnapshots (..),
  insertGovSnapshots,
  EnactState (..),
  RatifyState (..),
  ConwayGovState (..),
  Committee (..),
  GovAction (..),
  GovActionState (..),
  GovActionIx (..),
  GovActionId (..),
  GovActionPurpose (..),
  PrevGovActionIds (..),
  PrevGovActionId (..),
  govActionIdToText,
  Voter (..),
  Vote (..),
  VotingProcedure (..),
  VotingProcedures (..),
  ProposalProcedure (..),
  GovProcedures (..),
  Anchor (..),
  AnchorData (..),
  indexedGovProps,
  Constitution (..),
  ConwayEraGov (..),
  thresholdSPO,
  thresholdDRep,
  thresholdCC,
  ProposalsSnapshot,
  snapshotInsertGovAction,
  snapshotActions,
  snapshotAddVote,
  snapshotIds,
  snapshotRemoveIds,
  fromGovActionStateSeq,
  isConsistent_,
  -- Lenses
  cgGovSnapshotsL,
  cgEnactStateL,
  cgRatifyStateL,
  ensCommitteeL,
  ensConstitutionL,
  ensCurPParamsL,
  ensPrevPParamsL,
  ensPrevGovActionIdsL,
  ensPrevPParamUpdateL,
  ensPrevHardForkL,
  ensPrevCommitteeL,
  ensPrevConstitutionL,
  ensProtVerL,
  rsEnactStateL,
  curPParamsConwayGovStateL,
  prevPParamsConwayGovStateL,
  constitutionScriptL,
  constitutionAnchorL,
  curGovSnapshotsL,
  prevGovSnapshotsL,
  prevDRepsStateL,
  prevCommitteeStateL,
  gasCommitteeVotesL,
  gasDRepVotesL,
  gasStakePoolVotesL,
) where

import Cardano.Ledger.BaseTypes (
  ProtVer (..),
  StrictMaybe (..),
  UnitInterval,
 )
import Cardano.Ledger.Binary (
  DecCBOR (..),
  EncCBOR (..),
  FromCBOR (..),
  ToCBOR (..),
 )
import Cardano.Ledger.Binary.Coders (
  Decode (..),
  Encode (..),
  decode,
  encode,
  (!>),
  (<!),
 )
import Cardano.Ledger.CertState (CommitteeState, DRepState)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Core (
  dvtPPEconomicGroupL,
  dvtPPGovGroupL,
  dvtPPNetworkGroupL,
  dvtPPTechnicalGroupL,
 )
import Cardano.Ledger.Conway.Era (ConwayEra)
import Cardano.Ledger.Conway.Governance.Procedures (
  Anchor (..),
  AnchorData (..),
  Committee (..),
  GovAction (..),
  GovActionId (..),
  GovActionIx (..),
  GovActionPurpose (..),
  GovActionState (..),
  GovProcedures (..),
  PrevGovActionId (..),
  ProposalProcedure (..),
  Vote (..),
  Voter (..),
  VotingProcedure (..),
  VotingProcedures (..),
  gasCommitteeVotesL,
  gasDRepVotesL,
  gasStakePoolVotesL,
  govActionIdToText,
  indexedGovProps,
 )
import Cardano.Ledger.Conway.Governance.Snapshots (
  ProposalsSnapshot,
  fromGovActionStateSeq,
  isConsistent_,
  snapshotActions,
  snapshotAddVote,
  snapshotIds,
  snapshotInsertGovAction,
  snapshotRemoveIds,
 )
import Cardano.Ledger.Conway.PParams (
  ConwayEraPParams,
  DRepVotingThresholds (..),
  PParamGroup (..),
  PoolVotingThresholds (..),
  modifiedGroups,
  ppDRepVotingThresholdsL,
  ppPoolVotingThresholdsL,
 )
import Cardano.Ledger.Core
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Crypto (Crypto)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Shelley.Governance
import Cardano.Ledger.TreeDiff (ToExpr)
import Control.DeepSeq (NFData (..))
import Data.Aeson (KeyValue, ToJSON (..), object, pairs, (.=))
import Data.Default.Class (Default (..))
import Data.Foldable (Foldable (..))
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Generics (Generic)
import Lens.Micro
import NoThunks.Class (NoThunks)

data GovSnapshots era = GovSnapshots
  { curGovSnapshots :: !(ProposalsSnapshot era)
  , prevGovSnapshots :: !(ProposalsSnapshot era)
  , prevDRepsState ::
      !( Map
          (Credential 'DRepRole (EraCrypto era))
          (DRepState (EraCrypto era))
       )
  , prevCommitteeState :: !(CommitteeState era)
  }
  deriving (Generic)

instance EraPParams era => ToExpr (GovSnapshots era)

insertGovSnapshots ::
  GovActionState era ->
  GovSnapshots era ->
  GovSnapshots era
insertGovSnapshots v =
  curGovSnapshotsL %~ snapshotInsertGovAction v

curGovSnapshotsL ::
  Lens'
    (GovSnapshots era)
    (ProposalsSnapshot era)
curGovSnapshotsL = lens curGovSnapshots (\x y -> x {curGovSnapshots = y})

prevGovSnapshotsL ::
  Lens'
    (GovSnapshots era)
    (ProposalsSnapshot era)
prevGovSnapshotsL = lens prevGovSnapshots (\x y -> x {prevGovSnapshots = y})

prevDRepsStateL ::
  Lens'
    (GovSnapshots era)
    (Map (Credential 'DRepRole (EraCrypto era)) (DRepState (EraCrypto era)))
prevDRepsStateL = lens prevDRepsState (\x y -> x {prevDRepsState = y})

prevCommitteeStateL ::
  Lens'
    (GovSnapshots era)
    (CommitteeState era)
prevCommitteeStateL = lens prevCommitteeState (\x y -> x {prevCommitteeState = y})

deriving instance EraPParams era => Eq (GovSnapshots era)

deriving instance EraPParams era => Show (GovSnapshots era)

toGovSnapshotsPairs :: (KeyValue a, EraPParams era) => GovSnapshots era -> [a]
toGovSnapshotsPairs gas@(GovSnapshots _ _ _ _) =
  let GovSnapshots {..} = gas
   in [ "curGovSnapshots" .= curGovSnapshots
      , "prevGovSnapshots" .= prevGovSnapshots
      , "prevDRepsState" .= prevDRepsState
      , "prevCommitteeState" .= prevCommitteeState
      ]

instance EraPParams era => ToJSON (GovSnapshots era) where
  toJSON = object . toGovSnapshotsPairs
  toEncoding = pairs . mconcat . toGovSnapshotsPairs

instance EraPParams era => NFData (GovSnapshots era)

instance EraPParams era => NoThunks (GovSnapshots era)

instance Default (GovSnapshots era) where
  def = GovSnapshots def def def def

instance EraPParams era => EncCBOR (GovSnapshots era) where
  encCBOR GovSnapshots {..} =
    encode $
      Rec GovSnapshots
        !> To curGovSnapshots
        !> To prevGovSnapshots
        !> To prevDRepsState
        !> To prevCommitteeState

instance EraPParams era => DecCBOR (GovSnapshots era) where
  decCBOR =
    decode $
      RecD GovSnapshots
        <! From
        <! From
        <! From
        <! From

instance EraPParams era => ToCBOR (GovSnapshots era) where
  toCBOR = toEraCBOR @era

instance EraPParams era => FromCBOR (GovSnapshots era) where
  fromCBOR = fromEraCBOR @era

data PrevGovActionIds era = PrevGovActionIds
  { pgaPParamUpdate :: !(StrictMaybe (PrevGovActionId 'PParamUpdatePurpose (EraCrypto era)))
  -- ^ The last enacted GovActionId for a protocol parameter update
  , pgaHardFork :: !(StrictMaybe (PrevGovActionId 'HardForkPurpose (EraCrypto era)))
  -- ^ The last enacted GovActionId for a hard fork
  , pgaCommittee :: !(StrictMaybe (PrevGovActionId 'CommitteePurpose (EraCrypto era)))
  -- ^ The last enacted GovActionId for a committee change or no confidence vote
  , pgaConstitution :: !(StrictMaybe (PrevGovActionId 'ConstitutionPurpose (EraCrypto era)))
  -- ^ The last enacted GovActionId for a new constitution
  }
  deriving (Eq, Show, Generic)

instance NoThunks (PrevGovActionIds era)
instance Era era => NFData (PrevGovActionIds era)
instance Default (PrevGovActionIds era)

instance Era era => DecCBOR (PrevGovActionIds era) where
  decCBOR =
    decode $
      RecD PrevGovActionIds
        <! From
        <! From
        <! From
        <! From

instance Era era => EncCBOR (PrevGovActionIds era) where
  encCBOR PrevGovActionIds {..} =
    encode $
      Rec (PrevGovActionIds @era)
        !> To pgaPParamUpdate
        !> To pgaHardFork
        !> To pgaCommittee
        !> To pgaConstitution

toPrevGovActionIdsParis :: (KeyValue a, Era era) => PrevGovActionIds era -> [a]
toPrevGovActionIdsParis pga@(PrevGovActionIds _ _ _ _) =
  let PrevGovActionIds {..} = pga
   in [ "pgaPParamUpdate" .= pgaPParamUpdate
      , "pgaHardFork" .= pgaHardFork
      , "pgaCommittee" .= pgaCommittee
      , "pgaConstitution" .= pgaConstitution
      ]

instance Era era => ToJSON (PrevGovActionIds era) where
  toJSON = object . toPrevGovActionIdsParis
  toEncoding = pairs . mconcat . toPrevGovActionIdsParis

instance ToExpr (PrevGovActionIds era)

data EnactState era = EnactState
  { ensCommittee :: !(StrictMaybe (Committee era))
  -- ^ Constitutional Committee
  , ensConstitution :: !(Constitution era)
  -- ^ Constitution
  , ensPParams :: !(PParams era)
  , ensPrevPParams :: !(PParams era)
  , ensTreasury :: !Coin
  , ensWithdrawals :: !(Map (Credential 'Staking (EraCrypto era)) Coin)
  , ensPrevGovActionIds :: !(PrevGovActionIds era)
  -- ^ Last enacted GovAction Ids
  }
  deriving (Generic)

ensCommitteeL :: Lens' (EnactState era) (StrictMaybe (Committee era))
ensCommitteeL = lens ensCommittee (\x y -> x {ensCommittee = y})

ensConstitutionL :: Lens' (EnactState era) (Constitution era)
ensConstitutionL = lens ensConstitution (\x y -> x {ensConstitution = y})

ensProtVerL :: EraPParams era => Lens' (EnactState era) ProtVer
ensProtVerL = ensCurPParamsL . ppProtocolVersionL

ensCurPParamsL :: Lens' (EnactState era) (PParams era)
ensCurPParamsL = lens ensPParams (\es x -> es {ensPParams = x})

ensPrevPParamsL :: Lens' (EnactState era) (PParams era)
ensPrevPParamsL = lens ensPrevPParams (\es x -> es {ensPrevPParams = x})

ensPrevGovActionIdsL :: Lens' (EnactState era) (PrevGovActionIds era)
ensPrevGovActionIdsL = lens ensPrevGovActionIds (\es x -> es {ensPrevGovActionIds = x})

ensPrevPParamUpdateL ::
  Lens' (EnactState era) (StrictMaybe (PrevGovActionId 'PParamUpdatePurpose (EraCrypto era)))
ensPrevPParamUpdateL =
  lens
    (pgaPParamUpdate . ensPrevGovActionIds)
    (\es x -> es {ensPrevGovActionIds = (ensPrevGovActionIds es) {pgaPParamUpdate = x}})

ensPrevHardForkL ::
  Lens' (EnactState era) (StrictMaybe (PrevGovActionId 'HardForkPurpose (EraCrypto era)))
ensPrevHardForkL =
  lens
    (pgaHardFork . ensPrevGovActionIds)
    (\es x -> es {ensPrevGovActionIds = (ensPrevGovActionIds es) {pgaHardFork = x}})

ensPrevCommitteeL ::
  Lens' (EnactState era) (StrictMaybe (PrevGovActionId 'CommitteePurpose (EraCrypto era)))
ensPrevCommitteeL =
  lens
    (pgaCommittee . ensPrevGovActionIds)
    (\es x -> es {ensPrevGovActionIds = (ensPrevGovActionIds es) {pgaCommittee = x}})

ensPrevConstitutionL ::
  Lens' (EnactState era) (StrictMaybe (PrevGovActionId 'ConstitutionPurpose (EraCrypto era)))
ensPrevConstitutionL =
  lens
    (pgaConstitution . ensPrevGovActionIds)
    (\es x -> es {ensPrevGovActionIds = (ensPrevGovActionIds es) {pgaConstitution = x}})

instance ToExpr (PParamsHKD Identity era) => ToExpr (EnactState era)

instance EraPParams era => ToJSON (EnactState era) where
  toJSON = object . toEnactStatePairs
  toEncoding = pairs . mconcat . toEnactStatePairs

toEnactStatePairs :: (KeyValue a, EraPParams era) => EnactState era -> [a]
toEnactStatePairs cg@(EnactState _ _ _ _ _ _ _) =
  let EnactState {..} = cg
   in [ "committee" .= ensCommittee
      , "constitution" .= ensConstitution
      , "pparams" .= ensPParams
      , "prevPParams" .= ensPParams
      , "treasury" .= ensTreasury
      , "withdrawals" .= ensWithdrawals
      , "prevGovActionIds" .= ensPrevGovActionIds
      ]

deriving instance Eq (PParams era) => Eq (EnactState era)

deriving instance Show (PParams era) => Show (EnactState era)

instance EraPParams era => Default (EnactState era) where
  def =
    EnactState
      def
      def
      def
      def
      (Coin 0)
      def
      def

instance EraPParams era => DecCBOR (EnactState era) where
  decCBOR =
    decode $
      RecD EnactState
        <! From
        <! From
        <! From
        <! From
        <! From
        <! From
        <! From

instance EraPParams era => EncCBOR (EnactState era) where
  encCBOR EnactState {..} =
    encode $
      Rec EnactState
        !> To ensCommittee
        !> To ensConstitution
        !> To ensPParams
        !> To ensPrevPParams
        !> To ensTreasury
        !> To ensWithdrawals
        !> To ensPrevGovActionIds

instance EraPParams era => ToCBOR (EnactState era) where
  toCBOR = toEraCBOR @era

instance EraPParams era => FromCBOR (EnactState era) where
  fromCBOR = fromEraCBOR @era

instance EraPParams era => NFData (EnactState era)

instance EraPParams era => NoThunks (EnactState era)

data RatifyState era = RatifyState
  { rsEnactState :: !(EnactState era)
  , rsRemoved :: !(Set (GovActionId (EraCrypto era)))
  , rsDelayed :: !Bool
  }
  deriving (Generic)

deriving instance EraPParams era => Eq (RatifyState era)

deriving instance EraPParams era => Show (RatifyState era)

rsEnactStateL :: Lens' (RatifyState era) (EnactState era)
rsEnactStateL = lens rsEnactState (\x y -> x {rsEnactState = y})

instance EraPParams era => ToExpr (RatifyState era)

instance EraPParams era => Default (RatifyState era)

instance EraPParams era => DecCBOR (RatifyState era) where
  decCBOR =
    decode $
      RecD RatifyState
        <! From
        <! From
        <! From

instance EraPParams era => EncCBOR (RatifyState era) where
  encCBOR RatifyState {..} =
    encode $
      Rec RatifyState
        !> To rsEnactState
        !> To rsRemoved
        !> To rsDelayed

instance EraPParams era => ToCBOR (RatifyState era) where
  toCBOR = toEraCBOR @era

instance EraPParams era => FromCBOR (RatifyState era) where
  fromCBOR = fromEraCBOR @era

instance EraPParams era => NFData (RatifyState era)

instance EraPParams era => NoThunks (RatifyState era)

instance EraPParams era => ToJSON (RatifyState era) where
  toJSON = object . toRatifyStatePairs
  toEncoding = pairs . mconcat . toRatifyStatePairs

toRatifyStatePairs :: (KeyValue a, EraPParams era) => RatifyState era -> [a]
toRatifyStatePairs cg@(RatifyState _ _ _) =
  let RatifyState {..} = cg
   in [ "enactState" .= rsEnactState
      , "removed" .= rsRemoved
      , "delayed" .= rsDelayed
      ]

data ConwayGovState era = ConwayGovState
  { cgGovSnapshots :: !(GovSnapshots era)
  , cgEnactState :: !(EnactState era)
  }
  deriving (Generic, Eq, Show)

cgGovSnapshotsL :: Lens' (ConwayGovState era) (GovSnapshots era)
cgGovSnapshotsL = lens cgGovSnapshots (\x y -> x {cgGovSnapshots = y})

cgEnactStateL :: Lens' (ConwayGovState era) (EnactState era)
cgEnactStateL = lens cgEnactState (\x y -> x {cgEnactState = y})

{-# DEPRECATED cgRatifyStateL "Use cgEnactStateL instead" #-}
cgRatifyStateL :: Lens' (ConwayGovState era) (RatifyState era)
cgRatifyStateL =
  lens
    (\ConwayGovState {..} -> RatifyState cgEnactState mempty False)
    (\x RatifyState {..} -> x & cgEnactStateL .~ rsEnactState)

curPParamsConwayGovStateL :: Lens' (ConwayGovState era) (PParams era)
curPParamsConwayGovStateL = cgEnactStateL . ensCurPParamsL

prevPParamsConwayGovStateL :: Lens' (ConwayGovState era) (PParams era)
prevPParamsConwayGovStateL = cgEnactStateL . ensPrevPParamsL

instance EraPParams era => DecCBOR (ConwayGovState era) where
  decCBOR =
    decode $
      RecD ConwayGovState
        <! From
        <! From

instance EraPParams era => EncCBOR (ConwayGovState era) where
  encCBOR ConwayGovState {..} =
    encode $
      Rec ConwayGovState
        !> To cgGovSnapshots
        !> To cgEnactState

instance EraPParams era => ToCBOR (ConwayGovState era) where
  toCBOR = toEraCBOR @era

instance EraPParams era => FromCBOR (ConwayGovState era) where
  fromCBOR = fromEraCBOR @era

instance EraPParams era => Default (ConwayGovState era)

instance EraPParams era => NFData (ConwayGovState era)

instance EraPParams era => NoThunks (ConwayGovState era)

instance EraPParams era => ToJSON (ConwayGovState era) where
  toJSON = object . toConwayGovPairs
  toEncoding = pairs . mconcat . toConwayGovPairs

instance EraPParams era => ToExpr (ConwayGovState era)

toConwayGovPairs :: (KeyValue a, EraPParams era) => ConwayGovState era -> [a]
toConwayGovPairs cg@(ConwayGovState _ _) =
  let ConwayGovState {..} = cg
   in [ "gov" .= cgGovSnapshots
      , "ratify" .= cgEnactState
      ]

instance EraPParams (ConwayEra c) => EraGov (ConwayEra c) where
  type GovState (ConwayEra c) = ConwayGovState (ConwayEra c)

  getConstitution g = Just $ g ^. cgEnactStateL . ensConstitutionL

  curPParamsGovStateL = curPParamsConwayGovStateL

  prevPParamsGovStateL = prevPParamsConwayGovStateL

  obligationGovState st =
    foldMap' gasDeposit $ snapshotActions (st ^. cgGovSnapshotsL . curGovSnapshotsL)

class EraGov era => ConwayEraGov era where
  constitutionGovStateL :: Lens' (GovState era) (Constitution era)

instance Crypto c => ConwayEraGov (ConwayEra c) where
  constitutionGovStateL = cgEnactStateL . ensConstitutionL

pparamsUpdateThreshold ::
  forall era.
  ConwayEraPParams era =>
  PParams era ->
  PParamsUpdate era ->
  UnitInterval
pparamsUpdateThreshold pp ppu =
  let thresholdLens = \case
        NetworkGroup -> dvtPPNetworkGroupL
        GovernanceGroup -> dvtPPGovGroupL
        TechnicalGroup -> dvtPPTechnicalGroupL
        EconomicGroup -> dvtPPEconomicGroupL
      lookupGroupThreshold grp =
        pp ^. ppDRepVotingThresholdsL . thresholdLens grp
   in Set.foldr' max minBound $
        Set.map lookupGroupThreshold $
          modifiedGroups @era ppu

thresholdSPO ::
  ConwayEraPParams era =>
  RatifyState era ->
  GovAction era ->
  StrictMaybe UnitInterval
thresholdSPO rSt action =
  let pp = rSt ^. rsEnactStateL . ensCurPParamsL
      PoolVotingThresholds
        { pvtCommitteeNoConfidence
        , pvtCommitteeNormal
        , pvtHardForkInitiation
        } = pp ^. ppPoolVotingThresholdsL
      committee = rSt ^. rsEnactStateL . ensCommitteeL
   in case action of
        NoConfidence {} -> SJust pvtCommitteeNoConfidence
        NewCommittee {} -> SJust $
          case committee of
            SJust _ -> pvtCommitteeNormal
            SNothing -> pvtCommitteeNoConfidence
        NewConstitution {} -> SJust minBound
        HardForkInitiation {} -> SJust pvtHardForkInitiation
        ParameterChange {} -> SJust minBound
        TreasuryWithdrawals {} -> SJust minBound
        InfoAction {} -> SNothing

thresholdCC ::
  StrictMaybe (Committee era) ->
  GovAction era ->
  StrictMaybe UnitInterval
thresholdCC committee action =
  let ccThreshold = committeeQuorum <$> committee
   in case action of
        NoConfidence {} -> SJust minBound
        NewCommittee {} -> SJust minBound
        NewConstitution {} -> ccThreshold
        HardForkInitiation {} -> ccThreshold
        ParameterChange {} -> ccThreshold
        TreasuryWithdrawals {} -> ccThreshold
        InfoAction {} -> SNothing

thresholdDRep ::
  ConwayEraPParams era =>
  RatifyState era ->
  GovAction era ->
  StrictMaybe UnitInterval
thresholdDRep rSt action =
  let pp = rSt ^. rsEnactStateL . ensCurPParamsL
      DRepVotingThresholds
        { dvtCommitteeNoConfidence
        , dvtCommitteeNormal
        , dvtUpdateToConstitution
        , dvtHardForkInitiation
        , dvtTreasuryWithdrawal
        } = pp ^. ppDRepVotingThresholdsL
      committee = rSt ^. rsEnactStateL . ensCommitteeL
   in case action of
        NoConfidence {} -> SJust dvtCommitteeNoConfidence
        NewCommittee {} -> SJust $
          case committee of
            SJust _ -> dvtCommitteeNormal
            SNothing -> dvtCommitteeNoConfidence
        NewConstitution {} -> SJust dvtUpdateToConstitution
        HardForkInitiation {} -> SJust dvtHardForkInitiation
        ParameterChange _ ppu -> SJust $ pparamsUpdateThreshold pp ppu
        TreasuryWithdrawals {} -> SJust dvtTreasuryWithdrawal
        InfoAction {} -> SNothing
