{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}


module Shelley.Spec.Ledger.Tx
  ( -- transaction
    Tx(Tx
      , _body
      , _witnessVKeySet
      , _witnessMSigMap
      , _metadata
      , txBodyBytes
      , txWitsBytes
      , txMetadataBytes
      )
  , TxBody(..)
  , TxOut(..)
  , TxIn(..)
  , TxId(..)
  , Wits(..)
  , decodeWits
  , segwitTx
  , txUpdate
  , inputs
  , outputs
  , certs
  , wdrls
  , txfee
  , ttl
  , body
  , metadata
  , txwits
    -- witness data
  , WitVKey(..)
  , MultiSignatureScript
  , ShelleyOrGoguenTx
  , validateScript
  , hashScript
  , txwitsScript
  , extractKeyHash
  , extractScriptHash
  , extractGenKeyHash
  , getKeyCombinations
  , getKeyCombination
  )
where


import           Shelley.Spec.Ledger.BaseTypes (StrictMaybe, invalidKey, maybeToStrictMaybe, strictMaybeToMaybe,
                 Hash, hash)
import           Shelley.Spec.Ledger.Keys (AnyKeyHash, GenKeyHash, undiscriminateKeyHash)

import           Cardano.Binary (Annotator (..), Decoder, FromCBOR (fromCBOR), ToCBOR (toCBOR),
                     annotatorSlice, decodeWord, encodeListLen, encodeMapLen, encodePreEncoded,
                     encodeWord, serialize, serializeEncoding, withSlice, decodeListLenOf, encodeWord)
import           Cardano.Prelude (AllowThunksIn (..), LByteString, NoUnexpectedThunks (..),
                     catMaybes)
import qualified Data.ByteString.Lazy as BSL
import           Data.Foldable (fold)
import           Data.Map.Strict (Map)
                     encodeListLen, encodeWord, encodeMapLen, decodeListLenOf)
import           Cardano.Crypto.Hash (hashWithSerialiser)
import           Shelley.Spec.Ledger.Crypto
import           Cardano.Prelude (NoUnexpectedThunks (..))
import           Data.Map.Strict (Map, insert, empty)
import qualified Data.Map.Strict as Map
import           Data.Maybe (mapMaybe)
import           Data.Set (Set)
import qualified Data.Set as Set
import           GHC.Generics (Generic)
import           Shelley.Spec.Ledger.Crypto
import           Shelley.Spec.Ledger.MetaData (MetaData)
import           Shelley.Spec.Ledger.Scripts
import           Shelley.Spec.Ledger.Serialization (decodeList, decodeMapContents, decodeMaybe,
                     decodeRecordNamed, encodeFoldable)
import           Shelley.Spec.Ledger.TxData (Credential (..), TxBody (..),
                     TxId (..), TxIn (..), TxOut (..), WitVKey (..), TxWitness (..), certs, inputs,
                     outputs, ttl, txUpdate, txfee, wdrls, witKeyHash)

-- |A fully formed transaction.
data Tx crypto
  = Tx
      { _body           :: !(TxBody crypto)
      , _txwits         :: TxWitness crypto
      , _metadata       :: Maybe MetaData
      , _valtag         :: IsValidating

-- |A fully formed transaction.
data Tx crypto
  = Tx'
      { _body'           :: !(TxBody crypto)
      , _witnessVKeySet' :: !(Set (WitVKey crypto))
      , _witnessMSigMap' :: !(Map (ScriptHash crypto) (MultiSig crypto))
      , _metadata'       :: !(StrictMaybe MetaData)
      , txBodyBytes      :: LByteString
      , txWitsBytes      :: LByteString
      , txMetadataBytes  :: !(Maybe LByteString)
      , txFullBytes      :: LByteString
      } deriving (Show, Eq, Generic)
        deriving NoUnexpectedThunks via
          AllowThunksIn
            '["txBodyBytes"
            , "txWitsBytes"
            , "txMetadataBytes"
            , "txFullBytes"
            ] (Tx crypto)

