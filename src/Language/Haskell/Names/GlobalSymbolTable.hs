{-# LANGUAGE DeriveDataTypeable #-}
-- | This module is designed to be imported qualified.
module Language.Haskell.Names.GlobalSymbolTable where

import Language.Haskell.Exts hiding (NewType, PatSyn)

import Data.Map (
    Map)
import qualified Data.Map as Map (
    empty,unionWith,fromListWith,lookup)

import Control.Arrow
import Data.List as List (union)
import Data.Maybe (fromMaybe)

import Language.Haskell.Names.Types
import Language.Haskell.Names.SyntaxUtils (dropAnn)

-- | Global symbol table — contains names declared somewhere at the top level.
type Table = Map (QName ()) [Symbol]

-- | Empty global symbol table.
empty :: Table
empty = Map.empty

-- | For each name take the union of the lists of symbols they refer to.
mergeTables :: Table -> Table -> Table
mergeTables = Map.unionWith List.union

lookupValue :: QName l -> Table -> [Symbol]
lookupValue qn = filter isValue . lookupName qn

lookupType :: QName l -> Table -> [Symbol]
lookupType qn = filter isType . lookupName qn

lookupMethodOrAssociate :: QName l -> Table -> [Symbol]
lookupMethodOrAssociate qn = filter isMethodOrAssociated . lookupName qn

lookupSelector :: QName l -> Table -> [Symbol]
lookupSelector qn = filter isSelector . lookupName qn

lookupCategory :: QName l -> Table -> [Symbol]
lookupCategory qn = filter isCategory . lookupName qn

lookupPiece :: QName l -> Table -> [Symbol]
lookupPiece qn = filter isPiece . lookupName qn

lookupName ::  QName l -> Table -> [Symbol]
lookupName qn table = fromMaybe [] (Map.lookup (dropAnn qn) table)

isValue :: Symbol -> Bool
isValue symbol = case symbol of
    Value {} -> True
    Method {} -> True
    Selector {} -> True
    Constructor {} -> True
    PatternConstructor {} -> True
    PatternSelector {} -> True
    _ -> False

isType :: Symbol -> Bool
isType symbol = case symbol of
    Type {} -> True
    Data {} -> True
    NewType {} -> True
    TypeFam {} -> True
    DataFam {} -> True
    Class   {} -> True
    _ -> False

isMethodOrAssociated :: Symbol -> Bool
isMethodOrAssociated symbol = case symbol of
    Method {} -> True
    TypeFam {} -> True
    DataFam {} -> True
    _ -> False

isSelector :: Symbol -> Bool
isSelector symbol = case symbol of
    Selector {} -> True
    PatternSelector {} -> True
    _ -> False

isCategory :: Symbol -> Bool
isCategory symbol = case symbol of
    PieceCategory {} -> True
    _ -> False

isPiece :: Symbol -> Bool
isPiece symbol = case symbol of
    Piece {} -> True
    _ -> False

fromList :: [(QName (),Symbol)] -> Table
fromList = Map.fromListWith List.union . map (second (:[]))

