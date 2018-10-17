{-# LANGUAGE OverloadedStrings #-}

module Main where


import           ADiff.Arguments
import           ADiff.Data
import           ADiff.Persistence
import qualified Control.Concurrent.MSemN              as Sema
import qualified Data.Map                              as Map
import qualified Network.Wai.Handler.Warp              as Warp
import           Network.Wai.Middleware.StaticEmbedded
import           System.IO
import           Web.Scotty.Trans

import           ADiff.Application
import           ADiff.Server.Controller
import           ADiff.Server.Prelude

import qualified ADiff.Query2                          as Q2

data ServerParameters = ServerParameters
  { port                   :: Int
  , hostPref               :: Warp.HostPreference
  , forceRecount           :: Bool
  , maxConcurrentVerifiers :: Int
  }


parseServerParameters :: Parser ServerParameters
parseServerParameters = ServerParameters <$> port <*> host <*> switchForceRecount <*> maxConcurrent
  where
    port = option auto (short 'p' <> long "port" <> value 8080)
    switchForceRecount = switch (long "force-recount" <> help "re-calculates the temporary table that contains all counts of sats/unsats")
    maxConcurrent = option auto (short 'n' <> long "max-concurrent-verifiers" <> value 1)
    host = option str (long "host" <> value "*")


infos = progDesc "runs a webserver to inspect adiff results"

main :: IO ()
main = runADiffApp parseServerParameters infos $ \sp -> do
  logInfo "starting adiff-server"
  sema <- liftIO $ Sema.new (maxConcurrentVerifiers sp)
  env <- mkServerEnv sema

  -- clean up DB (this is important for the correctness of consensus)
  -- Q2.cleanUp -- TODO: Re-enable

  -- drop temporary entries
  when (forceRecount sp) Q2.cleanTemporary

  -- start server
  let opts = Options 1 (Warp.setHost (hostPref sp) Warp.defaultSettings)
  scottyOptsT opts (runRIO env) endpoints


mkServerEnv :: Sema.MSemN Int -> RIO MainEnv ServerEnv
mkServerEnv s = do
  menv <- ask
  tables <- newIORef Map.empty
  return $ ServerEnv menv s tables
