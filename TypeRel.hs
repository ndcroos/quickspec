{-# LANGUAGE Rank2Types, TypeOperators #-}
module TypeRel where

import qualified TypeMap
import TypeMap(TypeMap)
import Typed
import Typeable

type TypeRel f = TypeMap (List `O` f)

empty :: TypeRel f
empty = TypeMap.empty

singleton :: Typeable a => f a -> TypeRel f
singleton x = TypeMap.singleton (O [x])

fromList :: [Some f] -> TypeRel f
fromList = TypeMap.fromList . classify

toList :: TypeRel f -> [Some f]
toList = concatMap disperse . TypeMap.toList

lookup :: Typeable a => a -> TypeRel f -> [f a]
lookup x m = unO (TypeMap.lookup (O []) x m)

mapValues :: (forall a. Typeable a => f a -> g a) -> TypeRel f -> TypeRel g
mapValues f = TypeMap.mapValues2 (map f)