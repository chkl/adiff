{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE TemplateHaskell        #-}

module Main where

import           Control.Lens.Operators                 hiding ((^.))
import           Control.Lens.TH
import           Data.Tuple.Extra
import qualified Database.SQLite.Simple                 as SQL
import           Graphics.Rendering.Chart.Backend.Cairo
import qualified Graphics.Rendering.Chart.Easy          as Chart
import qualified Prelude                                as P
import           RIO
import           RIO.List
import           System.Exit
import           System.IO
import qualified Text.PrettyPrint.Tabulate              as T

import           VDiff.Arguments                        hiding (command)
import           VDiff.Data
import qualified VDiff.Query                            as Q
import           VDiff.Types
import           VDiff.Persistence (withDiffDB)


data ViewCommand = Stats
                 | List Q.Query
                 | Count Q.Query
                 | Program String
                 | TimeMemoryGraph FilePath
                 | Merge [FilePath]
                 deriving (Show, Eq)

data ViewParameters = ViewParameters
  { _databaseFn :: FilePath
  , _command    :: ViewCommand
  }
makeFieldsNoPrefix ''ViewParameters




main :: IO ()
main = do
  vp <- execParser opts
  -- set up logging
  logOptions <- logOptionsHandle stderr True
  let logOptions' = setLogMinLevel LevelDebug logOptions
  -- set up sql
  -- SQL.withConnection (vp ^. databaseFn) $ \conn ->
  withDiffDB (vp ^. databaseFn) $ \conn ->
    withLogFunc logOptions' $ \logger -> do
      let viewEnv = MainEnv logger conn
      runRIO viewEnv $ do
        Q.updateIndices
        executeView (vp ^. command)

instance T.CellValueFormatter Text

executeView :: (HasMainEnv env) => ViewCommand -> RIO env ()
executeView Stats = do
  stats <- Q.stats
  liftIO $  T.printTable stats
  return ()
executeView (List q) = do
  rs <- case q  of
        Q.Incomplete   -> Q.allIncomplete
        Q.Unsound      -> Q.allUnsound
        Q.Disagreement -> Q.allDisagreement
  liftIO $ T.printTable rs
executeView (Count q) = do
  rs <- case q  of
        Q.Incomplete   -> Q.allIncomplete
        Q.Unsound      -> Q.allUnsound
        Q.Disagreement -> Q.allDisagreement
  liftIO $ print $ length rs
executeView (Program hsh) = do
  p <- Q.programByHash hsh
  liftIO $ case p of
    Just p' -> putStr (p' ^. source)
    Nothing -> do
      hPutStrLn stderr $ "could not find program with hash: " <> hsh
      exitFailure
executeView (TimeMemoryGraph outp) = do
  d <- Q.allRuns
  liftIO $ renderPoints (cleanData d) outp
executeView (Merge files) = do
  mainConn <- view databaseL

  -- loop over the given databases
  liftIO $
    forM_ files $ \f -> do
      putStrLn $ "merging file " ++ f
      SQL.withConnection f $ \conn -> do

        putStrLn "merging programs"
        SQL.fold_ conn "SELECT code_hash,origin,content FROM programs" () $ \_ prg -> do
          let _ = prg :: (Text,Text,Text)
          SQL.execute mainConn "INSERT OR IGNORE INTO programs(code_hash,origin,content) VALUES(?,?,?)" prg
          putStr "."
        putStrLn ""

        putStrLn "merging runs"
        SQL.fold_ conn "SELECT run_id,verifier_name,result,time,memory,code_hash FROM runs;" () $ \_ run -> do
          let (_ :: Integer, vn :: Text, result :: Text, time :: Maybe Float, mem :: Maybe Integer, hsh :: Text ) = run
              runWithoutId = (vn, result, time, mem, hsh)
          SQL.execute mainConn "INSERT OR IGNORE INTO runs(verifier_name,result,time,memory,code_hash) VALUES(?,?,?,?,?)" runWithoutId
          putStr "."
        putStrLn ""

opts :: ParserInfo ViewParameters
opts = info (viewParameters <**> helper) (progDesc "viewer for vdiff")


viewParameters :: Parser ViewParameters
viewParameters = ViewParameters <$> databasePath  <*> viewCommand

viewCommand :: Parser ViewCommand
viewCommand = statCmd <|> listCmd <|> countCmd <|> programCmd <|> correlationCmd <|> mergeCmd

statCmd,listCmd,countCmd,programCmd,correlationCmd,mergeCmd :: Parser ViewCommand
statCmd = switch options $> Stats
  where options = mconcat [ long "stat"
                          , short 's'
                          , help "print basic statistics about this database"
                          ]

listCmd = switch options $> List <*> query
  where options = mconcat [ long "list"
                          , short 'l'
                          , help "prints a list"
                          ]

countCmd = switch options $> Count <*> query
  where options = mconcat [ long "count"
                          , help "returns the number of findings"
                          ]

programCmd = Program <$> option str options
  where options = mconcat [ long "hash"
                          , help "returns the source code of a program with the given hash"
                          ]

correlationCmd = switch options $> TimeMemoryGraph <*> someFile
  where options = mconcat [ long "correlation"
                          , help "generates a scatter plot of memory consumption and runtime" ]

mergeCmd = switch options $>  Merge <*> many someFile
  where options = mconcat [ long "merge"
                          , help "merge database files into one"]

query :: Parser Q.Query
query = incmpl <|> unsound <|> disagreement
  where incmpl = switch (long "incomplete") $> Q.Incomplete
        unsound = switch (long "unsound") $> Q.Unsound
        disagreement = switch (long "disagreement") $> Q.Disagreement



--------------------------------------------------------------------------------
-- for the time / memory chart
--------------------------------------------------------------------------------

data DataLine = DataLine
  { verifier    :: String
  , proportions :: [(Double, Int)]
  }

cleanData :: [(String, Maybe Double, Maybe Int)] -> [DataLine]
cleanData runs =
  let terminated = [(s,t, m `div` 1024 ) | (s, Just t, Just m) <- runs] -- memory in MiB
      grouped = groupBy (\(x,_,_) (x',_,_) -> x == x') (sortOn fst3 terminated)
      tagged = [DataLine (fst3 (P.head g)) (e23 g) | g <- grouped]
  in tagged
  where
    e23 g = [(y,z) | (_,y,z) <- g]


clrs :: [Chart.AlphaColour Double]
clrs = map Chart.opaque [ Chart.red
                        , Chart.blue
                        , Chart.green
                        , Chart.yellow
                        , Chart.black
                        , Chart.brown
                        , Chart.coral
                        ]

renderPoints :: [DataLine] -> FilePath -> IO ()
renderPoints lns outp = do
  let fileOptions = (fo_format .~ SVG) def
  toFile fileOptions outp $ do
    Chart.layout_title .= "resident memory (MiB) / Time (s)"
    forM_ (zip lns (cycle clrs)) $ \(ln, c) -> do
      Chart.setColors [c]
      Chart.plot (Chart.points (verifier ln) (proportions ln))
