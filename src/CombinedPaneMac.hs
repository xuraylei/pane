module CombinedPaneMac where

import Base
import HFT
import qualified Nettle.OpenFlow as OF
import MacLearning
import Pane
import qualified Flows

-- | switch arrivals (true) and departures (false)
-- timestamped packetIn messages
-- PANE requests from speakers
-- timeService
-- outputs:
-- channel of Network Flow Tables
-- channel of PANE responses to speakers
-- OpenFlow packetOut messages
combinedPaneMac :: Chan (OF.SwitchID, Bool) 
                -> Chan (OF.TransactionID, Integer, OF.SwitchID, OF.PacketInfo)
                -> Chan (Speaker, Integer, String)
                -> Chan Integer
                -> IO (Chan MatchTable, Chan (Speaker, Integer, String), PacketOutChan)
combinedPaneMac switch packetIn paneReq tickChan = do
  (paneTbl, paneResp) <- paneMgr paneReq tickChan
  (macLearnedTbl, pktOutChan) <- macLearning switch packetIn
  let cmb pt mt = do
        now <- readIORef sysTime
        return $ condense now (pt `concatTable` mt)
  combinedTbl <- liftChan cmb (emptyTable, paneTbl) (emptyTable, macLearnedTbl)
  return (combinedTbl, paneResp, pktOutChan)
