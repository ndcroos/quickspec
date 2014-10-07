{-# LANGUAGE CPP, ConstraintKinds, TypeSynonymInstances, FlexibleInstances, ScopedTypeVariables, TupleSections #-}
module Test.QuickSpec.Eval where

#include "errors.h"
import Test.QuickSpec.Base
import Test.QuickSpec.Utils
import Test.QuickSpec.Type
import Test.QuickSpec.Term
import Test.QuickSpec.Signature
import Test.QuickSpec.Equation
import Data.Constraint
import Data.Map(Map)
import Data.Maybe
import qualified Data.Map as Map
import Control.Monad
import Test.QuickSpec.Pruning
import qualified Test.QuickSpec.Pruning as Pruning
import Test.QuickSpec.Pruning.Simple hiding (S)
import Test.QuickSpec.Pruning.E hiding (S)
import qualified Test.QuickSpec.Pruning.Simple as Simple
import qualified Test.QuickSpec.Pruning.E as E
import Data.List hiding (insert)
import Data.Ord
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Class
import Data.MemoCombinators
import Data.MemoCombinators.Class
import Test.QuickCheck hiding (collect, Result)
import System.Random
import Test.QuickCheck.Gen
import Test.QuickCheck.Random
import qualified Data.Typeable.Internal as T
import Data.Word
import Debug.Trace
import System.IO
import PrettyPrinting

type TestSet = Map (Poly Type) (Value TestedTerms)

data TestedTerms a =
  TestedTerms {
    dict :: Dict (Ord a),
    testResults :: TestResults a }

data TestResults a = TestCase (Map a (TestResults a)) | Singleton (TestedTerm a)

data TestedTerm a =
  TestedTerm {
    term  :: Term,
    tests :: [a] }

type M = StateT S IO

data S = S {
  schemas       :: Schemas,
  schemaTestSet :: TestSet,
  termTestSet   :: Map (Poly Schema) TestSet,
  pruner        :: SimplePruner }

initialTestedTerms :: Signature -> Type -> Maybe (Value TestedTerms)
initialTestedTerms sig ty = do
  inst <- listToMaybe [ i | i <- ords sig, typ i == ty ]
  return $ forValue inst $ \(Instance dict) ->
    TestedTerms {
      dict = dict,
      testResults = TestCase Map.empty }

findTestSet :: Signature -> Type -> TestSet -> Maybe (Value TestedTerms)
findTestSet sig ty m =
  Map.lookup (poly ty) m `mplus`
  initialTestedTerms sig ty

data Result = New TestSet | Old Term | Untestable

insert :: Signature -> Value TestedTerm -> TestSet -> Result
insert sig x ts =
  case findTestSet sig (typ x) ts of
    Nothing -> Untestable
    Just tts ->
      case unwrap (pairValues insert1 x tts) of
        U (New1 tts) wrap ->
          New (Map.insert (poly (typ x)) (wrap tts) ts)
        U (Old1 t) _ ->
          Old t

data Result1 a = New1 (TestedTerms a) | Old1 Term

insert1 :: TestedTerm a -> TestedTerms a -> Result1 a
insert1 x ts =
  case dict ts of
    Dict -> aux k (term x) (tests x) (testResults ts)
  where
    k res = ts { testResults = res }
    aux :: Ord a => (TestResults a -> TestedTerms a) -> Term -> [a] -> TestResults a -> Result1 a
    aux k x [] (Singleton (TestedTerm y [])) = Old1 y
    aux k x ts (Singleton (TestedTerm y (t':ts'))) =
      aux k x ts (TestCase (Map.singleton t' (Singleton (TestedTerm y ts'))))
    aux k x (t:ts) (TestCase res) =
      case Map.lookup t res of
        Nothing -> New1 (k (TestCase (Map.insert t (Singleton (TestedTerm x ts)) res)))
        Just res' ->
          let k' r = k (TestCase (Map.insert t r res)) in
          aux k' x ts res'

makeTests :: (Type -> Value Gen) -> [(QCGen, Int)] -> Term -> Value TestedTerm
makeTests env tests t =
  mapValue (TestedTerm t . f) (evaluateTerm env t)
  where
    f :: Gen a -> [a]
    f x = map (uncurry (unGen x)) tests

