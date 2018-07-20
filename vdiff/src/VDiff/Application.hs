{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- Building blocks for applications -}
module VDiff.Application where

import qualified Data.List              as L
import qualified Data.Text              as T
import           Database.Beam
import           Database.Beam.Sqlite   as Sqlite
import qualified Database.SQLite.Simple as SQL
import qualified Database.SQLite3       as Sqlite3
import           Options.Applicative
import           RIO
import           System.IO              (putStrLn)
import           VDiff.Data

import           VDiff.Persistence      (retryOnBusy, runBeam)
import           VDiff.Prelude.Types

runVDiffApp :: Parser p -> (forall b. InfoMod b) -> (p -> RIO MainEnv a) -> IO a
runVDiffApp parser infoMod app = do
  -- parse arguments
  let combinedParser = (,) <$> parseMainArguments <*> parser
  ((dbPath, inMemoryFlag, bkpPath, logLevel), customParams) <- execParser (info (combinedParser <**> helper) infoMod)

  -- set up logging
  logOptions <- logOptionsHandle stderr True
  let logOptions' = setLogMinLevel logLevel logOptions

  let dbPath' = if inMemoryFlag then ":memory:" else dbPath
  -- wrap app in withLogFunc and withDiffDB
  withLogFunc logOptions' $ \logger ->
    withDiffDB dbPath' $ \database -> do
      let env = MainEnv logger database
      runRIO env $ do
        -- if necessary load into memory
        when inMemoryFlag (restoreDb (T.pack dbPath))
        x <- app customParams
        -- run backup if requested
        case bkpPath of
          Nothing  -> return ()
          Just bkp -> backupDb (T.pack bkp)
        return x


-- | parses loglevel, database
parseMainArguments :: Parser (FilePath, Bool, Maybe FilePath, LogLevel)
parseMainArguments = (,,,) <$> databasePath <*> inMemory <*> databaseBkpPath <*> level


level :: Parser LogLevel
level = option levelP options
  where
    options = mconcat [ long "log-level"
                      , help helpText
                      , metavar "LOGLEVEL"
                      , value LevelWarn
                      , completeWith values
                      ]
    values = ["debug", "info", "warning", "error"]
    helpText = "Allowed values: " ++ L.intercalate ", " values
    levelP = (str :: ReadM Text ) >>= \case
      "debug"   -> return LevelDebug
      "info"    -> return LevelInfo
      "warning" -> return LevelWarn
      "error"   -> return LevelError
      s -> readerError $ "unknown log-level " ++ show s

databasePath :: Parser String
databasePath = option str options
  where options = mconcat [ long "database"
                          , short 'd'
                          , help "path to sqlite3 database (if not given, an in-memory database is used)"
                          , value ":memory:"
                          , action "file"
                          ]

databaseBkpPath :: Parser (Maybe String)
databaseBkpPath = option (Just <$> str) options
  where options = mconcat [ long "backup"
                          , help "path to sqlite3 backup database (optional, if given, performs backup)"
                          , action "file"
                          , value Nothing
                          ]

inMemory :: Parser Bool
inMemory = switch (long "in-memory" <> help "WARNING: potential data loss")

-- | initializes the database with the necessary parameters. If not file path is given, the default name "vdiff.db" is used.
withDiffDB :: FilePath -> (SQL.Connection -> IO a) -> IO a
withDiffDB fn act = do
  conn <- liftIO $ SQL.open fn
  -- migrate / create schema
  retryOnBusy $ runBeamSqlite conn migrateVdiff
  -- create indices
  createIndices conn
  x <- act conn
  SQL.close conn
  return x


restoreDb :: (HasMainEnv env) => Text -> RIO env ()
restoreDb srcFn = do
  srcDb <- liftIO $ Sqlite3.open srcFn
  dstDb <- SQL.connectionHandle <$> view databaseL
  transferDb srcDb dstDb
  logInfo $ "load from " <> display srcFn <> " into in-memory Db complete"

backupDb :: (HasMainEnv env) => Text -> RIO env ()
backupDb dstFn = do
  srcDb <- SQL.connectionHandle <$> view databaseL
  dstDb <- liftIO $ Sqlite3.open dstFn
  transferDb srcDb dstDb


transferDb :: (HasMainEnv env) => Sqlite3.Database -> Sqlite3.Database -> RIO env ()
transferDb srcDb dstDb = do
  bkp <- liftIO $ Sqlite3.backupInit dstDb "main" srcDb "main"
  res <- liftIO $ Sqlite3.backupStep bkp (-1)
  case res of
    Sqlite3.BackupDone -> liftIO $ Sqlite3.backupFinish bkp
    Sqlite3.BackupOK   -> logError "backup/restore not completed"

createIndices :: SQL.Connection -> IO ()
createIndices conn = do
  SQL.execute_ conn "CREATE INDEX IF NOT EXISTS `runs_code_hash_idx` ON `runs` (`code_hash`);"
  SQL.execute_ conn "CREATE INDEX IF NOT EXISTS `runs_verifier_name_idx` ON `runs` (`verifier_name`);"
  SQL.execute_ conn "CREATE INDEX IF NOT EXISTS `runs_verifier_name_result_idx` ON `runs` (`verifier_name`, `result`);"
  SQL.execute_ conn "CREATE INDEX IF NOT EXISTS `tmp_counts_run_id_idx` ON `tmp_counts` (`run_id`);"
