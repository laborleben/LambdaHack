-- | Server operations performed periodically in the game loop
-- and related operations.
module Game.LambdaHack.Server.PeriodicServer
  ( spawnMonsters, generateMonster, addMonster, addHero
  , advanceTime, regenerateLevelHP, leadLevelFlip
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import Data.Text (Text)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State
import Game.LambdaHack.Utils.Frequency

-- | Spawn non-hero actors of any faction, friendly or not.
-- To be used for initial dungeon population, spontaneous spawning
-- of monsters and for the summon effect.
spawnMonsters :: (MonadAtomic m, MonadServer m)
              => [Point] -> LevelId -> Time -> FactionId
              -> m ()
spawnMonsters ps lid time fid = assert (not $ null ps) $ do
  Kind.COps{coactor=Kind.Ops{opick}, cofaction=Kind.Ops{okind}} <- getsState scops
  fact <- getsState $ (EM.! fid) . sfactionD
  let spawnName = fname $ okind $ gkind fact
  laid <- forM ps $ \ p -> do
    mk <- rndToAction $ fmap (fromMaybe $ assert `failure` spawnName)
                        $ opick spawnName (const True)
    addMonster mk fid p lid time
  mleader <- getsState $ gleader . (EM.! fid) . sfactionD  -- just changed
  when (isNothing mleader) $
    execUpdAtomic $ UpdLeadFaction fid Nothing (Just $ head laid)

-- | Generate a monster, possibly.
generateMonster :: (MonadAtomic m, MonadServer m) => LevelId -> m ()
generateMonster lid = do
  cops <- getsState scops
  pers <- getsServer sper
  lvl@Level{ldepth} <- getLevel lid
  s <- getState
  let f fid = isSpawnFaction fid s
      spawns = actorNotProjList f lid s
  depth <- getsState sdepth
  rc <- rndToAction $ monsterGenChance ldepth depth (length spawns)
  factionD <- getsState sfactionD
  when rc $ do
    time <- getsState $ getLocalTime lid
    let freq = toFreq "spawn"
               $ map (\(fid, fact) -> (playerSpawn $ gplayer fact, fid))
               $ EM.assocs factionD
    mfid <- if nullFreq freq then
              return Nothing
            else fmap Just $ rndToAction $ frequency freq
    case mfid of
      Nothing -> return ()  -- no faction spawns
      Just fid -> do
        let allPers = ES.unions $ map (totalVisible . (EM.! lid))
                      $ EM.elems $ EM.delete fid pers  -- expensive :(
        pos <- rndToAction $ rollSpawnPos cops allPers lid lvl fid s
        spawnMonsters [pos] lid time fid

-- | Create a new monster on the level, at a given position
-- and with a given actor kind and HP.
addMonster :: (MonadAtomic m, MonadServer m)
           => Kind.Id ActorKind -> FactionId -> Point -> LevelId -> Time
           -> m ActorId
addMonster mk bfid ppos lid time = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  let kind = okind mk
  hp <- rndToAction $ castDice $ ahp kind
  calm <- rndToAction $ castDice $ acalm kind
  addActor mk bfid ppos lid hp calm (asymbol kind) (aname kind)
           (acolor kind) time

-- | Create a new hero on the current level, close to the given position.
addHero :: (MonadAtomic m, MonadServer m)
        => FactionId -> Point -> LevelId -> [(Int, Text)] -> Maybe Int -> Time
        -> m ActorId
addHero bfid ppos lid heroNames mNumber time = do
  Kind.COps{coactor=coactor@Kind.Ops{okind}} <- getsState scops
  Faction{gcolor, gplayer} <- getsState $ (EM.! bfid) . sfactionD
  let kId = heroKindId coactor
  hp <- rndToAction $ castDice $ ahp $ okind kId
  calm <- rndToAction $ castDice $ acalm $ okind kId
  mhs <- mapM (\n -> getsState $ \s -> tryFindHeroK s bfid n) [0..9]
  let freeHeroK = elemIndex Nothing mhs
      n = fromMaybe (fromMaybe 100 freeHeroK) mNumber
      symbol = if n < 1 || n > 9 then '@' else Char.intToDigit n
      nameFromNumber 0 = "Captain"
      nameFromNumber k = "Hero" <+> tshow k
      name | gcolor == Color.BrWhite =
        fromMaybe (nameFromNumber n) $ lookup n heroNames
           | otherwise =
        playerName gplayer <+> nameFromNumber n
      startHP = hp - (min 10 $ hp `div` 10) * min 5 n
  addActor kId bfid ppos lid startHP calm symbol name gcolor time

addActor :: (MonadAtomic m, MonadServer m)
         => Kind.Id ActorKind -> FactionId -> Point -> LevelId -> Int -> Int
         -> Char -> Text -> Color.Color -> Time
         -> m ActorId
addActor mk bfid pos lid hp calm bsymbol bname bcolor time = do
  Kind.COps{coactor=coactor@Kind.Ops{okind}} <- getsState scops
  Faction{gplayer} <- getsState $ (EM.! bfid) . sfactionD
  DebugModeSer{sdifficultySer} <- getsServer sdebugSer
  nU <- nUI
  -- If no UI factions, the difficulty applies to heroes (for testing).
  let diffHP | playerUI gplayer || nU == 0 && mk == heroKindId coactor =
        (ceiling :: Double -> Int) $ fromIntegral hp
                                     * 1.5 ^^ difficultyCoeff sdifficultySer
             | otherwise = hp
      kind = okind mk
      speed = aspeed kind
      m = actorTemplate mk bsymbol bname bcolor speed diffHP calm
                        Nothing pos lid time bfid False
  acounter <- getsServer sacounter
  modifyServer $ \ser -> ser {sacounter = succ acounter}
  execUpdAtomic $ UpdCreateActor acounter m []
  return $! acounter

rollSpawnPos :: Kind.COps -> ES.EnumSet Point
             -> LevelId -> Level -> FactionId -> State
             -> Rnd Point
rollSpawnPos Kind.COps{cotile} visible
             lid Level{ltile, lxsize, lysize} fid s = do
  let factionDist = max lxsize lysize - 5
      inhabitants = actorNotProjList (/= fid) lid s
      as = actorList (const True) lid s
      isLit = Tile.isLit cotile
      distantAtLeast d p _ =
        all (\b -> chessDist (bpos b) p > d) inhabitants
  findPosTry 40 ltile
    ( \p t -> Tile.isWalkable cotile t
              && unoccupied as p)
    [ \_ t -> not (isLit t)  -- no such tiles on some maps
    , distantAtLeast factionDist
    , distantAtLeast $ factionDist `div` 2
    , \p _ -> not $ p `ES.member` visible
    , distantAtLeast $ factionDist `div` 3
    , \_ t -> Tile.hasFeature cotile F.CanActor t  -- in reachable area
    , distantAtLeast $ factionDist `div` 4
    , distantAtLeast 3  -- otherwise a fast actor can walk and hit in one turn
    ]

-- | Advance the move time for the given actor and his status effects
-- that are updated once per his move (as opposed to once per a time unit).
advanceTime :: MonadAtomic m => ActorId -> m ()
advanceTime aid = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  b <- getsState $ getActorBody aid
  let t = ticksPerMeter $ bspeed b
  execUpdAtomic $ UpdAgeActor aid t
  -- Calm or worry actor by enemies felt (even if not seen)
  -- on the level within 3 tiles.
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allFoes <- getsState $ actorNotProjList (isAtWar fact) (blid b)
  let closeFoes = filter ((<= 3) . chessDist (bpos b) . bpos) allFoes
      calmMax = maxDice $ acalm $ okind $ bkind b
      calmCur = bcalm b
      deltaCalm = if null closeFoes
                  then max 0 $ min 1 (calmMax - calmCur)
                  else max (-1) (-calmCur)
  when (deltaCalm /= 0) $ execUpdAtomic $ UpdCalmActor aid deltaCalm

-- TODO: generalize to any list of items (or effects) applied to all actors
-- every turn. Specify the list per level in config.
-- TODO: use itemEffect or at least effectSem to get from Regeneration
-- to HealActorA. Also, Applying an item with Regeneration should do the same
-- thing, but immediately (and destroy the item).
-- | Possibly regenerate HP for all actors on the current level.
--
-- We really want leader picking to be a purely UI distinction,
-- so all actors need to regenerate, not just the leaders.
-- Actors on frozen levels don't regenerate. This prevents cheating
-- via sending an actor to a safe level and letting him regenerate there.
regenerateLevelHP :: MonadAtomic m => LevelId -> m ()
regenerateLevelHP lid = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  time <- getsState $ getLocalTime lid
  s <- getState
  let approve (a, m) =
        let ak = okind $ bkind m
            eqpAssocs = getEqpAssocs m s
            regen = max 1 $
                      aregen ak `div`
                      case strongestRegen eqpAssocs of
                        Just (k, _)  -> k + 1
                        Nothing -> 1
            bhpMax = maxDice (ahp ak)
            deltaHP = min 1 (bhpMax - bhp m)
        in if (time `timeFit` timeTurn) `mod` regen /= 0
              || deltaHP <= 0
              || bhp m <= 0
           then Nothing
           else Just a
  toRegen <- getsState $ mapMaybe approve . actorNotProjAssocs (const True) lid
  mapM_ (\aid -> execUpdAtomic $ UpdHealActor aid 1) toRegen

leadLevelFlip :: (MonadAtomic m, MonadServer m) => m ()
leadLevelFlip = do
  Kind.COps{cotile} <- getsState scops
  let canFlip fact = playerAiLeader (gplayer fact)
                     || isSpawnFact fact
      flipFaction fact | not $ canFlip fact = return ()
      flipFaction fact = do
        case gleader fact of
          Nothing -> return ()
          Just leader -> do
            body <- getsState $ getActorBody leader
            lvl2 <- getLevel $ blid body
            let leaderStuck = waitedLastTurn body
                t = lvl2 `at` bpos body
            -- Keep the leader: he is on stairs and not stuck
            -- and we don't want to clog stairs or get pushed to another level.
            unless (not leaderStuck && Tile.isStair cotile t) $ do
              actorD <- getsState sactorD
              let ourLvl (lid, lvl) =
                    ( lid
                    , EM.size (lfloor lvl)
                    , actorNotProjAssocsLvl (== bfid body) lvl actorD )
              ours <- getsState $ map ourLvl . EM.assocs . sdungeon
              -- Non-humans, being born in the dungeon, have a rough idea of
              -- the number of items left on the level and will focus
              -- on levels they started exploring and that have few items
              -- left. This is to to explore them completely, leave them
              -- once and for all and concentrate forces on another level.
              -- In addition, sole stranded actors tend to become leaders
              -- so that they can join the main force ASAP.
              let freqList = [ (k, (lid, a))
                             | (lid, itemN, (a, b) : rest) <- ours
                             , bhp b > 0  -- drama levels skipped
                             , not leaderStuck || lid /= blid body
                             , let len = 1 + (min 10 $ length rest)
                                   k = 1000000 `div` (3 * itemN + len) ]
              unless (null freqList) $ do
                (lid, a) <- rndToAction $ frequency
                                        $ toFreq "leadLevel" freqList
                unless (lid == blid body) $
                  execUpdAtomic
                  $ UpdLeadFaction (bfid body) (Just leader) (Just a)
  factionD <- getsState sfactionD
  mapM_ flipFaction $ EM.elems factionD