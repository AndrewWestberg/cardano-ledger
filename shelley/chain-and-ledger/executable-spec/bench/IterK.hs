{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# OPTIONS_GHC -Wno-orphans #-}

{-# LANGUAGE FlexibleContexts, FlexibleInstances, FunctionalDependencies  #-}
{-# LANGUAGE GADTs, MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators, DataKinds,  KindSignatures #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies, TypeFamilyDependencies  #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Iteration with Continuations

module IterK where

import Prelude hiding (lookup)
-- import Debug.Trace

import Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map

import qualified Data.Set as Set

import Data.List(sortBy)

import Collect
import SetAlgebra(Iter(..),
                  -- And(..),Or(..),Project(..),Guard(..),Diff(..),Single(..),Sett(..),AndP(..),List(..),Chain(..),
                  Exp(..),BaseRep(..),List(..),Sett(..),Single(..),
                  dom, range, singleton, setSingleton, (◁), (⋪), (▷), (⋫), (∪), (⨃), (∈), (∉),(|>),(<|),
                  element, lifo, fifo, noKeys,
                  SymFun(..), Fun, fun, SymFun, apply,
                  BiMap(..), Bimap, biMapFromList, biMapEmpty, removeval,
                  Fun(..), Basic(..)
                 )

import Text.PrettyPrint.ANSI.Leijen(Doc,text,(<+>),align,vsep,parens)



-- ============================================================================================
-- | Given a BaseRep we can materialize a (Collect k v) which has no intrinsic type.
-- =============================================================================================

materialize :: (Ord k) => BaseRep f k v -> Collect (k,v) -> f k v
materialize ListR x = List (runCollect x [] (:))
materialize MapR x = runCollect x Map.empty (\ (k,v) ans -> Map.insert k v ans)
materialize SetR x = Sett (runCollect x Set.empty (\ (k,_) ans -> Set.insert k ans))
materialize BiMapR x = runCollect x  biMapEmpty (\ (k,v) ans -> addpair k v ans)
materialize SingleR x = runCollect x Fail (\ (k,v) _ignore -> Single k v)
-- materialize other x = error ("Can't materialize compound (Iter f) type: "++show other++". Choose some other BaseRep.")


-- =============================================================================
-- Another way to build any (f k v) given (Iter f) is to import it from a list.
-- =============================================================================

addp :: (Ord k,Basic f) => (k,v) -> f k v -> f k v
addp (k,v) xs = addpair k v xs

fromList:: Ord k => BaseRep f k v -> [(k,v)] -> f k v
fromList MapR xs = foldr addp Map.empty xs
fromList ListR xs = List (sortBy (\ x y -> compare (fst x) (fst y)) xs)
fromList SetR xs = foldr addp (Sett (Set.empty)) xs
fromList BiMapR xs = biMapFromList xs
fromList SingleR xs = foldr addp Fail xs
-- fromList other xs = error ("No fromList for compound iterators")


-- =========================================================================================
-- Now we make an iterator that collects triples, on the intersection
-- of the domain of the two Iter types 'f' and 'g'. An answer of (k,b,c) means that
-- (k,b) is in m::f k a, and (k,c) is in n::g k c. All the other possible triples
-- are skipped over.  This is an instance of a thing called a "Generic Join"
-- See https://arxiv.org/pdf/1310.3314.pdf  or  http://personales.dcc.uchile.cl/~pbarcelo/ngo.pdf
-- The number of tuples it touches is proportional to the size of the output (modulo log factors).
-- It's cost is unrelated to the size of its inputs (modulo log factors)
-- This is a specific version of the AndD compound iterator. t is used in the function 'eval'
-- =========================================================================================

(⨝) ::  (Ord k,Iter f,Iter g) =>  f k b -> g k c -> Collect (k,b,c)
(⨝) = domEq

domEq:: (Ord k,Iter f,Iter g) =>  f k b -> g k c -> Collect (k,b,c)
domEq m n = do
    triplem <- nxt m
    triplen <- nxt n
    let loop (mt@(k1,b,nextm)) (nt@(k2,c,nextn)) =
          case compare k1 k2 of
            EQ -> front (k1,b,c) (domEq nextm nextn)
            LT -> do { mt' <- lub k2 nextm; loop mt' nt }
            GT -> do { nt' <- lub k1 nextn; loop mt nt' }
    loop triplem triplen

-- This is included here for the benchmark tests. It is much slower because it does not use lub.

domEqSlow:: (Ord k,Iter f, Iter g) =>  f k b -> g k c -> Collect (k,b,c)
domEqSlow m n = do
    triplem <- nxt m
    triplen <- nxt n
    let loop (mt@(k1,b,nextm)) (nt@(k2,c,nextn)) =
          case compare k1 k2 of
            EQ -> front (k1,b,c) (domEqSlow nextm nextn)
            LT -> do { mt' <- nxt nextm; loop mt' nt }
            GT -> do { nt' <- nxt nextn; loop mt nt' }
    loop triplem triplen


-- =================================================================================
-- Dat is a single datatype that incorporates compound iterators
-- =================================================================================

data Dat k v where
   BaseD :: (Iter f,Ord k) => BaseRep f k v -> f k v -> Dat k v
   ProjectD :: Ord k => Dat k v -> Fun (k -> v -> u) -> Dat k u
   AndD :: Ord k => Dat k v -> Dat k w -> Dat k (v,w)
   ChainD:: (Ord k,Ord v) => Dat k v -> Dat v w -> Fun(k -> (v,w) -> u) -> Dat k u
   AndPD::  Ord k => Dat k v -> Dat k u -> Fun(k -> (v,u) -> w) -> Dat k w
   OrD:: Ord k => Dat k v -> Dat k v -> Fun(v -> v -> v) -> Dat k v
   GuardD:: Ord k => Dat k v -> Fun (k -> v -> Bool) -> Dat k v
   DiffD :: Ord k => Dat k v -> Dat k u -> Dat k v

-- ======================================================================================
-- smart constructors for Dat. These apply semantic preserving rewrites when applicable
-- ======================================================================================

smart :: Bool
smart = True

projD ::  Ord k => Dat k v -> Fun (k -> v -> u) -> Dat k u
projD x y = case (x,y) of
   (ProjectD f (Fun p _), Fun q _) | smart -> projD f (fun (Comp q p))
   (AndD f g, Fun q _) | smart -> andPD f g (fun (Comp q YY))
   (AndPD f g (Fun p _), Fun q _) | smart -> andPD f g (fun (Comp q p))
   (f, p) -> ProjectD f p

andD :: Ord k => Dat k v1 -> Dat k v2 -> Dat k (v1, v2)
andD (ProjectD f (Fun p _)) g | smart = AndPD f g (fun(CompSndL YY p))
andD f (ProjectD g (Fun p _)) | smart = AndPD f g (fun(CompSndR YY p))
andD f g = AndD f g

andPD :: Ord k => Dat k v1 -> Dat k u -> Fun (k -> (v1, u) -> v) -> Dat k v
andPD (ProjectD f (Fun p _)) g (Fun q _) | smart = andPD f g (fun(CompSndL q p))
andPD f g p = AndPD f g p

chainD :: (Ord k,Ord v) => Dat k v -> Dat v w -> Fun (k -> (v, w) -> u) -> Dat k u
chainD f (ProjectD g (Fun p _)) (Fun q _) | smart = chainD f g (fun(CompCurryR q p))
chainD f g p = ChainD f g p


-- ================================================================================
-- | Compile the (Exp (f k v)) to a Dat iterator, and a BaseRep that indicates
--   how to materialize the iterator to the correct type. Recall the iterator
--   can be used to constuct many things using runCollect, but here we want
--   to materialize it to the same type as the (Exp (f k v)), i.e. (f k v).
-- ================================================================================

compile:: Exp (f k v) -> (Dat k v,BaseRep f k v)
compile (Base rep relation) = (BaseD rep relation,rep)
compile (Singleton d r) = (BaseD SingleR (Single d r),SingleR)
compile (SetSingleton d  ) = (BaseD SingleR (SetSingle d  ),SingleR)
compile (Dom (Base SetR rel)) = (BaseD SetR rel,SetR)
compile (Dom (Singleton k v)) = (BaseD SetR (Sett(Set.singleton k)),SetR)
compile (Dom (SetSingleton k)) = (BaseD SetR (Sett(Set.singleton k)),SetR)
compile (Dom x) = (projD (fst(compile x)) (fun (Const ())),SetR)
compile (Rng (Base SetR rel))  = (BaseD SetR (Sett(Set.singleton ())),SetR)
compile (Rng (Singleton k v))  = (BaseD SetR (Sett(Set.singleton v)),SetR)
compile (Rng (SetSingleton k)) = (BaseD SetR (Sett(Set.singleton ())),SetR)
compile (Rng f) = (BaseD SetR (rngStep (fst(compile f))),SetR)  -- We really ought to memoize this. It might be computed many times.
compile (DRestrict set rel) = (projD (andD (fst(compile set)) reld) (fun (RngSnd)),rep)
    where (reld,rep) = compile rel
compile (DExclude set rel) = (DiffD reld (fst(compile set)),rep)
       where (reld,rep) = compile rel
compile (RRestrict rel set) =
   case (compile rel,compile set) of
      ((reld,rep),(BaseD _ x,_)) -> (GuardD reld (fun (RngElem x)),rep)
      ((reld,rep),(setd,_)) -> (chainD reld setd (fun RngFst),rep)
compile (RExclude rel set) =
   case (compile rel,compile set) of
      ((reld,rep),(BaseD _ x,_)) -> (GuardD reld (fun (Negate(RngElem x))),rep)
      ((reld,rep),_) -> (GuardD reld (fun (Negate(RngElem (eval set)))),rep)  -- This could be expensive
compile (UnionLeft rel1 rel2) =  (OrD rel1d (fst(compile rel2)) (fun YY),rep)
    where (rel1d,rep) = compile rel1
compile (UnionRight rel1 rel2) =  (OrD rel1d (fst(compile rel2)) (fun XX),rep)
    where (rel1d,rep) = compile rel1
compile (UnionPlus rel1 rel2) =  (OrD rel1d (fst(compile rel2)) (fun Plus),rep)
    where (rel1d,rep) = compile rel1

-- ===========================================================================
-- run materializes compiled code, only if it is not already data
-- ===========================================================================

run :: Ord k => (Dat k v,BaseRep f k v) -> f k v
run (BaseD SetR x,SetR) = x               -- If it is already data (BaseD)
run (BaseD MapR x,MapR) = x               -- and in the right form (the BaseRep's match)
run (BaseD SingleR x,SingleR) = x         -- just return the data
run (BaseD BiMapR x,BiMapR) = x           -- only need to materialize data
run (BaseD ListR x,ListR) = x             -- if the forms do not match.
run (BaseD source x,target) = materialize target (lifo x)
run (other,target) = materialize target (lifo other)           -- If it is a compund Iterator, than materialize it.


-- ==============================================================================================
-- Evaluate an (Exp t) into real data of type t. Try domain and type specific algorithms first,
-- and if those fail. Compile the formula as an iterator, then run the iterator to get an answer.
-- Here are some sample of the type specific algorithms we incorporate
--  x  ∈ (dom y)            haskey
--  x  ∉ (dom y)            not . haskey
-- x ∪ (singleton y)        addpair
-- (Set.singleton x) ⋪ y    removekey
-- x ⋫ (Set.singleton y)    easy on Bimap  remove val
-- (dom x) ⊆ (dom y)
-- ===============================================================================================

eval:: Exp t -> t
eval (Base rep relation) = relation

eval (Dom (Base SetR rel)) = rel
eval (Dom (Singleton k v)) = Sett (Set.singleton k)
eval (Dom (SetSingleton k)) = Sett (Set.singleton k)
eval (e@(Dom _)) = run(compile e)

eval (Rng (Base SetR rel)) = Sett (Set.singleton ())
eval (Rng (Singleton k v)) = Sett (Set.singleton v)
eval (Rng (SetSingleton k)) = Sett (Set.singleton ())
eval (e@(Rng _ )) = run(compile e)


eval (DRestrict (Base SetR (Sett set)) (Base MapR m)) = Map.restrictKeys m set
eval (DRestrict (Base SetR (Sett s1)) (Base SetR (Sett s2))) = Sett(Set.intersection s1 s2)
eval (DRestrict (Base SetR x1) (Base rep x2)) = materialize rep $ do { (x,y,z) <- x1 `domEq` x2; one (x,z) }
eval (DRestrict (Dom (Base _ x1)) (Base rep x2)) = materialize rep $ do { (x,y,z) <- x1 `domEq` x2; one (x,z) }
eval (DRestrict (SetSingleton k) (Base rep x2)) = materialize rep $  do { (x,y,z) <- (SetSingle k) `domEq` x2; one (x,z) }
eval (DRestrict (Dom (Singleton k _)) (Base rep x2)) = materialize rep $  do { (x,y,z) <- (SetSingle k) `domEq` x2; one (x,z) }
eval (DRestrict (Rng (Singleton _ v)) (Base rep x2)) = materialize rep $  do { (x,y,z) <- (SetSingle v) `domEq` x2; one (x,z) }
eval (e@(DRestrict _ _ )) = run(compile e)

eval (DExclude (SetSingleton n) (Base MapR m)) = Map.withoutKeys m (Set.singleton n)
eval (DExclude (Dom (Singleton n v)) (Base MapR m)) = Map.withoutKeys m (Set.singleton n)
eval (DExclude (Rng (Singleton n v)) (Base MapR m)) = Map.withoutKeys m (Set.singleton v)
eval (DExclude (Base SetR (Sett x1)) (Base MapR x2)) =  Map.withoutKeys x2 x1
eval (DExclude (Dom (Base MapR x1)) (Base MapR x2)) = noKeys x2 x1
eval (DExclude (SetSingleton k) (Base BiMapR x)) = removekey k x
eval (DExclude (Dom (Singleton k _)) (Base BiMapR x)) = removekey k x
eval (DExclude (Rng (Singleton _ v)) (Base BiMapR x)) = removekey v x
eval (e@(DExclude _ _ )) = run(compile e)

eval (RExclude (Base BiMapR x) (SetSingleton k)) = removeval k x
eval (RExclude (Base BiMapR x) (Dom (Singleton k v))) = removeval k x
eval (RExclude (Base BiMapR x) (Rng (Singleton k v))) = removeval v x
eval (RExclude (Base rep lhs) y) =
   materialize rep $ do { (a,b) <- lifo lhs; (c,_) <- lifo rhs; when (not(b==c)); one (a,b)} where rhs = eval y
eval (e@(RExclude _ _ )) = run(compile e)

eval (RRestrict (DRestrict (Dom (Base r1 stkcreds)) (Base r2 delegs)) (Dom (Base r3 stpools))) =
   materialize r2 $ do { (x,z,y) <- stkcreds `domEq` delegs; y `element` stpools; one (x,y)}
eval (e@(RRestrict _ _ )) = run(compile e)

eval (Elem k (Dom (Base rep x))) = haskey k x
eval (Elem k (Base rep rel)) = haskey k rel
eval (Elem k (Dom (Singleton key v))) = k==key
eval (Elem k (Rng (Singleton _ key))) = k==key
eval (Elem k (SetSingleton key)) = k==key
eval (Elem k set) = haskey k (eval set)

eval (NotElem k (Dom (Base rep x))) = not $ haskey k x
eval (NotElem k (Base rep rel)) = not $ haskey k rel
eval (NotElem k (Dom (Singleton key v))) = not $ k==key
eval (NotElem k (Rng (Singleton _ key))) = not $ k==key
eval (NotElem k (SetSingleton key)) = not $ k==key
eval (NotElem k set) = not $ haskey k (eval set)

eval (UnionLeft (Base rep x) (Singleton k v)) = addpair k v x
eval (e@(UnionLeft a b)) = run(compile e)

eval (UnionRight (Base rep x) (Singleton k v)) = addpair k v x   --TODO MIght not have the right parity
eval (e@(UnionRight a b)) = run(compile e)

eval (UnionPlus (Base MapR x) (Base MapR y)) = Map.unionWith (+) x y
eval (e@(UnionPlus a b)) = run(compile e)

eval (Singleton k v) = Single k v
eval (SetSingleton k) = (SetSingle k)

-- ==============================================================================================
-- To make compound iterators, i.e. instance (Iter Dat), we need "step" functions for each kind
-- ==============================================================================================

-- ==== Project ====
projStep
  :: Ord k =>
     (t -> Collect (k, v, Dat k v))
     -> Fun (k -> v -> u) -> t -> Collect (k, u, Dat k u)
projStep next p f = do { (k,v,f') <- next f; one (k,apply p k v,ProjectD f' p) }

-- ===== And = ====
andStep
  :: Ord a =>
     (a, b1, Dat a b1)
     -> (a, b2, Dat a b2) -> Collect (a, (b1, b2), Dat a (b1, b2))
andStep (ftrip@(k1,v1,f1)) (gtrip@(k2,v2,g2)) =
   case compare k1 k2 of
      EQ -> one (k1,(v1,v2), AndD f1 g2)
      LT -> do { ftrip' <- lubDat k2 f1; andStep ftrip' gtrip  }
      GT -> do { gtrip' <- lubDat k1 g2; andStep ftrip gtrip' }

-- ==== Chain ====
chainStep
  :: (Ord b, Ord a) =>
     (a, b, Dat a b)
     -> Dat b w -> Fun (a -> (b, w) -> u) -> Collect (a, u, Dat a u)
chainStep (f@(d,r1,f1)) g comb = do
   (r2,w,g1) <- lubDat r1 g
   case compare r1 r2 of
      EQ -> one (d,apply comb d (r2,w),ChainD f1 g comb)
      LT -> do { trip <- nxtDat f1; chainStep trip g comb}
      GT -> error ("lub makes this unreachable")

-- ==== And with Projection ====
andPstep
  :: Ord a =>
     (a, b1, Dat a b1)
     -> (a, b2, Dat a b2)
     -> Fun (a -> (b1, b2) -> w)
     -> Collect (a, w, Dat a w)
andPstep (ftrip@(k1,v1,f1)) (gtrip@(k2,v2,g2)) p =
   case compare k1 k2 of
      EQ -> one (k1,(apply p k1 (v1,v2)), AndPD f1 g2 p)
      LT -> do { ftrip' <- lubDat k2 f1; andPstep ftrip' gtrip p }
      GT -> do { gtrip' <- lubDat k1 g2; andPstep ftrip gtrip' p }

-- ==== Or with combine ====
orStep
  :: (Ord k, Ord a) =>
     (Dat k v -> Collect (a, v, Dat k v))
     -> Dat k v
     -> Dat k v
     -> Fun (v -> v -> v)
     -> Collect (a, v, Dat k v)
orStep next f g comb =
   case (hasElem (next f), hasElem (next g)) of   -- We have to be careful, because if only one has a nxt, there is still an answer
      (Nothing,Nothing) -> none
      (Just(k1,v1,f1),Nothing) -> one (k1,v1,OrD f1 g comb)
      (Nothing,Just(k1,v1,g1)) -> one (k1,v1,OrD f g1 comb)
      (Just(k1,v1,f1),Just(k2,v2,g2)) ->
        case compare k1 k2 of
           EQ -> one (k1,apply comb v1 v2,OrD f1 g2 comb)
           LT -> one (k1,v1,OrD f1 g comb)
           GT -> one (k2,v2,OrD f g2 comb)

-- ===== Guard =====
guardStep
  :: Ord a =>
     (Dat a b -> Collect (a, b, Dat a b))
     -> Fun (a -> b -> Bool) -> Dat a b -> Collect (a, b, Dat a b)
guardStep next p f = do { triple <- next f; loop triple }
   where loop (k,v,f') = if (apply p k v) then one (k,v,GuardD f' p) else do { triple <- nxtDat f'; loop triple}

-- ===== Difference by key =====
diffStep :: Ord k => (k, v, Dat k v) -> Dat k u -> Collect (k, v, Dat k v)
diffStep (t1@(k1,u1,f1)) g =
   case hasElem (lubDat k1 g) of
      Nothing -> one (k1,u1,DiffD f1 g)  -- g has nothing to subtract
      Just (t2@(k2,u2,g2)) -> case compare k1 k2 of
          EQ -> do { tup <- nxtDat f1; diffStep tup g2 }
          LT -> one (k1,u1,DiffD f1 g)
          GT -> one (k1,u1,DiffD f1 g)   -- the hasLub guarantees k1 <= k2, so this case is dead code

-- ========== Rng ====================
rngStep :: Ord v => Dat k v -> Sett v ()
rngStep dat = materialize SetR (loop dat)
  where loop x = do { (k,v,x2) <- nxt x; front (v,()) (loop x2) }

-- =========================== Now the Iter instance for Dat ======================

nxtDat :: Dat a b -> Collect (a, b, Dat a b)
nxtDat (BaseD rep x) = do {(k,v,x2) <- nxt x; one(k,v,BaseD rep x2)}
nxtDat (ProjectD x p) = projStep nxtDat p x
nxtDat (AndD f g) = do { triple1 <- nxtDat f; triple2 <- nxtDat g; andStep triple1 triple2 }
nxtDat (ChainD f g p) = do { trip <- nxtDat f; chainStep trip g p}
nxtDat (AndPD f g p) = do { triple1 <- nxtDat f; triple2 <- nxtDat g; andPstep triple1 triple2 p }
nxtDat (OrD f g comb) = orStep nxtDat f g comb
nxtDat (GuardD f p) = guardStep nxtDat p f
nxtDat (DiffD f g) = do { trip <- nxtDat f; diffStep trip g }

lubDat :: Ord a => a ->  Dat a b -> Collect (a, b, Dat a b)
lubDat key (BaseD rep x) = do {(k,v,x2) <- lub key x; one(k,v,BaseD rep x2)}
lubDat key (ProjectD x p) = projStep (lubDat key) p x
lubDat key (AndD f g) = do { triple1 <- lubDat key f; triple2 <- lubDat key g; andStep triple1 triple2 }
lubDat key (ChainD f g p) = do { trip <- lubDat key f; chainStep trip g p}
lubDat  key (AndPD f g p) = do { triple1 <- lubDat key f; triple2 <- lubDat key g; andPstep triple1 triple2 p}
lubDat key (OrD f g comb) = orStep (lubDat key) f g comb
lubDat key (GuardD f p) = guardStep (lubDat key) p f
lubDat key (DiffD f g) = do { trip <- lubDat key f; diffStep trip g}


instance Iter Dat where
   nxt = nxtDat
   lub = lubDat

-- =================================================
-- Show Instances
-- =================================================

ppDat :: Dat k v -> Doc
ppDat (BaseD rep f) = parens $ text(show rep)
ppDat (ProjectD f p) = parens $ text "Proj" <+> align(vsep[ppDat f,text(show p)])
ppDat (AndD f g) = parens $ text "And" <+> align(vsep[ppDat f,ppDat g])
ppDat (ChainD f g p) = parens $ text "Chain" <+> align(vsep[ppDat f,ppDat g,text(show p)])
ppDat (OrD f g p) = parens $ text "Or" <+> align(vsep[ppDat f,ppDat g,text(show p)])
ppDat (GuardD f p) = parens $ text "Guard" <+> align(vsep[ppDat f,text(show p)])
ppDat (DiffD f g) = parens $ text "Diff" <+> align(vsep[ppDat f,ppDat g])
ppDat (AndPD f g p) = parens $ text "AndP" <+> align(vsep[ppDat f,ppDat g,text(show p)])


instance Show (Dat k v) where
   show x = show(ppDat x)