{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Shelley.Spec.Ledger.Data.BlockChainData
  ( HashHeader (..),
    PrevHash (..),
    LastAppliedBlock (..),
    lastAppliedHash,
    BHBody (..),
    poolIDfromBHBody,
    issuerIDfromBHBody,
    BHeader (BHeader),
    Block (Block),
    LaxBlock (..),
    TxSeq (TxSeq, txSeqTxns'),
    HashBBody,
    bhHash,
    bbHash,
    hashHeaderToNonce,
    prevHashToNonce,
    bHeaderSize,
    bBodySize,
    slotToNonce,
    hBbsize,
    -- accessor functions
    bheader,
    bhbody,
    bbody,
    bnonce,
    --
    seedEta,
    seedL,
    incrBlocks,
    mkSeed,
    checkLeaderValue,
  )
where

import Cardano.Binary
  ( Annotator (..),
    Case (..),
    Decoder,
    FromCBOR (fromCBOR),
    ToCBOR (..),
    TokenType (TypeNull),
    annotatorSlice,
    decodeNull,
    encodeListLen,
    encodeNull,
    encodePreEncoded,
    peekTokenType,
    serialize',
    serializeEncoding,
    serializeEncoding',
    szCases,
    withSlice,
    withWordSize,
  )
import qualified Cardano.Crypto.Hash.Class as Hash
import qualified Cardano.Crypto.KES as KES
import Cardano.Crypto.Util (SignableRepresentation (..))
import qualified Cardano.Crypto.VRF as VRF
import Cardano.Ledger.Era
import Cardano.Prelude
  ( AllowThunksIn (..),
    ByteString,
    LByteString,
    NFData,
    NoUnexpectedThunks (..),
  )
import Cardano.Slotting.Slot (WithOrigin (..))
import Control.Monad (unless)
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Builder.Extra as BS
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Coerce (coerce)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Ratio ((%))
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Sequence.Strict (StrictSeq)
import qualified Data.Sequence.Strict as StrictSeq
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shelley.Spec.Ledger.BaseTypes
  ( ActiveSlotCoeff,
    FixedPoint,
    Nonce (..),
    Seed (..),
    activeSlotLog,
    activeSlotVal,
    intervalValue,
    mkNonceFromNumber,
    mkNonceFromOutputVRF,
    strictMaybeToMaybe,
  )
import Shelley.Spec.Ledger.EpochBoundary (BlocksMade (..))
import Shelley.Spec.Ledger.Hashing (HashAnnotated (..))
import Shelley.Spec.Ledger.Keys
  ( CertifiedVRF,
    Hash,
    KeyHash,
    KeyRole (..),
    SignedKES,
    VKey,
    VerKeyVRF,
    decodeSignedKES,
    decodeVerKeyVRF,
    encodeSignedKES,
    encodeVerKeyVRF,
    hashKey,
  )
import Shelley.Spec.Ledger.OCert (OCert (..))
import Shelley.Spec.Ledger.PParams (ProtVer (..))
import Shelley.Spec.Ledger.Serialization
  ( FromCBORGroup (..),
    ToCBORGroup (..),
    decodeMap,
    decodeRecordNamed,
    decodeSeq,
    encodeFoldableEncoder,
    encodeFoldableMapEncoder,
    listLenInt,
    runByteBuilder,
  )
import Shelley.Spec.Ledger.Slot (BlockNo (..), SlotNo (..))
import Shelley.Spec.Ledger.Tx (Tx (..), decodeWits, segwitTx, txWitsBytes)
import Shelley.Spec.NonIntegral (CompareResult (..), taylorExpCmp)

-- | The hash of a Block Header
newtype HashHeader era = HashHeader {unHashHeader :: (Hash era (BHeader era))}
  deriving (Show, Eq, Generic, Ord)
  deriving newtype (NFData, NoUnexpectedThunks)

deriving instance Era era => ToCBOR (HashHeader era)

deriving instance Era era => FromCBOR (HashHeader era)

data TxSeq era = TxSeq'
  { txSeqTxns' :: !(StrictSeq (Tx era)),
    txSeqBodyBytes :: LByteString,
    txSeqWitsBytes :: LByteString,
    txSeqMetadataBytes :: LByteString
  }
  deriving (Eq, Show, Generic)
  deriving
    (NoUnexpectedThunks)
    via AllowThunksIn
          '[ "txSeqBodyBytes",
             "txSeqWitsBytes",
             "txSeqMetadataBytes"
           ]
          (TxSeq era)

pattern TxSeq :: Era era => StrictSeq (Tx era) -> TxSeq era
pattern TxSeq xs <-
  TxSeq' xs _ _ _
  where
    TxSeq txns =
      let serializeFoldable x =
            serializeEncoding $
              encodeFoldableEncoder (encodePreEncoded . BSL.toStrict) x
          metaChunk index m =
            ( \metadata ->
                toCBOR index <> toCBOR metadata
            )
              <$> strictMaybeToMaybe m
       in TxSeq'
            { txSeqTxns' = txns,
              txSeqBodyBytes =
                serializeEncoding . encodeFoldableEncoder (toCBOR . _body) $ txns,
              txSeqWitsBytes = serializeFoldable $ txWitsBytes . _witnessSet <$> txns,
              txSeqMetadataBytes =
                serializeEncoding . encodeFoldableMapEncoder metaChunk $
                  _metadata <$> txns
            }

{-# COMPLETE TxSeq #-}

instance
  Era era =>
  ToCBORGroup (TxSeq era)
  where
  toCBORGroup (TxSeq' _ bodyBytes witsBytes metadataBytes) =
    encodePreEncoded $
      BSL.toStrict $
        bodyBytes <> witsBytes <> metadataBytes
  encodedGroupSizeExpr size _proxy =
    encodedSizeExpr size (Proxy :: Proxy ByteString)
      + encodedSizeExpr size (Proxy :: Proxy ByteString)
      + encodedSizeExpr size (Proxy :: Proxy ByteString)
  listLen _ = 3
  listLenBound _ = 3

-- | Hash of block body
newtype HashBBody era = HashBBody {unHashBody :: (Hash era (TxSeq era))}
  deriving (Show, Eq, Ord, NoUnexpectedThunks)

deriving instance Era era => ToCBOR (HashBBody era)

deriving instance Era era => FromCBOR (HashBBody era)

-- | Hash a given block header
bhHash ::
  Era era =>
  BHeader era ->
  HashHeader era
bhHash = HashHeader . hashAnnotated

-- | Hash a given block body
bbHash ::
  forall era.
  Era era =>
  TxSeq era ->
  HashBBody era
bbHash (TxSeq' _ bodies wits md) =
  (HashBBody . coerce) $
    hashStrict (hashPart bodies <> hashPart wits <> hashPart md)
  where
    hashStrict :: ByteString -> Hash era ByteString
    hashStrict = Hash.hashWith id
    hashPart = Hash.hashToBytes . hashStrict . BSL.toStrict

-- | HashHeader to Nonce
hashHeaderToNonce :: HashHeader era -> Nonce
hashHeaderToNonce = Nonce . coerce

data BHeader era = BHeader'
  { bHeaderBody' :: !(BHBody era),
    bHeaderSig' :: !(SignedKES era (BHBody era)),
    bHeaderBytes :: !LByteString
  }
  deriving (Generic)
  deriving
    (NoUnexpectedThunks)
    via AllowThunksIn '["bHeaderBytes"] (BHeader era)

instance Era era => HashAnnotated (BHeader era) era

deriving instance Era era => Eq (BHeader era)

deriving instance Era era => Show (BHeader era)

pattern BHeader :: Era era => BHBody era -> SignedKES era (BHBody era) -> BHeader era
pattern BHeader bHeaderBody' bHeaderSig' <-
  BHeader' {bHeaderBody', bHeaderSig'}
  where
    BHeader body sig =
      let mkBytes bhBody kESig =
            serializeEncoding $
              encodeListLen 2
                <> toCBOR bhBody
                <> encodeSignedKES kESig
       in BHeader' body sig (mkBytes body sig)

{-# COMPLETE BHeader #-}

instance
  Era era =>
  ToCBOR (BHeader era)
  where
  toCBOR (BHeader' _ _ bytes) = encodePreEncoded (BSL.toStrict bytes)
  encodedSizeExpr size proxy =
    1
      + encodedSizeExpr size (bHeaderBody' <$> proxy)
      + KES.encodedSigKESSizeExpr ((KES.getSig . bHeaderSig') <$> proxy)

instance
  Era era =>
  FromCBOR (Annotator (BHeader era))
  where
  fromCBOR = annotatorSlice $
    decodeRecordNamed "Header" (const 2) $ do
      bhb <- fromCBOR
      sig <- decodeSignedKES
      pure $ BHeader' <$> pure bhb <*> pure sig

-- | The previous hash of a block
data PrevHash era = GenesisHash | BlockHash !(HashHeader era)
  deriving (Show, Eq, Generic, Ord)

instance Era era => NoUnexpectedThunks (PrevHash era)

instance
  Era era =>
  ToCBOR (PrevHash era)
  where
  toCBOR GenesisHash = encodeNull
  toCBOR (BlockHash h) = toCBOR h
  encodedSizeExpr size proxy =
    szCases
      [ Case "GenesisHash" 1,
        Case
          "BlockHash"
          ( encodedSizeExpr
              size
              ( ( \case
                    -- we are mapping a 'Proxy', so nothing can
                    -- go wrong here
                    GenesisHash -> error "impossible happend"
                    BlockHash h -> h
                )
                  <$> proxy
              )
          )
      ]

instance
  Era era =>
  FromCBOR (PrevHash era)
  where
  fromCBOR = do
    peekTokenType >>= \case
      TypeNull -> do
        decodeNull
        pure GenesisHash
      _ -> BlockHash <$> fromCBOR

prevHashToNonce ::
  PrevHash era ->
  Nonce
prevHashToNonce = \case
  GenesisHash -> NeutralNonce -- This case can only happen when starting Shelley from genesis,
  -- setting the intial chain state to some epoch e,
  -- and having the first block be in epoch e+1.
  -- In this edge case there is no need to add any extra
  -- entropy via the previous header hash to the next epoch nonce,
  -- so using the neutral nonce is appropriate.
  BlockHash ph -> hashHeaderToNonce ph

data LastAppliedBlock era = LastAppliedBlock
  { labBlockNo :: !BlockNo,
    labSlotNo :: !SlotNo,
    labHash :: !(HashHeader era)
  }
  deriving (Show, Eq, Generic)

instance Era era => NoUnexpectedThunks (LastAppliedBlock era)

instance NFData (LastAppliedBlock era)

instance Era era => ToCBOR (LastAppliedBlock era) where
  toCBOR (LastAppliedBlock b s h) =
    encodeListLen 3 <> toCBOR b <> toCBOR s <> toCBOR h

instance Era era => FromCBOR (LastAppliedBlock era) where
  fromCBOR =
    decodeRecordNamed
      "lastAppliedBlock"
      (const 3)
      ( LastAppliedBlock
          <$> fromCBOR
          <*> fromCBOR
          <*> fromCBOR
      )

lastAppliedHash :: WithOrigin (LastAppliedBlock era) -> PrevHash era
lastAppliedHash Origin = GenesisHash
lastAppliedHash (At lab) = BlockHash $ labHash lab

data BHBody era = BHBody
  { -- | block number
    bheaderBlockNo :: !BlockNo,
    -- | block slot
    bheaderSlotNo :: !SlotNo,
    -- | Hash of the previous block header
    bheaderPrev :: !(PrevHash era),
    -- | verification key of block issuer
    bheaderVk :: !(VKey 'BlockIssuer era),
    -- | VRF verification key for block issuer
    bheaderVrfVk :: !(VerKeyVRF era),
    -- | block nonce
    bheaderEta :: !(CertifiedVRF era Nonce),
    -- | leader election value
    bheaderL :: !(CertifiedVRF era Natural),
    -- | Size of the block body
    bsize :: !Natural,
    -- | Hash of block body
    bhash :: !(HashBBody era),
    -- | operational certificate
    bheaderOCert :: !(OCert era),
    -- | protocol version
    bprotver :: !ProtVer
  }
  deriving (Show, Eq, Generic)

instance
  Era era =>
  SignableRepresentation (BHBody era)
  where
  getSignableRepresentation = serialize'

instance
  Era era =>
  NoUnexpectedThunks (BHBody era)

instance
  Era era =>
  ToCBOR (BHBody era)
  where
  toCBOR bhBody =
    encodeListLen (9 + listLen oc + listLen pv)
      <> toCBOR (bheaderBlockNo bhBody)
      <> toCBOR (bheaderSlotNo bhBody)
      <> toCBOR (bheaderPrev bhBody)
      <> toCBOR (bheaderVk bhBody)
      <> encodeVerKeyVRF (bheaderVrfVk bhBody)
      <> toCBOR (bheaderEta bhBody)
      <> toCBOR (bheaderL bhBody)
      <> toCBOR (bsize bhBody)
      <> toCBOR (bhash bhBody)
      <> toCBORGroup oc
      <> toCBORGroup pv
    where
      oc = bheaderOCert bhBody
      pv = bprotver bhBody

  encodedSizeExpr size proxy =
    fromInteger (withWordSize $ 9 + listLenBound oc + listLenBound pv)
      + encodedSizeExpr size (bheaderBlockNo <$> proxy)
      + encodedSizeExpr size (bheaderSlotNo <$> proxy)
      + encodedSizeExpr size (bheaderPrev <$> proxy)
      + encodedSizeExpr size (bheaderVk <$> proxy)
      + VRF.encodedVerKeyVRFSizeExpr (bheaderVrfVk <$> proxy)
      + encodedSizeExpr size (bheaderEta <$> proxy)
      + encodedSizeExpr size (bheaderL <$> proxy)
      + encodedSizeExpr size ((toWord64 . bsize) <$> proxy)
      + encodedSizeExpr size (bhash <$> proxy)
      + encodedSizeExpr size (bheaderOCert <$> proxy)
      + encodedSizeExpr size (bprotver <$> proxy)
    where
      oc = bheaderOCert <$> proxy
      pv = bprotver <$> proxy
      toWord64 :: Natural -> Word64
      toWord64 = fromIntegral

instance
  Era era =>
  FromCBOR (BHBody era)
  where
  fromCBOR = decodeRecordNamed "BHBody" bhBodySize $ do
    bheaderBlockNo <- fromCBOR
    bheaderSlotNo <- fromCBOR
    bheaderPrev <- fromCBOR
    bheaderVk <- fromCBOR
    bheaderVrfVk <- decodeVerKeyVRF
    bheaderEta <- fromCBOR
    bheaderL <- fromCBOR
    bsize <- fromCBOR
    bhash <- fromCBOR
    bheaderOCert <- fromCBORGroup
    bprotver <- fromCBORGroup
    pure $
      BHBody
        { bheaderBlockNo,
          bheaderSlotNo,
          bheaderPrev,
          bheaderVk,
          bheaderVrfVk,
          bheaderEta,
          bheaderL,
          bsize,
          bhash,
          bheaderOCert,
          bprotver
        }
    where
      bhBodySize body = 9 + listLenInt (bheaderOCert body) + listLenInt (bprotver body)

-- | Retrieve the pool id (the hash of the pool operator's cold key)
-- from the body of the block header.
poolIDfromBHBody :: Era era => BHBody era -> KeyHash 'BlockIssuer era
poolIDfromBHBody = hashKey . bheaderVk
{-# DEPRECATED poolIDfromBHBody "poolIDfromBHBody has been deprecated (the name is misleading), use issuerIDfromBHBody" #-}

-- | Retrieve the issuer id (the hash of the cold key) from the body of the block header.
-- This corresponds to either a genesis/core node or a stake pool.
issuerIDfromBHBody :: Era era => BHBody era -> KeyHash 'BlockIssuer era
issuerIDfromBHBody = hashKey . bheaderVk

-- | Retrieve the new nonce from the block header body.
bnonce :: BHBody era -> Nonce
bnonce = mkNonceFromOutputVRF . VRF.certifiedOutput . bheaderEta

data Block era
  = Block' !(BHeader era) !(TxSeq era) LByteString
  deriving (Eq, Show)

pattern Block :: Era era => BHeader era -> TxSeq era -> Block era
pattern Block h txns <-
  Block' h txns _
  where
    Block h txns =
      let bytes =
            serializeEncoding $
              encodeListLen (1 + listLen txns) <> toCBOR h <> toCBORGroup txns
       in Block' h txns bytes

{-# COMPLETE Block #-}

-- | Given a size and a mapping from indices to maybe metadata,
--  return a sequence whose size is the size paramater and
--  whose non-Nothing values correspond no the values in the mapping.
constructMetaData :: Int -> Map Int a -> Seq (Maybe a)
constructMetaData n md = fmap (`Map.lookup` md) (Seq.fromList [0 .. n -1])

instance
  Era era =>
  ToCBOR (Block era)
  where
  toCBOR (Block' _ _ blockBytes) = encodePreEncoded $ BSL.toStrict blockBytes

blockDecoder :: Era era => Bool -> forall s. Decoder s (Annotator (Block era))
blockDecoder lax = annotatorSlice $
  decodeRecordNamed "Block" (const 4) $ do
    header <- fromCBOR
    txns <- txSeqDecoder lax
    pure $ Block' <$> header <*> txns

txSeqDecoder :: Era era => Bool -> forall s. Decoder s (Annotator (TxSeq era))
txSeqDecoder lax = do
  (bodies, bodiesAnn) <- withSlice $ decodeSeq fromCBOR
  (wits, witsAnn) <- withSlice $ decodeSeq decodeWits
  let b = length bodies
      w = length wits

  (metadata, metadataAnn) <-
    withSlice $
      constructMetaData b
        <$> decodeMap fromCBOR fromCBOR
  let m = length metadata

  unless
    (lax || b == w)
    ( fail $
        "different number of transaction bodies ("
          <> show b
          <> ") and witness sets ("
          <> show w
          <> ")"
    )
  unless
    (lax || b == m)
    ( fail $
        "mismatch between transaction bodies ("
          <> show b
          <> ") and metadata ("
          <> show w
          <> ")"
    )
  let txns = sequenceA $ StrictSeq.toStrict $ Seq.zipWith3 segwitTx bodies wits metadata
  pure $ TxSeq' <$> txns <*> bodiesAnn <*> witsAnn <*> metadataAnn

instance
  Era era =>
  FromCBOR (Annotator (Block era))
  where
  fromCBOR = blockDecoder False

newtype LaxBlock era
  = LaxBlock (Block era)
  deriving (Show, Eq)
  deriving (ToCBOR) via (Block era)

instance
  Era era =>
  FromCBOR (Annotator (LaxBlock era))
  where
  fromCBOR = fmap LaxBlock <$> blockDecoder True

bHeaderSize ::
  forall era.
  (Era era) =>
  BHeader era ->
  Int
bHeaderSize = BS.length . serialize'

bBodySize ::
  forall era.
  (Era era) =>
  TxSeq era ->
  Int
bBodySize = BS.length . serializeEncoding' . toCBORGroup

slotToNonce :: SlotNo -> Nonce
slotToNonce (SlotNo s) = mkNonceFromNumber s

bheader ::
  Era era =>
  Block era ->
  BHeader era
bheader (Block bh _) = bh

bbody :: Era era => Block era -> TxSeq era
bbody (Block _ txs) = txs

bhbody ::
  Era era =>
  BHeader era ->
  BHBody era
bhbody (BHeader b _) = b

-- | Construct a seed to use in the VRF computation.
mkSeed ::
  -- | Universal constant
  Nonce ->
  SlotNo ->
  -- | Epoch nonce
  Nonce ->
  Seed
mkSeed ucNonce (SlotNo slot) eNonce =
  Seed
    . ( case ucNonce of
          NeutralNonce -> id
          Nonce h -> Hash.xor (Hash.castHash h)
      )
    . Hash.castHash
    . Hash.hashWith id
    . runByteBuilder (8 + 32)
    $ BS.word64BE slot
      <> ( case eNonce of
             NeutralNonce -> mempty
             Nonce h -> BS.byteStringCopy (Hash.hashToBytes h)
         )

-- | Check that the certified input natural is valid for being slot leader. This
-- means we check that
--
-- fromNat (certNat) < 1 - (1 - f)^σ
--
-- where fromNat creates an appropriate value in [0;1] from the certified
-- natural. The calculation is done using the following optimization:
--
-- let p = fromNat (certNat) and c = ln(1 - f)
--
-- then           p < 1 - (1 - f)^σ
-- <=>  1 / (1 - p) < exp(-σ * c)
--
-- this can be efficiently be computed by `taylorExpCmp` which returns `ABOVE`
-- in case the reference value `1 / (1 - p)` is above the exponential function
-- at `-σ * c`, `BELOW` if it is below or `MaxReached` if it couldn't
-- conclusively compute this within the given iteration bounds.
checkLeaderValue ::
  forall v.
  (VRF.VRFAlgorithm v) =>
  VRF.OutputVRF v ->
  Rational ->
  ActiveSlotCoeff ->
  Bool
checkLeaderValue certVRF σ f =
  if (intervalValue $ activeSlotVal f) == 1
    then -- If the active slot coefficient is equal to one,
    -- then nearly every stake pool can produce a block every slot.
    -- In this degenerate case, where ln (1-f) is not defined,
    -- we let the VRF leader check always succeed.
    -- This is a testing convenience, the active slot coefficient should not
    -- bet set above one half otherwise.
      True
    else case taylorExpCmp 3 recip_q x of
      ABOVE _ _ -> False
      BELOW _ _ -> True
      MaxReached _ -> False
  where
    certNatMax :: Natural
    certNatMax = (2 :: Natural) ^ (8 * VRF.sizeOutputVRF (Proxy @v))
    c, recip_q, x :: FixedPoint
    c = activeSlotLog f
    recip_q = fromRational (toInteger certNatMax % toInteger (certNatMax - certNat))
    x = (- fromRational σ * c)
    certNat :: Natural
    certNat = VRF.getOutputVRFNatural certVRF

seedEta :: Nonce
seedEta = mkNonceFromNumber 0

seedL :: Nonce
seedL = mkNonceFromNumber 1

hBbsize :: BHBody era -> Natural
hBbsize = bsize

incrBlocks ::
  Bool ->
  KeyHash 'StakePool era ->
  BlocksMade era ->
  BlocksMade era
incrBlocks isOverlay hk b'@(BlocksMade b)
  | isOverlay = b'
  | otherwise = BlocksMade $ case hkVal of
    Nothing -> Map.insert hk 1 b
    Just n -> Map.insert hk (n + 1) b
  where
    hkVal = Map.lookup hk b