env :: Signature -> Type -> Value Gen
env sig ty =
  case [ i | i <- arbs sig, typ i == ty ] of
    [] ->
      toValue (ERROR $ "missing arbitrary instance for " ++ prettyShow ty :: Gen A)
    (i:_) ->
      forValue i $ \(Instance Dict) -> arbitrary

type Schemas = Map Int (Map (Poly Type) [Schema])

instance Pruner S where
  emptyPruner      = initialState
  unifyUntyped t u = inPruner (unifyUntyped t u)
  repUntyped t     = inPruner (repUntyped t)

inPruner x = do
  s <- get
  let (y, s') = runState x (pruner s)
  put s { pruner = s' }
  return y

initialState :: S
initialState =
  S { schemas       = Map.empty,
      schemaTestSet = Map.empty,
      termTestSet   = Map.empty,
      pruner        = emptyPruner }

typeSchemas :: [Schema] -> Map Type [Schema]
typeSchemas = fmap (map schema) . collect . map instantiate

collect :: Typed a => [a] -> Map Type [a]
collect xs =
  Map.fromList [(typ y, ys) | ys@(y:_) <- partitionBy typ xs]

schemasOfSize :: Int -> Signature -> M [Schema]
schemasOfSize 1 sig =
  return $
    [Var ty | ty <- tys] ++
    [Fun c [] | c <- constants sig]
  where
    tys = [typeOf (undefined :: [Int])]
    {-tys = [typeOf (undefined :: Int),
           typeOf (undefined :: [Bool]),
           typeOf (undefined :: Layout Bool)]-}
schemasOfSize n _ = do
  ss <- gets schemas
  return $
    [ unPoly (apply f x)
    | i <- [1..n-1],
      let j = n-i,
      (fty, fs) <- Map.toList =<< maybeToList (Map.lookup i ss),
      canApply fty (poly (Var (TyVar 0))),
      or [ canApply (poly f) (poly (Var (Var (TyVar 0)))) | f <- fs ],
      (xty, xs) <- Map.toList =<< maybeToList (Map.lookup j ss),
      canApply fty xty,
      f <- fmap poly fs,
      canApply f (poly (Var (Var (TyVar 0)))),
      x <- fmap poly xs ]

genSeeds :: Int -> IO [(QCGen, Int)]
genSeeds maxSize = do
  rnd <- newQCGen
  let rnds rnd = rnd1 : rnds rnd2 where (rnd1, rnd2) = split rnd
  return (zip (rnds rnd) (concat (repeat [0,2..maxSize])))

quickSpec :: Signature -> IO ()
quickSpec sig = do
  hSetBuffering stdout NoBuffering
  seeds <- genSeeds 20
  _ <- execStateT (go 1 sig (take 100 seeds) (table (env sig))) initialState
  return ()

go :: Int -> Signature -> [(QCGen, Int)] -> (Type -> Value Gen) -> M ()
go 10 _ _ _ = return ()
go n sig seeds gen = do
  modify (\s -> s { schemas = Map.insert n Map.empty (schemas s) })
  ss <- fmap (sortBy (comparing measure)) (schemasOfSize n sig)
  lift $ putStr ("\n\nSize " ++ show n ++ ", " ++ show (length ss) ++ " schemas to consider: ")
  mapM_ (consider sig seeds gen) ss
  go (n+1) sig seeds gen

allUnifications :: Term -> [Term]
allUnifications t = map f ss
  where
    vs = [ map (x,) xs | xs <- partitionBy typ (usort (vars t)), x <- xs ]
    ss = map Map.fromList (sequence vs)
    go s x = Map.findWithDefault __ x s
    f s = rename (go s) t

consider :: Signature -> [(QCGen, Int)] -> (Type -> Value Gen) -> Schema -> M ()
consider sig gen env s = do
  state <- get
  let t = instantiate s
  case evalState (repUntyped (encodeTypes t)) (pruner state) of
    Nothing -> do
      -- Need to test this term
      let skel = skeleton t
      case insert sig (makeTests env gen skel) (schemaTestSet state) of
        Untestable ->
          accept s
        Old u -> do
          --lift (putStrLn ("Found schema equality! " ++ prettyShow (untyped skel :=: untyped u)))
          lift $ putStr "!"
          let s = schema u
              extras =
                case Map.lookup (poly s) (termTestSet state) of
                  Nothing -> allUnifications (instantiate (schema u))
                  Just _ -> []
          modify (\st -> st { termTestSet = Map.insertWith (\x y -> y) (poly s) Map.empty (termTestSet st) })
          mapM_ (considerTerm sig gen env s) (sortBy (comparing measure) (extras ++ allUnifications t))
        New ts' -> do
          lift $ putStr "O"
          modify (\st -> st { schemaTestSet = ts' })
          when (simple s) $ do
            modify (\st -> st { termTestSet = Map.insertWith (\x y -> y) (poly s) Map.empty (termTestSet st) })
            mapM_ (considerTerm sig gen env s) (sortBy (comparing measure) (allUnifications (instantiate s)))
          accept s
    Just u | measure (schema (decodeTypes u)) < measure s -> do
      lift $ putStr "X"
      -- lift $ putStrLn ("Throwing away redundant schema: " ++ prettyShow t ++ " -> " ++ prettyShow (decodeTypes u))
      let pruner' = execState (unifyUntyped (encodeTypes t) u) (pruner state)
      put state { pruner = pruner' }

-- simple t = size t <= 5
-- simple t = True
simple t = False

considerTerm :: Signature -> [(QCGen, Int)] -> (Type -> Value Gen) -> Schema -> Term -> M ()
considerTerm sig gen env s t = do
  state <- get
  case evalState (repUntyped (encodeTypes t)) (pruner state) of
    Nothing -> do
      --lift $ putStrLn ("Couldn't simplify " ++ prettyShow (t))
      case insert sig (makeTests env gen t) (Map.findWithDefault __ (poly s) (termTestSet state)) of
        Untestable ->
          ERROR "testable term became untestable"
        Old u -> do
          found t u
          modify (\st -> st { pruner = execState (Test.QuickSpec.Pruning.unify (t :=: u)) (pruner st) })
        New ts' -> do
          lift $ putStr "o"
          modify (\st -> st { termTestSet = Map.insert (poly s) ts' (termTestSet st) })
    Just u -> do
      lift $ putStr "x"
      --lift $ putStrLn ("Throwing away redundant term: " ++ prettyShow (untyped t) ++ " -> " ++ prettyShow (decodeTypes u))
      let pruner' = execState (unifyUntyped (encodeTypes t) u) (pruner state)
      put state { pruner = pruner' }

found :: Term -> Term -> M ()
found t u = do
  Simple.S eqs <- gets pruner
  case False of -- evalState (Pruning.unify (t :=: u)) (E.S eqs) of
    True -> do
      lift $ putStrLn ("\nProved by E: " ++ prettyShow t ++ " = " ++ prettyShow u)
      return ()
    False ->
      lift $ putStrLn ("\n******** " ++ prettyShow t ++ " = " ++ prettyShow u)

accept :: Schema -> M ()
accept s = do
  --lift (putStrLn ("Accepting schema " ++ prettyShow s))
  modify (\st -> st { schemas = Map.adjust f (size s) (schemas st) })
  where
    t = instantiate s
    f m = Map.insertWith (++) (poly (typ t)) [s] m

instance MemoTable Type where
  table = wrap f g table
    where
      f :: Either Int (TyCon, [Type]) -> Type
      f (Left x) = Var (TyVar x)
      f (Right (x, xs)) = Fun x xs
      g :: Type -> Either Int (TyCon, [Type])
      g (Var (TyVar x)) = Left x
      g (Fun x xs) = Right (x, xs)

instance MemoTable TyCon where
  table = wrap f g table
    where
      f :: Maybe T.TyCon -> TyCon
      f (Just x) = TyCon x
      f Nothing = Arrow
      g :: TyCon -> Maybe T.TyCon
      g (TyCon x) = Just x
      g Arrow = Nothing

instance MemoTable T.TyCon where
  table = wrap f g table
    where
      f :: (Word64, Word64) -> T.TyCon
      f (x, y) = T.TyCon (T.Fingerprint x y) undefined undefined undefined
      g :: T.TyCon -> (Word64, Word64)
      g (T.TyCon (T.Fingerprint x y) _ _ _) = (x, y)