pattern Tx :: Crypto crypto
  => TxBody crypto
  -> Set (WitVKey crypto)
  -> Map (ScriptHash crypto) (MultiSig crypto)
  -> StrictMaybe MetaData
  -> Tx crypto
pattern Tx { _body, _witnessVKeySet, _witnessMSigMap, _metadata } <-
  Tx' _body _witnessVKeySet _witnessMSigMap _metadata _ _ _ _
  where
  Tx body witnessVKeySet witnessMSigMap metadata =
    let encodeMapElement ix enc x =
          if null x then Nothing else Just (encodeWord ix <> enc x)
        l = catMaybes $
              [ encodeMapElement 0 encodeFoldable witnessVKeySet
              , encodeMapElement 1 encodeFoldable witnessMSigMap
              ]
        n = fromIntegral $ length l
        bodyBytes = serialize body
        witsBytes = serializeEncoding $ encodeMapLen n <> fold l
        metadataBytes = serialize <$> (strictMaybeToMaybe metadata)
        wrappedMetadataBytes = serialize metadata
        fullBytes = (serializeEncoding $ encodeListLen 3)
          <> bodyBytes <> witsBytes <> wrappedMetadataBytes
     in Tx'
        { _body'           = body
        , _witnessVKeySet' = witnessVKeySet
        , _witnessMSigMap' = witnessMSigMap
        , _metadata'       = metadata
        , txBodyBytes      = bodyBytes
        , txWitsBytes      = witsBytes
        , txMetadataBytes  = metadataBytes
        , txFullBytes      = fullBytes
        }

