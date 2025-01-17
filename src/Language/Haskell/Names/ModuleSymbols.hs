{-# LANGUAGE ScopedTypeVariables, ViewPatterns #-}
module Language.Haskell.Names.ModuleSymbols
  ( moduleSymbols
  , moduleTable
  , getTopDeclSymbols
  )
  where

import Data.Maybe
import Data.Data
import qualified Data.Map as Map

import Language.Haskell.Exts hiding (DataOrNew(NewType))
import qualified Language.Haskell.Exts as Syntax (DataOrNew(NewType))
import Language.Haskell.Names.Types
import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import Language.Haskell.Names.SyntaxUtils
import Language.Haskell.Names.ScopeUtils
import Language.Haskell.Names.GetBound

-- | Compute module's global table. It contains both the imported entities
-- and the global entities defined in this module.
moduleTable
  :: (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> Module l
  -> Global.Table
moduleTable impTbl m = Global.mergeTables impTbl (computeSymbolTable
  False (dropAnn (getModuleName m)) (moduleSymbols impTbl m))

-- | Compute the symbols that are defined in the given module.
--
-- The import table is needed to resolve possible top-level record
-- wildcard bindings, such as
--
-- >A {..} = foo
moduleSymbols
  :: (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> Module l
  -> [Symbol]
moduleSymbols impTbl m =
  concatMap (getTopDeclSymbols impTbl $ getModuleName m) (getModuleDecls m)

getTopDeclSymbols
  :: forall l . (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> ModuleName l
  -> Decl l
  -> [Symbol]
getTopDeclSymbols impTbl modulename d = (case d of
    TypeDecl _ dh _ -> [declHeadSymbol Type dh]

    TypeFamDecl _ dh _ _ -> [TypeFam (dropAnn modulename) (dropAnn (getDeclHeadName dh)) Nothing]

    DataDecl _ dataOrNew _ dh qualConDecls _ -> declHeadSymbol (dataOrNewCon dataOrNew) dh : infos where

        dq = getDeclHeadName dh

        infos = constructorsToInfos modulename dq (qualConDeclNames qualConDecls)

    GDataDecl _ dataOrNew _ dh _ gadtDecls _ -> declHeadSymbol (dataOrNewCon dataOrNew) dh : infos where
      -- FIXME: We shouldn't create selectors for fields with existential type variables!
        dq = getDeclHeadName dh

        cons :: [(Name l,[Name l])]
        cons = do -- list monad
          GadtDecl _ cn _ _ (fromMaybe [] -> fields) _ty <- gadtDecls
          return (cn , [f | FieldDecl _ fNames _ <- fields, f <- fNames])

        infos = constructorsToInfos modulename dq cons          

    DataFamDecl _ _ dh _ -> [DataFam (dropAnn modulename) (dropAnn (getDeclHeadName dh)) Nothing]

    ClassDecl _ _ declHead _ mds -> classSymbol : typeFamilySymbols ++ dataFamilySymbols ++ methodSymbols where
        cdecls = fromMaybe [] mds
        classSymbol = declHeadSymbol Class declHead
        typeFamilySymbols = do
            ClsTyFam   _   familyHead _ _ <- cdecls
            return (TypeFam (dropAnn modulename) (dropAnn (getDeclHeadName familyHead)) (Just (dropAnn (getDeclHeadName declHead))))
        dataFamilySymbols = do
            ClsDataFam _ _ familyHead _ <- cdecls
            return (DataFam (dropAnn modulename) (dropAnn (getDeclHeadName familyHead)) (Just (dropAnn (getDeclHeadName declHead))))
        methodSymbols = do
            methodName <- getBound impTbl d
            return (Method (dropAnn modulename) (dropAnn methodName) (dropAnn (getDeclHeadName declHead)))

    FunBind _ ms -> [ Value (dropAnn modulename) (dropAnn vn) ] where
      vn : _ = getBound impTbl ms

    PatBind _ p _ _ -> [ Value (dropAnn modulename) (dropAnn vn) | vn <- getBound impTbl p ]

    PatSyn _ p _ _ -> case patternHead p of
      Just patternName -> patternConstructor : patternSelectors where
        patternConstructor = PatternConstructor (dropAnn modulename) (dropAnn patternName) Nothing
        patternSelectors = [PatternSelector (dropAnn modulename) (dropAnn fn) Nothing (dropAnn patternName) | fn <- patternFields p ]
      Nothing -> []

    ForImp _ _ _ _ fn _ -> [ Value (dropAnn modulename) (dropAnn fn)]

    DataInsDecl _ _ typ qualConDecls _ -> constructorsToInfos modulename (typeOuterName typ) (qualConDeclNames qualConDecls)

    GDataInsDecl _ _ typ _ gadtDecls _ -> constructorsToInfos modulename (typeOuterName typ) cons where
      -- FIXME: We shouldn't create selectors for fields with existential type variables!
        cons :: [(Name l,[Name l])]
        cons = do -- list monad
          GadtDecl _ cn _ _ (fromMaybe [] -> fields) _ty <- gadtDecls
          return (cn , [f | FieldDecl _ fNames _ <- fields, f <- fNames])

    PieceCatDecl _ category -> [ PieceCategory (dropAnn modulename) (dropAnn category) ]

    PieceDecl _ category _ declHead qualConDecls -> piece : infos where
        pieceName = getDeclHeadName declHead
        piece = Piece (dropAnn modulename) (dropAnn pieceName) catModule (dropAnn $ qNameToName category)
        catModule = moduleForCat impTbl modulename category
        infos = toPieceConstructor <$> constructorsToInfos modulename pieceName (qualConDeclNames qualConDecls)
        toPieceConstructor (Constructor n1 n2 n3) = PieceConstructor n1 n2 n3
        toPieceConstructor symbol                 = symbol

    CompFunDecl _ names _ category _ -> map nameToInfo names where
        nameToInfo name = ExtFunction (dropAnn modulename) (dropAnn name) catModule (dropAnn $ qNameToName category)
        catModule = moduleForCat impTbl modulename category

    _ -> [])
        where
            declHeadSymbol c dh = c (dropAnn modulename) (dropAnn (getDeclHeadName dh))

moduleForCat :: Global.Table -> ModuleName l -> QName l -> ModuleName ()
moduleForCat impTbl modulename category =
    case Global.lookupCategory category impTbl of
            [symbol] -> symbolModule symbol  -- the category is imported from a singular module
            _ -> dropAnn modulename -- the category comes from either this module or multible imported modules

-- | Takes a type name and a list of constructor names paired with selector names. Returns
--   all symbols i.e. constructors and selectors.
constructorsToInfos :: ModuleName l -> Name l -> [(Name l,[Name l])] -> [Symbol]
constructorsToInfos modulename typename constructors = conInfos ++ selInfos where
        conInfos = do
            (constructorname,_) <- constructors
            return (Constructor (dropAnn modulename) (dropAnn constructorname) (dropAnn typename))

        selectorsMap = Map.fromListWith (++) (do
            (constructorname,selectornames) <- constructors
            selectorname <- selectornames
            return (nameToString selectorname,[constructorname]))

        selInfos = do
            (_,selectornames) <- constructors
            selectorname <- selectornames
            constructornames <- maybeToList (Map.lookup (nameToString selectorname) selectorsMap)
            return (Selector (dropAnn modulename) (dropAnn selectorname) (dropAnn typename) (map dropAnn constructornames))

typeOuterName :: Type l -> Name l
typeOuterName t = case t of
    TyForall _ _ _ typ -> typeOuterName typ
    TyApp _ typ _ -> typeOuterName typ
    TyCon _ qname -> qNameToName qname
    TyParen _ typ -> typeOuterName typ
    TyInfix _ _ (PromotedName _ qname) _ -> qNameToName qname
    TyInfix _ _ (UnpromotedName _ qname) _ -> qNameToName qname
    TyKind _ typ _ -> typeOuterName typ
    TyBang _ _ _ typ -> typeOuterName typ
    _ -> error "illegal data family in data instance"

qualConDeclNames :: [QualConDecl l] -> [(Name l,[Name l])]
qualConDeclNames qualConDecls = do
    QualConDecl _ _ _ conDecl <- qualConDecls
    case conDecl of
        ConDecl _ n _ -> return (n, [])
        InfixConDecl _ _ n _ -> return (n, [])
        RecDecl _ n fields ->
            return (n , [f | FieldDecl _ fNames _ <- fields, f <- fNames])


dataOrNewCon :: Syntax.DataOrNew l -> ModuleName () -> Name () -> Symbol
dataOrNewCon dataOrNew = case dataOrNew of DataType {} -> Data; Syntax.NewType {} -> NewType


patternHead :: Pat l -> Maybe (Name l)
patternHead (PApp _ (UnQual _ n) _) = Just n
patternHead (PInfixApp _ _ (UnQual _ n) _) = Just n
patternHead (PRec _ (UnQual _ n) _) = Just n
patternHead _ = Nothing


patternFields :: Pat l -> [Name l]
patternFields (PRec _ _ fs) = concatMap get' fs where
  get' (PFieldPat _ (UnQual _ n) _) = [n]
  get' (PFieldPun _ (UnQual _ n)) = [n]
  get' _ = []
patternFields _ = []

