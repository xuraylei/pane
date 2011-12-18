module FlowController where

import Set (Set)
import qualified Set
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Tree
import Tree (Tree)
import qualified PriorityQueue as PQ
import PriorityQueue (PQ)
import Data.Maybe (maybe, mapMaybe, fromMaybe)
import Base
import TokenBucket (TokenBucket)
import qualified TokenBucket as TB

data Share = Share {
  shareName :: ShareRef,       -- ^must match name in the 'ShareTree'
  shareFlows :: FlowGroup,     -- set of flows in this share
  shareHolders :: Set Speaker, -- users who can speak about this share
  shareReq :: PQ Req,          -- queue of accepted requests, sort by start
--  shareStart :: Integer, -- invariant: start < end
--  shareEnd :: Limit,  TODO (?)

  -- Restrictions on what this share can be used for
  shareResvUB :: Limit,
  shareResvLB :: Limit,
  shareCanAllowFlows :: Bool,
  shareCanDenyFlows :: Bool,
  -- |'shareResvTokens' throttles the frequency of reservations. For a reservation
  -- of 'm' units of bandwidth for 'n' units of time, we consume 'm * n' tokens.
  shareResvTokens :: TokenBucket
} deriving (Show)

type ShareTree = Tree ShareRef Share


data State = State {
  shareTree :: ShareTree,
  stateSpeakers :: Set String,
  acceptedReqs :: PQ Req,
  activeReqs :: PQ Req,
  stateNow :: Integer
} deriving Show

-----------------------------
-- Useful defined variables
-----------------------------

anyFlow = FlowGroup Set.all Set.all Set.all Set.all

rootSpeaker :: String
rootSpeaker = "root"

rootShareRef :: ShareRef
rootShareRef = "rootShare"

emptyShareReq = PQ.empty reqStartOrder

emptyState = 
  State (Tree.root 
           rootShareRef
           (Share rootShareRef anyFlow (Set.singleton rootSpeaker) emptyShareReq
                   NoLimit (DiscreteLimit 0) True True TB.unlimited))
        (Set.singleton rootSpeaker)
        (PQ.empty reqStartOrder)
        (PQ.empty reqEndOrder)
        0
        

-----------------------------
-- Helper Functions
-----------------------------

reqStartOrder :: Req -> Req -> Bool
reqStartOrder req1 req2 = reqStart req1 <= reqStart req2

reqEndOrder :: Req -> Req -> Bool
reqEndOrder req1 req2 = reqEnd req1 <= reqEnd req2

isResv :: Req -> Bool
isResv req =
  case (reqData req) of
    (ReqResv _) -> True
    otherwise -> False

isAllow :: Req -> Bool
isAllow req =
  case (reqData req) of
    ReqAllow -> True
    otherwise -> False

isDeny :: Req -> Bool
isDeny req =
  case (reqData req) of
    ReqDeny -> True
    otherwise -> False

isAdmControl :: Req -> Bool
isAdmControl req = (isAllow req) || (isDeny req)

reqDepth :: Req -> State -> Int
reqDepth req state =
  Tree.depth (reqShare req) (shareTree state)

unReqResv :: ReqData -> Maybe Integer
unReqResv rd =
  case rd of
    (ReqResv n) -> (Just n)
    otherwise -> Nothing

isSubFlow :: FlowGroup -> FlowGroup -> Bool
isSubFlow (FlowGroup fs1 fr1 fsp1 fdp1) (FlowGroup fs2 fr2 fsp2 fdp2) =
  Set.isSubsetOf fs1 fs2 &&
  Set.isSubsetOf fr1 fr2 &&
  Set.isSubsetOf fsp1 fsp2 &&
  Set.isSubsetOf fdp1 fdp2

isIntersectingFlow :: FlowGroup -> FlowGroup -> Bool
isIntersectingFlow (FlowGroup fs1 fr1 fsp1 fdp1) (FlowGroup fs2 fr2 fsp2 fdp2) =
  not (Set.null (Set.intersection fs1 fs2)) &&
  not (Set.null (Set.intersection fr1 fr2)) &&
  not (Set.null (Set.intersection fsp1 fsp2)) &&
  not (Set.null (Set.intersection fdp1 fdp2))

isSubShare :: Share -> Share -> Bool
isSubShare (Share _ flows1 _ _ resUB1 resLB1 canAllow1 canDeny1 _)
          (Share _ flows2 _ _ resUB2 resLB2 canAllow2 canDeny2 _) = 
  resUB1 <= resUB2 &&
  resLB1 >= resLB2 &&
  flows1 `isSubFlow` flows2 &&
  canAllow1 <= canAllow2 &&
  canDeny1 <= canDeny2

