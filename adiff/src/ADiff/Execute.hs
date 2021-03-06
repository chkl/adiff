-- MIT License
--
-- Copyright (c) 2018 Christian Klinger
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE InstanceSigs           #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TemplateHaskell        #-}

module ADiff.Execute
  ( executeVerifier
  , executeVerifierInDocker
  , MemoryConstraint(..)
  , MemoryConstraintSize
  -- * Execution package
  , ExecutionPackage(..)
  , packageVerifierName
  , verifierExtraFlags
  , inputFile
  ) where

import           Docker.Client       as Docker

import qualified Data.Text           as T
import qualified Data.Text.IO        as T
import           UnliftIO.Concurrent
import           ADiff.Data
import           ADiff.Prelude

-- | An instance of this data type is serialized on the host side, passed to the
-- docker container as a file and deseralized by an instance of adiff that runs
-- inside of the container.
data ExecutionPackage
  = ExecutionPackage
  { _packageVerifierName :: VerifierName
  , _verifierExtraFlags  :: [Text]
  , _timelimit           :: Timelimit
  , _inputFile           :: Text
  } deriving (Show, Read)


executeVerifier :: Verifier -> FilePath -> RIO VerifierEnv VerifierResult
executeVerifier v fp = try (_verifierExecute v fp) >>= \case
  Left (e :: IOException) -> do
    logWarn $ "verifier " <> display (_name v) <> " just caused an IO exception: " <> display (tshow $ displayException e)
    return $ VerifierResult Nothing Nothing Unknown
  Right res -> return res


instance MonadUnliftIO (DockerT IO) where
  withRunInIO :: ((forall a. DockerT IO a -> IO a) -> IO b) -> DockerT IO b
  withRunInIO inner = do
    env <- ask
    liftIO $ inner $ runDockerT env


executeVerifierInDocker :: (HasLogFunc env) => VerifierResources -> VerifierName -> [Text] -> Text -> RIO env VerifierResult
executeVerifierInDocker resources vn flags source = do
  let pkgS = T.pack $ show $ ExecutionPackage vn flags (resources ^. timelimit) source -- TODO: Handle Flags
  h <- liftIO $ unixHttpHandler "/var/run/docker.sock"
  withSystemTempDirectory "exchange" $ \dirPath -> do
      -- serialize the package and write it into a temporary file
      writeFileUtf8 (dirPath <> "/package") pkgS
      writeFileUtf8 (dirPath <> "/output") ""  -- just to make sure that it is a file and not a directory

      -- prepare a few functions to be used in pure IO
      u <- askUnliftIO
      let logWarnIO = liftIO . unliftIO u . logWarn :: Utf8Builder -> IO ()
      let logInfoIO = liftIO . unliftIO u . logInfo :: Utf8Builder -> IO ()

      liftIO $ runDockerT (defaultClientOpts, h) $ do
        -- create container
        let cops  = mkCreateOpts resources dirPath
        cid <- createContainer cops Nothing
        case cid of
          Left err -> error $ "could not create container, error: " ++ show err
          Right i -> do
            (resultVar :: MVar (Maybe VerifierResult)) <- newEmptyMVar
            -- one thread for the container
            t_container <- forkIO $ do
              startContainer defaultStartOpts i
              liftIO $ logInfoIO $ "started container " <> display i <> " for verifier " <> display vn
              waitContainer i >>= \case
                Right ExitSuccess  -> do
                  runOutput <- readFileUtf8 (dirPath <> "/output")
                  putMVar resultVar (readMay $ T.unpack runOutput)
                Right (ExitFailure 137) ->
                  liftIO $ logInfoIO "docker container was killed using SIGKILL (what a stubborn process!)"
                Right (ExitFailure err) -> do
                  liftIO $ logWarnIO $ "internal adiff exited with status code (could  be due to OOM): " <> display err
                  putMVar resultVar Nothing
                Left dockerErr -> putMVar resultVar Nothing

            -- one thread for the timer
            t_timer <- forkIO $ do
              threadDelay (microseconds $ resources ^. timelimit)
              putMVar resultVar Nothing
            -- wait until at least one of the threads has completed
            result <- takeMVar resultVar
            case result of
              Nothing -> return $ VerifierResult Nothing Nothing Unknown
              Just r  -> return r
            `finally` do
              liftIO $ logInfoIO $ "deleting container " <> display i
              deleteContainer (defaultDeleteOpts { Docker.force = True}) i

mkCreateOpts :: VerifierResources -> FilePath -> CreateOpts
mkCreateOpts simpleConstraints dirPath =
  (defaultCreateOpts "adiff/adiff:latest")
  { containerConfig = (defaultContainerConfig "adiff/adiff:latest")
                      { env = [EnvVar "PATH" "/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
                      , cmd = ["/root/.local/bin/adiff-run-package", "/exchange/package", "/exchange/output"]
                      }
  , hostConfig = defaultHostConfig
                 { binds = [Bind (T.pack dirPath) "/exchange" Nothing]
                 , resources =  defaultContainerResources
                                { memorySwap    = _memory simpleConstraints
                                , Docker.memory = _memory simpleConstraints
                                , cpusetCpus    = _cpus simpleConstraints
                                }
                 , logConfig = LogDriverConfig JsonFile []
                 }
  }

makeFieldsNoPrefix ''ExecutionPackage
