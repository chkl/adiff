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

{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TupleSections         #-}

-- similar to Query but slightly more high-level
module ADiff.Statistics where

import           Data.List            (intersperse)
import qualified Data.Map             as Map
import           Database.Beam
import           Database.Beam.Sqlite
import Data.Maybe (fromJust)
import           ADiff.Data
import           ADiff.Persistence
import           ADiff.Prelude
import           ADiff.Query2         as Q2
import           ADiff.Util.Tables
import           ADiff.Verifier


verdicts :: (HasDatabase env, HasLogFunc env) => Maybe [VerifierName] -> RIO env (Int, Int, Int)
verdicts qf = do
  vs <- runBeam $ runSelectReturningList $ select $ agg $ flt allRuns_
  let sats    = fromMaybe 0 $ lookup Sat vs
  let unsats  = fromMaybe 0 $ lookup Unsat vs
  let unknown = fromMaybe 0 $ lookup Unknown vs
  return (sats, unsats, unknown)
 where
   flt = case qf of
           Nothing -> filter_ ( const $ val_ True)
           Just vs -> filter_ (\r  -> (r ^. verifierName) `in_` map val_ vs)
   agg = aggregate_ $ \r -> (group_ (r ^. (result . verdict)), countAll_)



relative :: (HasDatabase env, HasLogFunc env)
  => Verdict
  -> Bool
  -> Relatee
  -> Relatee
  -> RIO env (Integer, Integer)
relative vrd allowUnknown v1 v2 = do
  (Just intersection) <- runProgramByVerdicts [ (v1, vrd : [Unknown | allowUnknown]), (v2, [vrd]) ]
  (Just totalV2) <-      runProgramByVerdicts [ (v1, [Sat, Unsat, Unknown])         , (v2, [vrd]) ]
  return (fromIntegral intersection,  fromIntegral totalV2)
  where
    runProgramByVerdicts = runBeam . runSelectReturningOne . select . aggregate_ (const countAll_) . programByVerdicts


relativeSoundness, relativeCompleteness, relativeRecall, relativePrecision
  :: (HasDatabase env, HasLogFunc env) => Relatee -> Relatee -> RIO env (Integer, Integer)

relativeSoundness    = relative Sat True
relativeCompleteness = relative Unsat True
relativeRecall       = relative Sat False
relativePrecision    = relative Unsat False

type RelativeTable = Map (Relatee, Relatee) (Integer, Integer)


getBinaryComparison :: (HasDatabase env, HasLogFunc env) => Relatee -> Relatee -> RIO env (Int, Map (Verdict, Verdict) Int)
getBinaryComparison r1 r2 = do
  -- find the number of programs for which we have runs of both r1 and r2
  bigN <- runCount $ programByVerdicts [(r1, allVerdicts), (r2, allVerdicts)]
  pairs <- forM [(vrd1, vrd2) | vrd1 <- allVerdicts, vrd2 <- allVerdicts] $ \(vrd1, vrd2) -> do
    n <- runCount $ programByVerdicts [(r1, [vrd1]), (r2, [vrd2])]
    return ((vrd1, vrd2), n)
  return (bigN, Map.fromList pairs)
  where
    allVerdicts = [Sat, Unsat, Unknown]
    runCount = fmap fromJust . runBeam . runSelectReturningOne . select . aggregate_ (const countAll_)

--------------------------------------------------------------------------------

overPairs :: (HasDatabase env, HasLogFunc env) => (Relatee -> Relatee -> RIO env (Integer,Integer)) -> RIO env RelativeTable
overPairs f = do
  (vns :: [Relatee]) <- map RelateName <$> Q2.getVerifierNames
  Map.fromList <$> sequence [ ((v1, v2),) <$> f v1 v2 | v1 <- vns , v2 <- vns]

overPairsWithConsensus :: (HasDatabase env, HasLogFunc env) => Weights -> (Relatee -> Relatee -> RIO env (Integer,Integer)) -> RIO env RelativeTable
overPairsWithConsensus consensusModel f = do
  Q2.ensureConsensusExists consensusModel
  vns <- Q2.getVerifierNames
  let rels = ConsensusBy consensusModel : [RelateName v | v <- vns]
  Map.fromList <$> sequence [ ((v1, v2),) <$> f v1 v2 | v1 <- rels, v2 <- rels ]

