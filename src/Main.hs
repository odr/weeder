{-# LANGUAGE TupleSections, RecordWildCards, ScopedTypeVariables #-}

module Main(main) where

import Hi
import Cabal
import Stack
import Data.List.Extra
import Data.Functor
import Data.Tuple.Extra
import Control.Monad.Extra
import System.Exit
import System.IO.Extra
import qualified Data.HashMap.Strict as Map
import System.Directory.Extra
import System.FilePath
import Check
import Warning
import CmdLine
import Prelude


data Result = Good | Bad deriving Eq

main :: IO ()
main = do
    cmd@Cmd{..} <- getCmd
    res <- mapM (weedDirectory cmd) cmdProjects
    when (Bad `elem` res) exitFailure


weedDirectory :: Cmd -> FilePath -> IO Result
weedDirectory Cmd{..} dir = do
    file <- do b <- doesDirectoryExist dir; return $ if b then dir </> "stack.yaml" else dir
    when cmdBuild $ buildStack file
    Stack{..} <- parseStack file
    cabals <- forM stackPackages $ \x -> do
        file <- selectCabalFile $ dir </> x
        (file,) <$> parseCabal file

    ignore <- do
        let x = takeDirectory file </> ".weeder.yaml"
        b <- doesFileExist x
        if not b then return [] else readWarningsFile x

    res <- concatForM cabals $ \(cabalFile, cabal@Cabal{..}) -> do
        (fileToKey, keyToHi) <- hiParseDirectory $ takeDirectory cabalFile </> stackDistDir
        let warn = check (keyToHi Map.!) cabalName $ map (id &&& selectHiFiles fileToKey) cabalSections
        unless (cmdJson || cmdYaml) $
            putStrLn $ unlines $ showWarningsPretty cabalName warn
        return warn

    when cmdJson $ putStrLn $ showWarningsJson res
    when cmdYaml $ putStrLn $ showWarningsYaml res
    if cmdMatch then
        if sort ignore == sort res
        then putStrLn "Warnings match" >> return Good
        else putStrLn "ERROR: Warnings do not match" >> return Bad
     else
        return $ if null res then Good else Bad