isSubShareWRefs :: ShareRef -> ShareRef -> ShareTree -> Bool
isSubShareWRefs sr1 sr2 sT =
  let s1 = Tree.lookup sr1 sT
      s2 = Tree.lookup sr2 sT in
    isSubShare s1 s2

-----------------------------
-- API Functions
-----------------------------

createSpeaker :: Speaker -- ^name of new speaker
              -> State -- ^existing state
              -> Maybe State
createSpeaker newSpeaker st@(State {stateSpeakers=spk})  =
  if Set.exists (==newSpeaker) spk then
    Nothing
  else
    Just (st { stateSpeakers = Set.insert newSpeaker spk })

giveReference :: Speaker -- ^grantor
              -> ShareRef -- ^reference to share
              -> Speaker -- ^acceptor
              -> State -- ^existing state
              -> Maybe State
giveReference from ref to st@(State {shareTree=sT, stateSpeakers=refs}) = 
  if not (Set.member from refs) || not (Set.member to refs) ||
     not (Tree.member ref sT) then
    Nothing
  else
    let share = Tree.lookup ref sT
      in case from `Set.member` shareHolders share of
        True -> 
          let share' = share {shareHolders = Set.insert to (shareHolders share)}
              sT' = Tree.update ref share' sT
            in Just (st {shareTree = sT'})
        False -> Nothing

giveDefaultReference :: Speaker -- ^grantor
                     -> ShareRef -- ^reference to share
                     -> State -- ^existing state
                     -> Maybe State
giveDefaultReference from ref st@(State {shareTree=sT, stateSpeakers=refs}) = 
  if not (Set.member from refs) then
    Nothing
  else
    let share = Tree.lookup ref sT 
      in case from `Set.member` shareHolders share of
        True -> 
          let share' = share {shareHolders = Set.all}
              sT' = Tree.update ref share' sT
            in Just (st {shareTree = sT'})
        False -> Nothing

newShare :: Speaker
           -> ShareRef
           -> Share
           -> State
           -> Maybe State
newShare spk parentName newShare@(Share { shareName = shareName })
           st@(State {shareTree = sT}) =
  if Tree.member parentName sT then
    let parentShare = Tree.lookup parentName sT
      in case Set.member spk (shareHolders parentShare) of
        True -> case newShare `isSubShare` parentShare of
                  True -> 
                    Just (st { shareTree =
                             (Tree.insert shareName newShare parentName sT) } )
                  False -> Nothing
        False -> Nothing
  else
    Nothing

injLimit n = DiscreteLimit n

simulate :: PQ Req -- ^ sorted by start time
         -> TokenBucket
         -> Integer -- ^ simulation starting time
         -> Req    -- ^ the new request which is being considered
         -> [(Limit, Integer, TokenBucket)] -- ^time, height of resv bw, TB
simulate reqsByStart shareTB trueNow newR =
  simStep (injLimit trueNow) 0 shareTB reqsByStart (PQ.empty reqEndOrder) newR where 
    simStep now size tb byStart byEnd newReq
      | PQ.isEmpty byStart && PQ.isEmpty byEnd = []
      | otherwise =
      let now' = min (maybe NoLimit (injLimit.reqStart) (PQ.peek byStart))
                    (maybe NoLimit reqEnd (PQ.peek byEnd))
          (startingNow, byStart') = PQ.dequeueWhile (\r ->
                                           (injLimit.reqStart) r == now')
                                        byStart
          (endingNow, byEnd') = PQ.dequeueWhile (\r -> reqEnd r == now')
                                      byEnd
          byEnd'' = foldr PQ.enqueue byEnd' startingNow
          bwDelta = sum (mapMaybe (unReqResv.reqData) startingNow)
                  - sum (mapMaybe (unReqResv.reqData) endingNow)
          size' = size + bwDelta
          tb'   = case (now' > (DiscreteLimit trueNow)) of
                    True -> TB.updateRate (-bwDelta) (TB.tickLim
                                                      (now' `subLimits` now) tb)
                    -- Be careful not to simulate events which occurred:
                    False  -> case (injLimit (reqStart newReq) == now') of
                                True -> TB.updateRate (-bwDelta') tb where
                                          bwDelta' = fromMaybe 0 (unReqResv
                                                       (reqData newReq))
                                False -> tb
          in (now', size', tb'):(simStep now' size' tb' byStart' byEnd'' newReq)


-- TODO: needs to be more general so it can be used for any resource which
-- needs to be checked up the tree (eg, latency, rate-limit, etc.)
recursiveRequest :: Req
                 -> State
                 -> Maybe State
recursiveRequest req@(Req shareRef _ start end (ReqResv resv) _) -- TODO: specific
                 st@(State {shareTree = sT, acceptedReqs = accepted }) =
  let chain = Tree.chain shareRef sT
      f Nothing _ = Nothing
      f (Just sT) (thisShareName, thisShare@(Share {shareReq=reqs})) = 
        let g req'@(Req { reqStart = start', reqEnd = end' }) =
                 (isResv req && isResv req') && -- TODO: generalize in future 
                 not (end' < (DiscreteLimit start) ||
                      (DiscreteLimit start') > end)
            simReqs = PQ.enqueue req (PQ.filter g reqs)
            (_, sizes, tbs) = unzip3 (simulate simReqs (shareResvTokens thisShare)
                                      (stateNow st) req) in
-- TODO: these next lines are the specific tests for reservations, rather than
-- any type of request
          if (injLimit (maximum sizes) > shareResvUB thisShare) ||
               (injLimit resv < shareResvLB thisShare) ||
               (minimum (map TB.currTokens tbs) < injLimit (0)) then
            Nothing
          else
            let thisShare' = thisShare { shareReq = PQ.enqueue req reqs } in
                Just (Tree.update thisShareName thisShare' sT)
    in case foldl f (Just sT) chain of
         Nothing -> Nothing
         Just sT' -> 
           Just (tick 0 (st { shareTree = sT',
                      acceptedReqs = PQ.enqueue req accepted }))

-- For resources which only need to be checked in their share (not up the tree)
localRequest :: Req
             -> State
             -> Maybe State
localRequest req@(Req shareRef _ _ _ _ _)
             st@(State {shareTree = sT, acceptedReqs = accepted }) =
  let share = Tree.lookup shareRef sT in
    if (isAllow req && shareCanAllowFlows share) ||
       (isDeny req && shareCanDenyFlows share)
      then
        let share' = share { shareReq = PQ.enqueue req (shareReq share) }
            sT' = Tree.update shareRef share sT
          in Just (tick 0 (st { shareTree = sT',
                                acceptedReqs = PQ.enqueue req accepted }))
      else
        Nothing

-- For strict application of allow/deny: 1) check if any existing admission 
-- control statements in non-parent shares apply 2) if none do, then it is
-- ok to proceed to local request
strictAdmControl :: Req
                 -> State
                 -> Maybe State
strictAdmControl req@(Req shareRef flow _ _ _ _)
                 st@(State {shareTree = sT }) =
  let isNonParent (Req sR' _ _ _ _ _) =
        -- the only shares that should return false are parents of shareRef
        not (isSubShareWRefs shareRef sR' sT) -- || shareRef == sR'
  in case filter (\x -> isNonParent x && isAdmControl x && 
                        -- only care if allow blocked by deny, and vice versa
                        ((reqData req) /= (reqData x)))
                 (findReqByIntersectingFG flow st) of
    [] -> localRequest req st
    _ -> Nothing -- TODO: Return why strict failed


-- TODO: Make more general so it can be used in three functions:
-- 1) IsAvailable  2)  HoldIfAvailable  3) RequestIfAvailable (existing use)
request :: Speaker
        -> Req
        -> State
        -> Maybe State
request spk req@(Req shareRef flow start end rD strict)
        st@(State {shareTree = sT,
                   acceptedReqs = accepted }) =
  if Tree.member shareRef sT then
    let share = Tree.lookup shareRef sT
      in case Set.member spk (shareHolders share) && 
               flow `isSubFlow` (shareFlows share) &&
               start >= (stateNow st) &&
               (DiscreteLimit start) < end of
        False -> Nothing
        True -> case strict of
                  True -> case rD of
                             -- TODO: need to send reason why if request rejected
                             (ReqResv _) -> recursiveRequest req st
                             ReqAllow -> strictAdmControl req st
                             ReqDeny -> strictAdmControl req st
                  False -> case rD of
                             -- TODO: need to send explanation of what happened
                             ReqAllow -> localRequest req st
                             ReqDeny -> localRequest req st
                             _ -> error "FAIL. PARTIAL RESERVE UNIMPLEMENTED."
  else
    Nothing

tickShare :: Integer -> [Req] -> [Req] -> Share -> Share
tickShare t starting ending share@(Share { shareResvTokens = resvToks }) =
  share { shareResvTokens = resvToks'' } where
    resvToks'  = TB.tick t resvToks
    starting'  = filter (\x -> reqShare x == shareName share) starting
    ending'    = filter (\x -> reqShare x == shareName share) ending
    resvToks'' = TB.updateRate (sum (mapMaybe (unReqResv.reqData) ending')
                              - sum (mapMaybe (unReqResv.reqData) starting'))
                              resvToks'

-- Starting & ending reservations now have a side-effect on the
-- token buckets, so we need to execute each start and end event at
-- the appropriate time
tick :: Integer -> State -> State
tick 0 st = tickInternal 0 st 
tick 1 st = tickInternal 1 st
tick t st = tick (t - nextEvent) (tickInternal nextEvent st) where
  byStart   = acceptedReqs st
  byEnd     = activeReqs st
  nextEvent = case min (maybe NoLimit (injLimit.reqStart) (PQ.peek byStart))
                       (maybe NoLimit reqEnd (PQ.peek byEnd)) of
                DiscreteLimit n -> (n - stateNow st)
                NoLimit -> t

tickInternal :: Integer -> State -> State
tickInternal t st@(State { shareTree    = shares,
                   acceptedReqs = byStart,
                   activeReqs   = byEnd, 
                   stateNow     = now }) =
  st { acceptedReqs = byStart',
       activeReqs   = byEnd'',
       stateNow     = now',
       shareTree = fmap (tickShare t startingNow endingNow) shares
     } 
  where now' = now + t
        (startingNow, byStart') =  PQ.dequeueWhile (\r -> reqStart r <= now')
                                       byStart
        (endingNow, byEnd') = PQ.dequeueWhile (\r -> reqEnd r
                                       <= (injLimit now'))
                                       byEnd
-- TODO: We should delete the endingNow reservations from the shareTree (optimization)
-- TODO: After we can delete reservations, make it possible to delete shares
        byEnd'' = foldr PQ.enqueue byEnd' startingNow

currentRequests = PQ.toList.activeReqs

-----------------------------
-- Query Functions
-----------------------------

findSharesByFlowGroup :: FlowGroup -> State -> [(ShareRef, Share)]
findSharesByFlowGroup fg st@(State {shareTree=sT}) =
  findInTree fg (rootShareRef, (Tree.lookup rootShareRef sT)) sT where
    findInTree flow (shareRef, share) tr = 
      let next = (foldl (++) [] (map (\x -> findInTree flow x tr)
                                  (Tree.children shareRef tr)))
        in case fg `isSubFlow` (shareFlows share) of
          False -> [] -- skip the children b/c tree constructed with isSubFlow
          True -> (shareRef, share):next

findSharesByUser :: User -> State -> [(ShareRef, Share)]
findSharesByUser user st@(State {shareTree=sT}) =
  findInTree user (rootShareRef, (Tree.lookup rootShareRef sT)) sT where
    findInTree holder (shareRef, share) tr = 
      let next = (foldl (++) [] (map (\x -> findInTree holder x tr)
                                  (Tree.children shareRef tr)))
        in case Set.member holder (shareHolders share) of
          False -> next -- we want recursive descent when checking for users
          True -> (shareRef, share):next

findReqByFlowGroup :: FlowGroup -> State -> [Req]
findReqByFlowGroup fg st@(State {acceptedReqs=accepted,activeReqs=active}) =
  PQ.toList (PQ.filter (\x -> fg `isSubFlow` (reqFlows x)) active) ++
    PQ.toList (PQ.filter (\x -> fg `isSubFlow` (reqFlows x)) accepted)

findReqWithSubFlow :: FlowGroup -> State -> [Req]
findReqWithSubFlow fg st@(State {acceptedReqs=accepted,activeReqs=active}) =
  PQ.toList (PQ.filter (\x -> (reqFlows x) `isSubFlow` fg) active) ++
    PQ.toList (PQ.filter (\x -> (reqFlows x) `isSubFlow` fg) accepted)

findReqByIntersectingFG :: FlowGroup -> State -> [Req]
findReqByIntersectingFG fg st@(State {acceptedReqs=accepted,activeReqs=active}) =
  PQ.toList (PQ.filter (\x -> fg `isIntersectingFlow` (reqFlows x)) active) ++
    PQ.toList (PQ.filter (\x -> fg `isIntersectingFlow` (reqFlows x)) accepted)
