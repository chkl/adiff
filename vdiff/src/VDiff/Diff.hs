{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Main entry point. Implements all the commands that are called from Main
module VDiff.Diff where

import           VDiff.Prelude

import           Control.Monad.Random
import           Data.List                   (sortBy)
import qualified Data.List                   as L
import qualified Data.Map                    as Map
import           Data.Ord                    (comparing)
import qualified Data.Text.IO                as T
import qualified Data.Text.Lazy              as LT
import qualified Docker.Client               as Docker
import           Language.C
import           System.Directory
import           System.Exit
import           System.IO
import           Text.PrettyPrint            (render)

import           VDiff.ArithmeticExpressions (evalExpr)
import           VDiff.Data
import           VDiff.Execute
import           VDiff.Instrumentation
import           VDiff.Strategy
import           VDiff.Util.ResourcePool
import           VDiff.Verifier



cmdDiff :: HasMainEnv a => Maybe Int -> DiffParameters -> RIO a ()
cmdDiff seed params = do
  logInfo "starting diff"

  s <- case seed of
    Just s  -> return s
    Nothing -> getRandomR (1,10000)
  logInfo $ "seed for random generator: " <> display s
  liftIO $ setStdGen $ mkStdGen s


  mAst <- openCFile (params ^. inputFile)
  case mAst of
    Nothing -> liftIO exitFailure
    Just ast -> do
      let ast' = preprocess ast
      stratEnv <- mkStrategyEnv ast' params
      runRIO stratEnv $ executeStrategy $ params ^. strategy


-- | parses the file, runs the semantic analysis (type checking), and pretty-prints the resulting semantic AST.
-- Use this to test the modified language-c-extensible library.
cmdParseTest :: HasLogFunc env => FilePath -> RIO env ()
cmdParseTest fn = openCFile fn >>= \case
  Nothing -> liftIO exitFailure
  Just ast -> liftIO $ putStrLn $ render $ pretty ast


cmdMarkReads :: HasLogFunc env => SearchMode -> FilePath -> RIO env ()
cmdMarkReads mode fn = do
  logDebug $ "mode is " <> display (tshow mode)
  (Just ast) <- openCFile fn
  let ast' = markAllReads mode ast
  liftIO . putStrLn . render . pretty $ ast'

cmdVersions :: RIO a ()
cmdVersions = liftIO $ forM_ (sortBy (comparing (^. name)) allVerifiers) $ \verifier -> do
    T.putStr $ verifier ^. name
    putStr ": "
    sv <- try (verifier ^. version) >>= \case
      Left (_ :: IOException) -> return "unknown (error)"
      Right Nothing -> return "unknown"
      Right (Just v) -> return v
    putStrLn sv

cmdRunVerifiers :: (HasLogFunc env) => DiffParameters -> RIO env ()
cmdRunVerifiers dp = do
  source <- readFileUtf8 (dp ^. inputFile)
  pool <- newResourcePool (dp ^. verifierResources)
  logInfo $ "created pool with " <> display (length $ dp ^. verifierResources) <> " verifier resources"
  runs <- withResourcePool pool $ flip map (dp ^. verifiers) $ \(vn, flags, newName) r -> do
    result <- executeVerifierInDocker r vn flags source
    let name = fromMaybe vn newName
    printD $ display name <> ":\t " <> display (tshow $ result ^. verdict)
  return ()

mkStrategyEnv :: (HasMainEnv env) => CTranslationUnit SemPhase -> DiffParameters -> RIO env StrategyEnv
mkStrategyEnv tu dp = do
  lg <- view logFuncL
  db <- view databaseL
  let searchMode_ =  dp ^. searchMode
      budgetSpecification_ = dp ^. budgetSpecification
  -- interpret the budget specification
  let reads     = findAllReads searchMode_ tu
      positions = L.nub [r ^. position | r <- reads]
      exprEnv = Map.fromList [ ("reads", fromIntegral $ length reads)
                             , ("positions", fromIntegral $ length positions)
                             ]
  case evalExpr exprEnv (dp ^. budgetSpecification) of
    Left err -> error err
    Right bdg -> do
      logDebug $ "evaluated Doll expression '" <> display (dp ^. budgetSpecification) <> "' to " <> display (tshow bdg)
      return $ StrategyEnv  lg tu dp db (round bdg)
