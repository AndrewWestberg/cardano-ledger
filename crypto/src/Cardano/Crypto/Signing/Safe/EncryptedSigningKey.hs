{-# LANGUAGE DerivingVia          #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Crypto.Signing.Safe.EncryptedSigningKey
  ( EncryptedSigningKey(..)
  , mkEncSecretUnsafe
  , mkEncSecretWithSaltUnsafe
  , encToSigning
  , encToVerification
  , noPassEncrypt
  )
where

import Cardano.Prelude

import qualified Cardano.Crypto.Wallet as CC
import Crypto.Random (MonadRandom)
import Data.Default (Default(..))
import Formatting.Buildable (Buildable(..))
import qualified Prelude

import Cardano.Binary (FromCBOR(..), ToCBOR(..), encodeListLen, enforceSize)
import qualified Cardano.Crypto.Scrypt as S
import Cardano.Crypto.Signing.VerificationKey (VerificationKey(..))
import Cardano.Crypto.Signing.Safe.PassPhrase (PassPhrase, emptyPassphrase)
import Cardano.Crypto.Signing.SigningKey
  (SigningKey(..), fromCBORXPrv, toCBORXPrv, toVerification)


-- | Encrypted HD signing key
data EncryptedSigningKey = EncryptedSigningKey
  { eskPayload :: !CC.XPrv
  -- ^ Secret key itself, encrypted with passphrase.
  , eskHash    :: !S.EncryptedPass
  -- ^ Hash of passphrase used for key creation.
  }
  deriving NoUnexpectedThunks via UseIsNormalForm EncryptedSigningKey

-- We don't have the @Eq CC.XPrv@ instance here because
-- it is a security issue to compare signing keys. But it
-- can be derived in tests where it doesn't matter.
deriving instance Eq CC.XPrv => Eq EncryptedSigningKey

instance Show EncryptedSigningKey where
  show _ = "<encrypted key>"

instance Buildable EncryptedSigningKey where
  build _ = "<encrypted key>"

instance ToCBOR EncryptedSigningKey where
  toCBOR (EncryptedSigningKey sk pph) =
    encodeListLen 2 <> toCBORXPrv sk <> toCBOR pph

instance FromCBOR EncryptedSigningKey where
  fromCBOR =
    EncryptedSigningKey
      <$  enforceSize "EncryptedSigningKey" 2
      <*> fromCBORXPrv
      <*> fromCBOR

-- | Parameters used to evaluate hash of passphrase.
passScryptParam :: S.ScryptParams
passScryptParam = fromMaybe (panic "Bad passphrase scrypt parameters")
  $ S.mkScryptParams def { S.spHashLen = 32 }  -- maximal passphrase length

-- | Wrap raw signing key, attaching hash to it
--
--   Hash is evaluated using given salt.
--   This function assumes that passphrase matches with signing key.
mkEncSecretWithSaltUnsafe
  :: S.Salt -> PassPhrase -> CC.XPrv -> EncryptedSigningKey
mkEncSecretWithSaltUnsafe salt pp payload =
  EncryptedSigningKey payload $ S.encryptPassWithSalt passScryptParam salt pp

-- | Wrap raw signing key, attachind hash to it.
--   Hash is evaluated using generated salt.
--   This function assumes that passphrase matches with signing key.
mkEncSecretUnsafe
  :: (MonadRandom m) => PassPhrase -> CC.XPrv -> m EncryptedSigningKey
mkEncSecretUnsafe pp payload =
  EncryptedSigningKey payload <$> S.encryptPass passScryptParam pp

-- | Generate a signing key from encrypted signing key.
encToSigning :: EncryptedSigningKey -> SigningKey
encToSigning (EncryptedSigningKey sk _) = SigningKey sk

-- | Generate a verification key using an encrypted signing key and passphrase
encToVerification :: EncryptedSigningKey -> VerificationKey
encToVerification = toVerification . encToSigning

-- | Re-wrap unencrypted signing key as an encrypted one.
--
--   Note: for testing purposes only
--
noPassEncrypt :: SigningKey -> EncryptedSigningKey
noPassEncrypt (SigningKey k) =
  EncryptedSigningKey k emptyEncryptedPass

-- | Only for testing. Only used when wrapping unencrypted signing keys as
-- encrypted ones.
--
-- We cache the empty EncryptedPass as a top level CAF here because generating
-- them is very expensive (using scrypt) and in testing we sometimes need to
-- generate a lot of them.
--
emptyEncryptedPass :: S.EncryptedPass
emptyEncryptedPass =
  S.encryptPassWithSalt passScryptParam S.emptySalt emptyPassphrase
