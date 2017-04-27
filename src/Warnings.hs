{-# LANGUAGE TupleSections, RecordWildCards, NamedFieldPuns, ScopedTypeVariables #-}

module Warnings(
    Warning(..),
    warningPath,
    warnings
    ) where

import Hi
import Cabal
import Util
import Data.Maybe
import Data.List.Extra
import Data.Tuple.Extra
import qualified Data.HashSet as Set
import qualified Data.HashMap.Strict as Map


data Warning = Warning
    {warningMessage :: String
    ,warningSections :: [CabalSectionType]
    ,warningPackage :: Maybe PackageName
    ,warningModule :: Maybe ModuleName
    ,warningIdentifier :: Maybe IdentName
    } deriving Show

warningPath :: Warning -> [String]
warningPath Warning{..} =
    [intercalate "," $ map show warningSections
    ,warningMessage] ++
    catMaybes [warningPackage, warningModule, warningIdentifier]

data S = S
    {hi :: HiKey -> Hi
    ,sections :: [(CabalSection, ([HiKey], [HiKey]))]
    }


---------------------------------------------------------------------
-- ACTUAL WARNING COMPUTATION

warnings :: (HiKey -> Hi) -> [(CabalSection, ([HiKey], [HiKey]))] -> [Warning]
warnings hi sections = map (\x -> x{warningSections = sort $ warningSections x}) $
    warnReusedModuleBetweenSections s ++
    warnRedundantPackageDependency s ++
    warnIncorrectOtherModules s ++
    warnUnusedExport s
    where s = S{..}


warnReusedModuleBetweenSections :: S -> [Warning]
warnReusedModuleBetweenSections S{..} =
    [ Warning "Module reused between two components" ss Nothing (Just $ hiModuleName $ hi m) Nothing
    | (m, ss) <- groupSort [(x, cabalSectionType c) | (c, (x1,x2)) <- sections, x <- x1++x2]
    , length ss > 1]


warnRedundantPackageDependency :: S -> [Warning]
warnRedundantPackageDependency S{..} =
    [ Warning "Redundant build-depends entry"
        [cabalSectionType] (Just p) Nothing Nothing
    | (CabalSection{..}, (x1,x2)) <- sections
    , let usedPackages = Set.unions $ map (hiImportPackage . hi) $ x1 ++ x2
    , p <- Set.toList $ Set.fromList cabalPackages `Set.difference` usedPackages]


warnIncorrectOtherModules :: S -> [Warning]
warnIncorrectOtherModules S{..} = concat
    [ [Warning "Missing other-modules entry" [cabalSectionType] Nothing (Just m) Nothing | m <- Set.toList missing] ++
      [Warning "Excessive other-modules entry" [cabalSectionType] Nothing (Just m) Nothing | m <- Set.toList excessive]
    | (CabalSection{..}, (external, internal)) <- sections
    , let imports = Map.fromList [(hiModuleName, Set.map identModule hiImportIdent) | Hi{..} <- map hi $ external ++ internal]
    , let missing =  Set.filter (not . isPathsModule) $
                     Set.unions (Map.elems imports) `Set.difference`
                     Set.fromList (Map.keys imports)
    , let excessive = Set.fromList (map (hiModuleName . hi) internal) `Set.difference`
                      reachable (\k -> maybe [] Set.toList $ Map.lookup k imports) (map (hiModuleName . hi) external)
    ]


warnUnusedExport :: S -> [Warning]
warnUnusedExport S{..} =
    [ Warning "Weeds exported" ss Nothing (Just $ hiModuleName $ hi m) (Just i)
    | (m,(ss,is)) <- Map.toList unused, i <- Set.toList is]
    where
        unionsWith f = foldr (Map.unionWith f) Map.empty
        -- important: for an identifer to be unused, it must be unused in all sections that use that key
        unused = unionsWith (\(s1,i1) (s2,i2) -> (s1++s2, i1 `Set.intersection` i2))
                 [ Map.fromList [(k, ([cabalSectionType], Set.fromList $ Map.lookupDefault [] (hiModuleName $ hi k) bad)) | k <- internal]
                 | (CabalSection{..}, (external, internal)) <- sections
                 , let bad = Map.fromListWith (++) $ map (identModule &&& pure . identName) $ notUsedOrExposed (map hi external) (map hi internal)]

notUsedOrExposed :: [Hi] -> [Hi] -> [Ident]
notUsedOrExposed external internal = Set.toList $ privateAPI `Set.difference` Set.union publicAPI usedAnywhere
    where
        -- things exported from this package
        publicAPI = Set.unions $ map hiExportIdent external

        -- things that are defined in other modules and exported
        privateAPI = Set.unions [Set.filter ((==) hiModuleName . identModule) $ hiExportIdentUnsupported hi | hi@Hi{..} <- internal]

        -- things that are used anywhere, if someone imports and exports something assume that isn't also a use (find some redundant warnings)
        usedAnywhere = Set.unions [hiImportIdent `Set.difference` hiExportIdent | Hi{..} <- external ++ internal]