{-# COMPLETE Tx #-}

segwitTx
  :: (TxBody crypto, Annotator LByteString)
  -> (Wits crypto, Annotator LByteString)
  -> Maybe (MetaData, Annotator LByteString)
  -> Annotator (Tx crypto)
segwitTx
  (body, bodyAnn)
  (Wits witnessVKeySet witnessMSigMap, witsAnn)
  metadataPair
  = Annotator $ \bytes ->
      let bodyBytes = runAnnotator bodyAnn bytes
          witsBytes = runAnnotator witsAnn bytes
          (metadata, metadataBytes) = case metadataPair of
            Nothing -> (Nothing, Nothing)
            Just (m, mb) -> (Just m, Just $ runAnnotator mb bytes)
          wrappedMetadataBytes = case metadataBytes of
            Nothing -> serializeEncoding $ encodeListLen 0
            Just b -> (serializeEncoding $ encodeListLen 1) <> b
          fullBytes = (serializeEncoding $ encodeListLen 3)
            <> bodyBytes <> witsBytes <> wrappedMetadataBytes
       in Tx'
          { _body'           = body
          , _witnessVKeySet' = witnessVKeySet
          , _witnessMSigMap' = witnessMSigMap
          , _metadata'       = maybeToStrictMaybe metadata
          , txBodyBytes      = bodyBytes
          , txWitsBytes      = witsBytes
          , txMetadataBytes  = metadataBytes
          , txFullBytes      = fullBytes
          }

data Wits crypto = Wits
  (Set (WitVKey crypto))
  (Map (ScriptHash crypto) (MultiSig crypto))

decodeWits :: Crypto crypto => Decoder s (Wits crypto)
decodeWits = do
  mapParts <- decodeMapContents $
    decodeWord >>= \case
      0 -> decodeList fromCBOR >>= \x -> pure (\(_,b) -> (x,b))
      1 -> decodeList fromCBOR >>= \x -> pure (\(a,_) -> (a,x))
      k -> invalidKey k
  let (witsVKeys, witsScripts) = foldr ($) ([], []) mapParts
  pure $ Wits (Set.fromList witsVKeys) (keyBy hashScript witsScripts)

keyBy :: Ord k => (a -> k) -> [a] -> Map k a
keyBy f xs = Map.fromList $ (\x -> (f x, x)) <$> xs

instance
  (Crypto crypto)
  => ToCBOR (Tx crypto)
 where
  toCBOR tx = encodePreEncoded . BSL.toStrict $ txFullBytes tx

instance Crypto crypto => FromCBOR (Annotator (Tx crypto)) where
  fromCBOR = annotatorSlice $ decodeRecordNamed "Tx" (const 3) $ do
    (body, bodyAnn) <- withSlice fromCBOR
    (Wits witsVKeys witsScripts, witsAnn) <- withSlice decodeWits
    (meta, metaAnn) <- do
      result <- decodeMaybe (withSlice fromCBOR)
      pure $ case result of
        Nothing -> (Nothing, pure Nothing)
        Just (a,b) -> (Just a, Just <$> b)
    pure $
      Tx' <$> pure body
          <*> pure witsVKeys
          <*> pure witsScripts
          <*> pure (maybeToStrictMaybe meta)
          <*> bodyAnn
          <*> witsAnn
          <*> metaAnn

--   toCBOR tx =
--     encodeListLen 4
--       <> toCBOR (_body tx)
--       <> toCBOR (_txwits tx)
--       <> toCBOR (_metadata tx)
--       <> toCBOR (_valtag tx)
--
-- instance Crypto crypto => FromCBOR (Tx crypto) where
--   fromCBOR = do
--        enforceSize "Tx" 4
--        bod <- fromCBOR
--        wts <- fromCBOR
--        md <- fromCBOR
--        vt <- fromCBOR
--        pure $ Tx bod wts md vt

-- | Typeclass for multis-signature script data types. Allows for script
-- validation and hashing.
class (Crypto crypto, ToCBOR a) =>
  MultiSignatureScript a crypto where
  validateScript :: a -> Tx crypto -> Bool
  hashScript :: a -> ScriptHash crypto

-- | instance of MultiSignatureScript type class
instance Crypto crypto =>
  MultiSignatureScript (MultiSig crypto) crypto where
  validateScript = validateNativeMultiSigScript
  hashScript = \x -> hashAnyScript (MultiSigScript x)

-- | Script evaluator for native multi-signature scheme. 'vhks' is the set of
-- key hashes that signed the transaction to be validated.
evalNativeMultiSigScript
  :: MultiSig crypto
  -> Set (AnyKeyHash crypto)
  -> Bool
evalNativeMultiSigScript (RequireSignature hk) vhks = Set.member hk vhks
evalNativeMultiSigScript (RequireAllOf msigs) vhks =
  all (`evalNativeMultiSigScript` vhks) msigs
evalNativeMultiSigScript (RequireAnyOf msigs) vhks =
  any (`evalNativeMultiSigScript` vhks) msigs
evalNativeMultiSigScript (RequireMOf m msigs) vhks =
  m <= sum [if evalNativeMultiSigScript msig vhks then 1 else 0 | msig <- msigs]

-- | Script validator for native multi-signature scheme.
validateNativeMultiSigScript
  :: (Crypto crypto)
  => MultiSig crypto
  -> Tx crypto
  -> Bool
validateNativeMultiSigScript msig tx =
  evalNativeMultiSigScript msig vhks
  where witsSet = _witnessVKeySet $ _txwits tx
        vhks    = Set.map witKeyHash witsSet



-- | script witness accessor function for Transactions
txwitsScript
  :: Crypto crypto
  => Tx crypto
  -> Map (ScriptHash crypto) (Script crypto)
txwitsScript tx = Set.foldl (\m a -> Map.insert (ScriptHash $ hash a) a m) Map.empty (_scripts $ _txwits tx)

extractKeyHash
  :: [Credential crypto]
  -> [AnyKeyHash crypto]
extractKeyHash =
  mapMaybe (\case
                KeyHashObj hk -> Just $ undiscriminateKeyHash hk
                _ -> Nothing)

extractScriptHash
  :: [Credential crypto]
  -> [ScriptHash crypto]
extractScriptHash =
  mapMaybe (\case
                ScriptHashObj hk -> Just hk
                _ -> Nothing)

extractGenKeyHash
  :: [GenKeyHash crypto]
  -> [AnyKeyHash crypto]
extractGenKeyHash = map undiscriminateKeyHash
