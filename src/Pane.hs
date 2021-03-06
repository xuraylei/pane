module Pane
  ( paneMgr
  ) where

import Parser
import Base
import ShareTreeLang
import ShareTree
import Control.Monad
import HFT
import Control.Monad.State

paneMgr :: Chan (Speaker, Integer, String) -- ^commands from speaker
        -> Chan Integer           -- ^current time (ticks from timeService)
        -> IO (Chan MatchTable, Chan (Speaker, Integer, String))
paneMgr reqChan tickChan = do
  tblChan <- newChan
  respChan <- newChan
  stRef <- newIORef emptyState
  let handleReq = do
        (spk, clientId, req) <- readChan reqChan
        paneM <- parseFromString spk req
        st <- readIORef stRef
-- TODO(adf): WTF? for correctness, we should compile again. (equiv of "tick 0")
        (resp, st') <- runStateT paneM st
        case resp of
          BoolResult True -> do
            writeIORef stRef st'
            writeChan respChan (spk, clientId, show resp)
          otherwise -> do
            writeChan respChan (spk, clientId, show resp)
      buildTbl = do
        now <- readChan tickChan
        st <- readIORef stRef
        let removeEndingNow sh = sh { shareReq = req }
              where req = filter
                            (\r -> reqEnd r > fromInteger now)
                            (shareReq sh)
        writeIORef stRef (st { shareTree = fmap removeEndingNow (shareTree st),
                               stateNow = now })
        writeChan tblChan (compileShareTree now (getShareTree st))
  forkIO (forever handleReq)
  forkIO (forever buildTbl)
  return (tblChan, respChan)
