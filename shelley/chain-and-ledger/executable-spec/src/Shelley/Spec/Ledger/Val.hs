{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module defines a generalised notion of a "value" - that is, something
-- with which we may quantify a transaction output.
--
-- This module is intended for qualified import:
-- > import qualified Shelley.Spec.Ledger.Val as Val
module Shelley.Spec.Ledger.Val
  ( Val (..),

    -- * Re-exports
    Data.Group.invert,
    (Data.PartialOrd.<=),
    (Data.PartialOrd.>=),
    (Data.PartialOrd.==),
    (Data.PartialOrd./=),
    (Data.PartialOrd.>),
    (Data.PartialOrd.<),
    Data.PartialOrd.compare,
  )
where

import Cardano.Prelude (NFData (), NoUnexpectedThunks (..))
import Data.Group (Abelian)
import qualified Data.Group
import Data.PartialOrd hiding ((==))
import qualified Data.PartialOrd
import Data.Typeable (Typeable)
import Shelley.Spec.Ledger.Coin (Coin (..))

class
  ( Abelian t,
    Eq t,
    PartialOrd t,
    -- Do we really need these?
    Show t,
    Typeable t,
    NFData t,
    NoUnexpectedThunks t
  ) =>
  Val t
  where
  -- | TODO This needs documenting. what is it?
  scalev :: Integer -> t -> t

  -- | Is the argument zero?
  isZero :: t -> Bool
  isZero t = t == mempty

  coin :: t -> Coin -- get the Coin amount
  inject :: Coin -> t -- inject Coin into the Val instance
  size :: t -> Integer -- compute size of Val instance
  -- TODO add PACK/UNPACK stuff to this class

instance Val Coin where
  scalev n (Coin x) = Coin $ n * x
  coin = id
  inject = id
  size _ = 1
