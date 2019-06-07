{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeApplications  #-}

-- | Generation of genesis data for testnet

module Cardano.Chain.Genesis.Generate
  ( GeneratedSecrets(..)
  , gsSigningKeys
  , gsSigningKeysPoor
  , PoorSecret(..)
  , generateGenesisData
  , GenesisDataGenerationError(..)

  -- * Helpers which are also used by keygen.
  , poorSecretToEncKey
  , poorSecretToKey
  )
where

import Cardano.Prelude

import Control.Monad.Except (liftEither)
import Crypto.Random (MonadRandom, getRandomBytes)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.Time (UTCTime)
import Formatting (build, bprint, int, stext)
import qualified Formatting.Buildable as B

import Cardano.Binary (serialize')
import Cardano.Chain.Common
  ( Address
  , Lovelace
  , LovelaceError
  , addLovelace
  , applyLovelacePortionDown
  , deriveFirstHDAddress
  , divLovelace
  , makeVerKeyAddress
  , mkKnownLovelace
  , hashKey
  , modLovelace
  , scaleLovelace
  , subLovelace
  , sumLovelace
  )
import Cardano.Chain.Common.NetworkMagic (makeNetworkMagic)
import qualified Cardano.Chain.Delegation.Certificate as Delegation
import Cardano.Chain.Genesis.AvvmBalances (GenesisAvvmBalances(..))
import Cardano.Chain.Genesis.Data (GenesisData(..))
import Cardano.Chain.Genesis.Delegation
  (GenesisDelegation(..), GenesisDelegationError, mkGenesisDelegation)
import Cardano.Chain.Genesis.Initializer
  (FakeAvvmOptions(..), GenesisInitializer(..), TestnetBalanceOptions(..))
import Cardano.Chain.Genesis.NonAvvmBalances (GenesisNonAvvmBalances(..))
import Cardano.Chain.Genesis.Spec (GenesisSpec(..))
import Cardano.Chain.Genesis.KeyHashes (GenesisKeyHashes(..))
import Cardano.Crypto
  ( EncryptedSigningKey
  , SigningKey
  , createPsk
  , deterministic
  , emptyPassphrase
  , encToSigning
  , getProtocolMagicId
  , keyGen
  , noPassEncrypt
  , noPassSafeSigner
  , redeemDeterministicKeyGen
  , safeKeyGen
  , toVerification
  )


-- | Poor node secret
data PoorSecret = PoorSecret SigningKey | PoorEncryptedSecret EncryptedSigningKey

-- | Valuable secrets which can unlock genesis data.
data GeneratedSecrets = GeneratedSecrets
    { gsDlgIssuersSecrets :: ![SigningKey]
    -- ^ Secret keys which issued heavyweight delegation certificates
    -- in genesis data. If genesis heavyweight delegation isn't used,
    -- this list is empty.
    , gsRichSecrets       :: ![SigningKey]
    -- ^ All secrets of rich nodes.
    , gsPoorSecrets       :: ![PoorSecret]
    -- ^ Keys for HD addresses of poor nodes.
    , gsFakeAvvmSeeds     :: ![ByteString]
    -- ^ Fake avvm seeds.
    }

gsSigningKeys :: GeneratedSecrets -> [SigningKey]
gsSigningKeys gs = gsRichSecrets gs <> gsSigningKeysPoor gs

gsSigningKeysPoor :: GeneratedSecrets -> [SigningKey]
gsSigningKeysPoor = map poorSecretToKey . gsPoorSecrets

data GenesisDataGenerationError
  = GenesisDataAddressBalanceMismatch Text Int Int
  | GenesisDataGenerationDelegationError GenesisDelegationError
  | GenesisDataGenerationDistributionMismatch Lovelace Lovelace
  | GenesisDataGenerationLovelaceError LovelaceError
  | GenesisDataGenerationPassPhraseMismatch
  | GenesisDataGenerationRedeemKeyGen
  deriving (Eq, Show)

instance B.Buildable GenesisDataGenerationError where
  build = \case
    GenesisDataAddressBalanceMismatch distr addresses balances ->
      bprint ("GenesisData address balance mismatch, Distribution: "
             . stext
             . " Addresses list length: "
             . int
             . " Balances list length: "
             . int
             )
             distr
             addresses
             balances
    GenesisDataGenerationDelegationError genesisDelegError ->
      bprint ("GenesisDataGenerationDelegationError: "
             . build
             )
             genesisDelegError
    GenesisDataGenerationDistributionMismatch testBalance totalBalance ->
      bprint ("GenesisDataGenerationDistributionMismatch: Test balance: "
             . build
             . " Total balance: "
             . build
             )
             testBalance
             totalBalance
    GenesisDataGenerationLovelaceError lovelaceErr ->
      bprint ("GenesisDataGenerationLovelaceError: "
             . build
             )
             lovelaceErr
    GenesisDataGenerationPassPhraseMismatch ->
      bprint "GenesisDataGenerationPassPhraseMismatch"
    GenesisDataGenerationRedeemKeyGen ->
      bprint "GenesisDataGenerationRedeemKeyGen"


generateGenesisData
  :: MonadError GenesisDataGenerationError m
  => UTCTime
  -> GenesisSpec
  -> m (GenesisData, GeneratedSecrets)
generateGenesisData startTime genesisSpec = do
  -- Genesis Keys
  let
    genesisSecrets =
      if giUseHeavyDlg gi then dlgIssuersSecrets else richSecrets

    genesisKeyHashes :: GenesisKeyHashes
    genesisKeyHashes =
      GenesisKeyHashes
        .   Set.fromList
        $   hashKey
        .   toVerification
        <$> genesisSecrets

  -- Heavyweight delegation.
  -- genesisDlgList is empty if giUseHeavyDlg = False
  let
    genesisDlgList :: [Delegation.Certificate]
    genesisDlgList =
      (\(issuerSK, delegateSK) -> createPsk
          (getProtocolMagicId pm)
          (noPassSafeSigner issuerSK)
          (toVerification delegateSK)
          0
        )
        <$> zip dlgIssuersSecrets richSecrets

  genesisDlg <-
    mkGenesisDelegation
        (  M.elems (unGenesisDelegation $ gsHeavyDelegation genesisSpec)
        <> genesisDlgList
        )
      `wrapError` GenesisDataGenerationDelegationError

  -- Real AVVM Balances
  let
    applyAvvmBalanceFactor :: Map k Lovelace -> Map k Lovelace
    applyAvvmBalanceFactor =
      map (applyLovelacePortionDown $ giAvvmBalanceFactor gi)

    realAvvmMultiplied :: GenesisAvvmBalances
    realAvvmMultiplied =
      GenesisAvvmBalances . applyAvvmBalanceFactor $ unGenesisAvvmBalances
        realAvvmBalances

  -- Fake AVVM Balances
  fakeAvvmVerificationKeys <-
    mapM (maybe (throwError GenesisDataGenerationRedeemKeyGen) (pure . fst))
      $ fmap redeemDeterministicKeyGen (gsFakeAvvmSeeds generatedSecrets)
  let
    fakeAvvmDistr = GenesisAvvmBalances . M.fromList $ map
      (, faoOneBalance fao)
      fakeAvvmVerificationKeys

  -- Non AVVM balances
  ---- Addresses
  let
    createAddressPoor
      :: MonadError GenesisDataGenerationError m => PoorSecret -> m Address
    createAddressPoor (PoorEncryptedSecret hdwSk) =
      maybe (throwError GenesisDataGenerationPassPhraseMismatch) (pure . fst)
        $ deriveFirstHDAddress nm emptyPassphrase hdwSk
    createAddressPoor (PoorSecret secret) =
      pure $ makeVerKeyAddress nm (toVerification secret)
  let richAddresses = map (makeVerKeyAddress nm . toVerification) richSecrets

  poorAddresses        <- mapM createAddressPoor poorSecrets

  ---- Balances
  totalFakeAvvmBalance <-
    scaleLovelace (faoOneBalance fao) (faoCount fao)
      `wrapError` GenesisDataGenerationLovelaceError

  -- Compute total balance to generate
  avvmSum <-
    sumLovelace (unGenesisAvvmBalances realAvvmMultiplied)
      `wrapError` GenesisDataGenerationLovelaceError
  maxTnBalance <-
    subLovelace maxBound avvmSum `wrapError` GenesisDataGenerationLovelaceError
  let tnBalance = min maxTnBalance (tboTotalBalance tbo)

  let
    safeZip
      :: MonadError GenesisDataGenerationError m
      => Text
      -> [a]
      -> [b]
      -> m [(a, b)]
    safeZip s a b = if length a /= length b
      then throwError
        $ GenesisDataAddressBalanceMismatch s (length a) (length b)
      else pure $ zip a b

  nonAvvmBalance <-
    subLovelace tnBalance totalFakeAvvmBalance
      `wrapError` GenesisDataGenerationLovelaceError

  (richBals, poorBals) <- genTestnetDistribution tbo nonAvvmBalance

  richDistr <- safeZip "richDistr" richAddresses richBals
  poorDistr <- safeZip "poorDistr" poorAddresses poorBals

  let
    nonAvvmDistr = GenesisNonAvvmBalances . M.fromList $ richDistr ++ poorDistr

  let
    genesisData = GenesisData
      { gdGenesisKeyHashes = genesisKeyHashes
      , gdHeavyDelegation = genesisDlg
      , gdStartTime = startTime
      , gdNonAvvmBalances = nonAvvmDistr
      , gdProtocolParameters = gsProtocolParameters genesisSpec
      , gdK         = gsK genesisSpec
      , gdProtocolMagicId = getProtocolMagicId pm
      , gdAvvmDistr = fakeAvvmDistr <> realAvvmMultiplied
      }

  pure (genesisData, generatedSecrets)
 where
  pm          = gsProtocolMagic genesisSpec
  nm          = makeNetworkMagic pm
  realAvvmBalances = gsAvvmDistr genesisSpec

  gi          = gsInitializer genesisSpec

  generatedSecrets = generateSecrets gi
  dlgIssuersSecrets = gsDlgIssuersSecrets generatedSecrets
  richSecrets = gsRichSecrets generatedSecrets
  poorSecrets = gsPoorSecrets generatedSecrets

  fao         = giFakeAvvmBalance gi
  tbo         = giTestBalance gi


generateSecrets :: GenesisInitializer -> GeneratedSecrets
generateSecrets gi = deterministic (serialize' $ giSeed gi) $ do

  -- Generate fake AVVM seeds
  fakeAvvmSeeds <- replicateM (fromIntegral $ faoCount fao) (getRandomBytes 32)

  -- Generate secret keys
  dlgIssuersSecrets <- if giUseHeavyDlg gi
    then replicateRich (snd <$> keyGen)
    else pure []

  richSecrets <- replicateRich (snd <$> keyGen)

  poorSecrets <- replicateM (fromIntegral $ tboPoors tbo) genPoorSecret

  pure $ GeneratedSecrets
    { gsDlgIssuersSecrets = dlgIssuersSecrets
    , gsRichSecrets       = richSecrets
    , gsPoorSecrets       = poorSecrets
    , gsFakeAvvmSeeds     = fakeAvvmSeeds
    }
 where
  fao = giFakeAvvmBalance gi
  tbo = giTestBalance gi

  replicateRich :: Applicative m => m a -> m [a]
  replicateRich = replicateM (fromIntegral $ tboRichmen tbo)

  genPoorSecret :: MonadRandom m => m PoorSecret
  genPoorSecret = if tboUseHDAddresses tbo
    then PoorEncryptedSecret . snd <$> safeKeyGen emptyPassphrase
    else PoorSecret . snd <$> keyGen


----------------------------------------------------------------------------
-- Exported helpers
----------------------------------------------------------------------------

poorSecretToKey :: PoorSecret -> SigningKey
poorSecretToKey (PoorSecret          key   ) = key
poorSecretToKey (PoorEncryptedSecret encKey) = encToSigning encKey

poorSecretToEncKey :: PoorSecret -> EncryptedSigningKey
poorSecretToEncKey (PoorSecret          key ) = noPassEncrypt key
poorSecretToEncKey (PoorEncryptedSecret encr) = encr


----------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------

-- | Generates balance distribution for testnet
genTestnetDistribution
  :: MonadError GenesisDataGenerationError m
  => TestnetBalanceOptions
  -> Lovelace
  -> m ([Lovelace], [Lovelace])
genTestnetDistribution tbo testBalance = do
  (richBalances, poorBalances, totalBalance) <-
    liftEither . first GenesisDataGenerationLovelaceError $ do
      richmanBalance      <- divLovelace desiredRichBalance tboRichmen

      richmanBalanceExtra <- modLovelace desiredRichBalance tboRichmen

      richmanBalance'     <- if tboRichmen == 0
        then pure $ mkKnownLovelace @0
        else addLovelace
          richmanBalance
          (if richmanBalanceExtra > mkKnownLovelace @0
            then mkKnownLovelace @1
            else mkKnownLovelace @0
          )

      totalRichBalance    <- scaleLovelace richmanBalance' tboRichmen

      desiredPoorsBalance <- subLovelace testBalance totalRichBalance

      poorBalance         <- if tboPoors == 0
        then pure $ mkKnownLovelace @0
        else divLovelace desiredPoorsBalance tboPoors

      totalPoorBalance <- scaleLovelace poorBalance tboPoors

      totalBalance     <- addLovelace totalRichBalance totalPoorBalance

      pure
        ( replicate (fromIntegral tboRichmen) richmanBalance'
        , replicate (fromIntegral tboPoors)   poorBalance
        , totalBalance
        )

  if totalBalance <= testBalance
    then pure (richBalances, poorBalances)
    else throwError
      $ GenesisDataGenerationDistributionMismatch testBalance totalBalance
 where
  TestnetBalanceOptions { tboPoors, tboRichmen } = tbo

  desiredRichBalance =
    applyLovelacePortionDown (tboRichmenShare tbo) testBalance
