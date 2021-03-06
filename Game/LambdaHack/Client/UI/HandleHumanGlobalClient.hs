{-# LANGUAGE DataKinds, GADTs #-}
-- | Semantics of 'Command.Cmd' client commands that return server commands.
-- A couple of them do not take time, the rest does.
-- Here prompts and menus and displayed, but any feedback resulting
-- from the commands (e.g., from inventory manipulation) is generated later on,
-- for all clients that witness the results of the commands.
-- TODO: document
module Game.LambdaHack.Client.UI.HandleHumanGlobalClient
  ( -- * Commands that usually take time
    moveRunHuman, waitHuman, moveItemHuman
  , projectHuman, applyHuman, alterDirHuman, triggerTileHuman
  , stepToTargetHuman
    -- * Commands that never take time
  , gameRestartHuman, gameExitHuman, gameSaveHuman, tacticHuman, automateHuman
  ) where

import Control.Applicative
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.BfsClient
import Game.LambdaHack.Client.CommonClient
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.HandleHumanLocalClient
import Game.LambdaHack.Client.UI.HumanCmd (Trigger (..))
import Game.LambdaHack.Client.UI.InventoryClient
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgClient
import Game.LambdaHack.Client.UI.RunClient
import Game.LambdaHack.Client.UI.WidgetClient
import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.TileKind (TileKind)
import qualified Game.LambdaHack.Content.TileKind as TK

-- * Move and Run

moveRunHuman :: MonadClientUI m
             => Bool -> Vector -> m (SlideOrCmd RequestAnyAbility)
moveRunHuman run dir = do
  tgtMode <- getsClient stgtMode
  if isJust tgtMode then
    fmap Left $ moveCursorHuman dir (if run then 10 else 1)
  else do
    arena <- getArenaUI
    leader <- getLeaderUI
    sb <- getsState $ getActorBody leader
    fact <- getsState $ (EM.! bfid sb) . sfactionD
    let tpos = bpos sb `shift` dir
    -- We start by checking actors at the the target position,
    -- which gives a partial information (actors can be invisible),
    -- as opposed to accessibility (and items) which are always accurate
    -- (tiles can't be invisible).
    tgts <- getsState $ posToActors tpos arena
    case tgts of
      [] -> do  -- move or search or alter
        -- Start running in the given direction. The first turn of running
        -- succeeds much more often than subsequent turns, because we ignore
        -- most of the disturbances, since the player is mostly aware of them
        -- and still explicitly requests a run, knowing how it behaves.
        runStopOrCmd <- moveRunAid leader dir
        case runStopOrCmd of
          Left stopMsg -> failWith stopMsg
          Right runCmd@(RequestAnyAbility ReqMove{}) -> do
            sel <- getsClient sselected
            let runMembers = if noRunWithMulti fact
                             then [leader]  -- TODO: warn?
                             else ES.toList (ES.delete leader sel) ++ [leader]
                runParams = RunParams { runLeader = leader
                                      , runMembers
                                      , runDist = 0
                                      , runStopMsg = Nothing
                                      , runInitDir = Just dir }
            when run $ modifyClient $ \cli -> cli {srunning = Just runParams}
            return $ Right runCmd
          -- Any other command does ends the run immediately.
          Right runCmd -> return $ Right runCmd
        -- When running, the invisible actor is hit (not displaced!),
        -- so that running in the presence of roving invisible
        -- actors is equivalent to moving (with visible actors
        -- this is not a problem, since runnning stops early enough).
        -- TODO: stop running at invisible actor
      [((target, _), _)] | run ->
        -- Displacing requires accessibility, but it's checked later on.
        fmap RequestAnyAbility <$> displaceAid target
      _ : _ : _ | run -> do
        assert (all (bproj . snd . fst) tgts) skip
        failSer DisplaceProjectiles
      ((target, tb), _) : _ -> do
        -- No problem if there are many projectiles at the spot. We just
        -- attack the first one.
        -- We always see actors from our own faction.
        if bfid tb == bfid sb && not (bproj tb) then do
          let autoLvl = snd $ autoDungeonLevel fact
          if autoLvl then failSer NoChangeLvlLeader
          else do
            -- Select adjacent actor by bumping into him. Takes no time.
            success <- pickLeader True target
            assert (success `blame` "bump self"
                            `twith` (leader, target, tb)) skip
            return $ Left mempty
        else
          -- Attacking does not require full access, adjacency is enough.
          fmap RequestAnyAbility <$> meleeAid target

-- | Actor atttacks an enemy actor or his own projectile.
meleeAid :: MonadClientUI m
         => ActorId -> m (SlideOrCmd (RequestTimed AbMelee))
meleeAid target = do
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  tb <- getsState $ getActorBody target
  sfact <- getsState $ (EM.! bfid sb) . sfactionD
  mel <- pickWeaponClient leader target
  case mel of
    [] -> failWith "nothing to melee with"
    wp : _ -> do
      let returnCmd = return $ Right wp
          res | bproj tb || isAtWar sfact (bfid tb) = returnCmd
              | isAllied sfact (bfid tb) = do
                go1 <- displayYesNo ColorBW
                         "You are bound by an alliance. Really attack?"
                if not go1 then failWith "Attack canceled." else returnCmd
              | otherwise = do
                go2 <- displayYesNo ColorBW
                         "This attack will start a war. Are you sure?"
                if not go2 then failWith "Attack canceled." else returnCmd
      res
  -- Seeing the actor prevents altering a tile under it, but that
  -- does not limit the player, he just doesn't waste a turn
  -- on a failed altering.

-- | Actor swaps position with another.
displaceAid :: MonadClientUI m
            => ActorId -> m (SlideOrCmd (RequestTimed AbDisplace))
displaceAid target = do
  cops <- getsState scops
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  tb <- getsState $ getActorBody target
  tfact <- getsState $ (EM.! bfid tb) . sfactionD
  activeItems <- activeItemsClient target
  disp <- getsState $ dispEnemy leader target activeItems
  actorSk <- getsState $ maxActorSkills target activeItems
  let immobile = EM.findWithDefault 0 AbDisplace actorSk <= 0
                 && EM.findWithDefault 0 AbMove actorSk <= 0
      spos = bpos sb
      tpos = bpos tb
      adj = checkAdjacent sb tb
      atWar = isAtWar tfact (bfid sb)
  if not adj then failSer DisplaceDistant
  else if not (bproj tb) && atWar
          && actorDying tb then failSer DisplaceDying
  else if not (bproj tb) && atWar
          && braced tb then failSer DisplaceBraced
  else if not (bproj tb) && atWar
          && immobile then failSer DisplaceImmobile
  else if not disp && atWar then failSer DisplaceSupported
  else do
    let lid = blid sb
    lvl <- getLevel lid
    -- Displacing requires full access.
    if accessible cops lvl spos tpos then do
      tgts <- getsState $ posToActors tpos lid
      case tgts of
        [] -> assert `failure` (leader, sb, target, tb)
        [_] -> do
          return $ Right $ ReqDisplace target
        _ -> failSer DisplaceProjectiles
    else failSer DisplaceAccess

-- * Wait

-- | Leader waits a turn (and blocks, etc.).
waitHuman :: MonadClientUI m => m (RequestTimed AbWait)
waitHuman = do
  modifyClient $ \cli -> cli {swaitTimes = abs (swaitTimes cli) + 1}
  return ReqWait

-- * MoveItem

moveItemHuman :: MonadClientUI m
              => [CStore] -> CStore -> (Maybe MU.Part) -> Bool
              -> m (SlideOrCmd (RequestTimed AbMoveItem))
moveItemHuman cLegalRaw destCStore mverb auto = do
  assert (destCStore `notElem` cLegalRaw) skip
  let verb = fromMaybe (MU.Text $ verbCStore destCStore) mverb
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  let cLegal = if calmEnough b activeItems
               then cLegalRaw
               else if destCStore == CSha
                    then []
                    else delete CSha cLegalRaw
  ggi <- if auto
         then getAnyItem verb cLegalRaw cLegal False False
         else getAnyItem verb cLegalRaw cLegal True True
  case ggi of
    Right ((iid, itemFull), CActor _ fromCStore) -> do
      let k = itemK itemFull
          retReq toCStore =
            return $ Right $ ReqMoveItem iid k fromCStore toCStore
      if fromCStore == CGround
      then case destCStore of
        CEqp | goesIntoInv (itemBase itemFull) ->
          retReq CInv
        CEqp | eqpOverfull b k -> do
          msgAdd $ "Warning:" <+> showReqFailure EqpOverfull <> "."
          retReq CInv
        _ ->
          retReq destCStore
      else case destCStore of
        CEqp | eqpOverfull b k -> failSer EqpOverfull
        _ -> retReq destCStore
    Left slides -> return $ Left slides
    _ -> assert `failure` ggi

-- * Project

projectHuman :: MonadClientUI m
             => [Trigger] -> m (SlideOrCmd (RequestTimed AbProject))
projectHuman ts = do
  leader <- getLeaderUI
  tgtPos <- leaderTgtToPos
  tgt <- getsClient $ getTarget leader
  case tgtPos of
    Nothing -> failWith "last target invalid"
    Just pos -> do
      -- Set cursor to the personal target, temporarily.
      oldCursor <- getsClient scursor
      modifyClient $ \cli -> cli {scursor = fromMaybe (scursor cli) tgt}
      -- Show the targeting line, temporarily.
      oldTgtMode <- getsClient stgtMode
      lidV <- viewedLevel
      modifyClient $ \cli -> cli {stgtMode = Just $ TgtMode lidV}
      canAim <- leaderTgtAims
      oldEps <- getsClient seps
      outcome <- case canAim of
        Right newEps -> do
          -- Modify @seps@,, temporarily.
          modifyClient $ \cli -> cli {seps = newEps}
          projectPos ts pos
        Left cause -> failWith cause
      modifyClient $ \cli -> cli { stgtMode = oldTgtMode
                                 , scursor = oldCursor
                                 , seps = oldEps }
      return outcome

projectPos :: MonadClientUI m
           => [Trigger] -> Point -> m (SlideOrCmd (RequestTimed AbProject))
projectPos ts tpos = do
  Kind.COps{cotile} <- getsState scops
  leader <- getLeaderUI
  eps <- getsClient seps
  sb <- getsState $ getActorBody leader
  let lid = blid sb
      spos = bpos sb
  Level{lxsize, lysize} <- getLevel lid
  case bla lxsize lysize eps spos tpos of
    Nothing -> failSer ProjectAimOnself
    Just [] -> assert `failure` "project from the edge of level"
                      `twith` (spos, tpos, sb, ts)
    Just (pos : _) -> do
      lvl <- getLevel lid
      let t = lvl `at` pos
      if not $ Tile.isWalkable cotile t
        then failSer ProjectBlockTerrain
        else do
          mab <- getsState $ posToActor pos lid
          if maybe True (bproj . snd . fst) mab
          then projectEps ts tpos eps
          else failSer ProjectBlockActor

projectEps :: MonadClientUI m
           => [Trigger] -> Point -> Int
           -> m (SlideOrCmd (RequestTimed AbProject))
projectEps ts tpos eps = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  actorSk <- actorSkillsClient leader
  let skill = EM.findWithDefault 0 AbProject actorSk
  activeItems <- activeItemsClient leader
  let cLegal = [CGround, CInv, CEqp]
      (verb1, object1) = case ts of
        [] -> ("aim", "item")
        tr : _ -> (verb tr, object tr)
      triggerSyms = triggerSymbols ts
      p itemFull@ItemFull{itemBase} =
        let legal = permittedProject triggerSyms False skill itemFull b activeItems
        in case legal of
          Left{} -> legal
          Right False -> legal
          Right True -> Right $ totalRange itemBase >= chessDist (bpos b) tpos
      prompt = makePhrase ["What", object1, "to", verb1]
      promptGeneric = "What item to fling"
  ggi <- getGroupItem (either (const False) id . p) prompt promptGeneric cLegal cLegal
  case ggi of
    Right ((iid, itemFull), CActor _ fromCStore) ->
      case p itemFull of
        Left reqFail -> failSer reqFail
        Right _ -> return $ Right $ ReqProject tpos eps iid fromCStore
    Left slides -> return $ Left slides
    _ -> assert `failure` ggi

triggerSymbols :: [Trigger] -> [Char]
triggerSymbols [] = []
triggerSymbols (ApplyItem{symbol} : ts) = symbol : triggerSymbols ts
triggerSymbols (_ : ts) = triggerSymbols ts

-- * Apply

applyHuman :: MonadClientUI m
           => [Trigger] -> m (SlideOrCmd (RequestTimed AbApply))
applyHuman ts = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  actorSk <- actorSkillsClient leader
  let skill = EM.findWithDefault 0 AbProject actorSk
  activeItems <- activeItemsClient leader
  let cLegal = [CGround, CInv, CEqp]
      (verb1, object1) = case ts of
        [] -> ("activate", "item")
        tr : _ -> (verb tr, object tr)
      triggerSyms = triggerSymbols ts
      p itemFull = permittedApply triggerSyms skill itemFull b activeItems
      prompt = makePhrase ["What", object1, "to", verb1]
      promptGeneric = "What item to activate"
  ggi <- getGroupItem (either (const False) id . p) prompt promptGeneric cLegal cLegal
  case ggi of
    Right ((iid, itemFull), CActor _ fromCStore) ->
      case p itemFull of
        Left reqFail -> failSer reqFail
        Right _ -> return $ Right $ ReqApply iid fromCStore
    Left slides -> return $ Left slides
    _ -> assert `failure` ggi

-- * AlterDir

-- | Ask for a direction and alter a tile, if possible.
alterDirHuman :: MonadClientUI m
              => [Trigger] -> m (SlideOrCmd (RequestTimed AbAlter))
alterDirHuman ts = do
  Config{configVi, configLaptop} <- askConfig
  let verb1 = case ts of
        [] -> "alter"
        tr : _ -> verb tr
      keys = zipWith K.KM (repeat K.NoModifier)
                          (K.dirAllKey configVi configLaptop)
      prompt = makePhrase ["What to", verb1 <> "? [movement key"]
  me <- displayChoiceUI prompt emptyOverlay keys
  case me of
    Left slides -> failSlides slides
    Right e -> K.handleDir configVi configLaptop e (flip alterTile ts)
                                                   (failWith "never mind")

-- | Player tries to alter a tile using a feature.
alterTile :: MonadClientUI m
          => Vector -> [Trigger] -> m (SlideOrCmd (RequestTimed AbAlter))
alterTile dir ts = do
  cops@Kind.COps{cotile} <- getsState scops
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lvl <- getLevel $ blid b
  let tpos = bpos b `shift` dir
      t = lvl `at` tpos
      alterFeats = alterFeatures ts
  case filter (\feat -> Tile.hasFeature cotile feat t) alterFeats of
    [] -> failWith $ guessAlter cops alterFeats t
    feat : _ -> return $ Right $ ReqAlter tpos $ Just feat

alterFeatures :: [Trigger] -> [TK.Feature]
alterFeatures [] = []
alterFeatures (AlterFeature{feature} : ts) = feature : alterFeatures ts
alterFeatures (_ : ts) = alterFeatures ts

-- | Guess and report why the bump command failed.
guessAlter :: Kind.COps -> [TK.Feature] -> Kind.Id TileKind -> Msg
guessAlter Kind.COps{cotile} (TK.OpenTo _ : _) t
  | Tile.isClosable cotile t = "already open"
guessAlter _ (TK.OpenTo _ : _) _ = "cannot be opened"
guessAlter Kind.COps{cotile} (TK.CloseTo _ : _) t
  | Tile.isOpenable cotile t = "already closed"
guessAlter _ (TK.CloseTo _ : _) _ = "cannot be closed"
guessAlter _ _ _ = "never mind"

-- * TriggerTile

-- | Leader tries to trigger the tile he's standing on.
triggerTileHuman :: MonadClientUI m
                 => [Trigger] -> m (SlideOrCmd (RequestTimed AbTrigger))
triggerTileHuman ts = do
  tgtMode <- getsClient stgtMode
  if isJust tgtMode then do
    let getK tfs = case tfs of
          TriggerFeature {feature = TK.Cause (IK.Ascend k)} : _ -> Just k
          _ : rest -> getK rest
          [] -> Nothing
        mk = getK ts
    case mk of
      Nothing -> failWith "never mind"
      Just k -> fmap Left $ tgtAscendHuman k
  else triggerTile ts

-- | Player tries to trigger a tile using a feature.
triggerTile :: MonadClientUI m
            => [Trigger] -> m (SlideOrCmd (RequestTimed AbTrigger))
triggerTile ts = do
  cops@Kind.COps{cotile} <- getsState scops
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lvl <- getLevel $ blid b
  let t = lvl `at` bpos b
      triggerFeats = triggerFeatures ts
  case filter (\feat -> Tile.hasFeature cotile feat t) triggerFeats of
    [] -> failWith $ guessTrigger cops triggerFeats t
    feat : _ -> do
      go <- verifyTrigger leader feat
      case go of
        Right () -> return $ Right $ ReqTrigger $ Just feat
        Left slides -> return $ Left slides

triggerFeatures :: [Trigger] -> [TK.Feature]
triggerFeatures [] = []
triggerFeatures (TriggerFeature{feature} : ts) = feature : triggerFeatures ts
triggerFeatures (_ : ts) = triggerFeatures ts

-- | Verify important feature triggers, such as fleeing the dungeon.
verifyTrigger :: MonadClientUI m
              => ActorId -> TK.Feature -> m (SlideOrCmd ())
verifyTrigger leader feat = case feat of
  TK.Cause IK.Escape{} -> do
    b <- getsState $ getActorBody leader
    side <- getsClient sside
    fact <- getsState $ (EM.! side) . sfactionD
    if not (fcanEscape $ gplayer fact) then failWith
      "This is the way out, but where would you go in this alien world?"
    else do
      go <- displayYesNo ColorFull "This is the way out. Really leave now?"
      if not go then failWith "Game resumed."
      else do
        (_, total) <- getsState $ calculateTotal b
        if total == 0 then do
          -- The player can back off at each of these steps.
          go1 <- displayMore ColorBW
                   "Afraid of the challenge? Leaving so soon and empty-handed?"
          if not go1 then failWith "Brave soul!"
          else do
             go2 <- displayMore ColorBW
                     "Next time try to grab some loot before escape!"
             if not go2 then failWith "Here's your chance!"
             else return $ Right ()
        else return $ Right ()
  _ -> return $ Right ()

-- | Guess and report why the bump command failed.
guessTrigger :: Kind.COps -> [TK.Feature] -> Kind.Id TileKind -> Msg
guessTrigger Kind.COps{cotile} fs@(TK.Cause (IK.Ascend k) : _) t
  | Tile.hasFeature cotile (TK.Cause (IK.Ascend (-k))) t =
    if k > 0 then "the way goes down, not up"
    else if k < 0 then "the way goes up, not down"
    else assert `failure` fs
guessTrigger _ fs@(TK.Cause (IK.Ascend k) : _) _ =
    if k > 0 then "cannot ascend"
    else if k < 0 then "cannot descend"
    else assert `failure` fs
guessTrigger _ _ _ = "never mind"

-- * StepToTarget

stepToTargetHuman :: MonadClientUI m => m (SlideOrCmd RequestAnyAbility)
stepToTargetHuman = do
  tgtMode <- getsClient stgtMode
  -- Movement is legal only outside targeting mode.
  -- TODO: use this command for something in targeting mode.
  if isJust tgtMode then failWith "cannot move in targeting mode"
  else do
    leader <- getLeaderUI
    b <- getsState $ getActorBody leader
    tgtPos <- leaderTgtToPos
    case tgtPos of
      Nothing -> failWith "target not set"
      Just c | c == bpos b -> failWith "target reached"
      Just c -> do
        (_, mpath) <- getCacheBfsAndPath leader c
        case mpath of
          Nothing -> failWith "no route to target"
          Just [] -> assert `failure` (leader, b, bpos b, c)
          Just (p1 : _) -> do
            as <- getsState $ posToActors p1 (blid b)
            if not $ null as then
              failWith "actor in the path to target"
            else
              moveRunHuman False $ towards (bpos b) p1

-- * GameRestart; does not take time

gameRestartHuman :: MonadClientUI m => GroupName ModeKind -> m (SlideOrCmd RequestUI)
gameRestartHuman t = do
  let restart = do
        leader <- getLeaderUI
        DebugModeCli{sdifficultyCli} <- getsClient sdebugCli
        Config{configHeroNames} <- askConfig
        return $ Right
               $ ReqUIGameRestart leader t sdifficultyCli configHeroNames
  escAI <- getsClient sescAI
  if escAI == EscAIExited then restart
  else do
    let msg = "You just requested a new" <+> tshow t <+> "game."
    b1 <- displayMore ColorFull msg
    if not b1 then failWith "never mind"
    else do
      b2 <- displayYesNo ColorBW
              "Current progress will be lost! Really restart the game?"
      msg2 <- rndToAction $ oneOf
                [ "Yea, would be a pity to leave them all to die."
                , "Yea, a shame to get your own team stranded." ]
      if not b2 then failWith msg2
      else restart

-- * GameExit; does not take time

gameExitHuman :: MonadClientUI m => m (SlideOrCmd RequestUI)
gameExitHuman = do
  go <- displayYesNo ColorFull "Really save and exit?"
  if go then do
    leader <- getLeaderUI
    DebugModeCli{sdifficultyCli} <- getsClient sdebugCli
    return $ Right $ ReqUIGameExit leader sdifficultyCli
  else failWith "Save and exit canceled."

-- * GameSave; does not take time

gameSaveHuman :: MonadClientUI m => m RequestUI
gameSaveHuman = do
  -- Announce before the saving started, since it can take some time
  -- and may slow down the machine, even if not block the client.
  -- TODO: do not save to history:
  msgAdd "Saving game backup."
  return ReqUIGameSave

-- * Tactic; does not take time

-- Note that the difference between seek-target and follow-the-leader tactic
-- can influence even a faction with passive actors. E.g., if a passive actor
-- has an extra active skill from equipment, he moves every turn.
-- TODO: set tactic for allied passive factions, too or all allied factions
-- and perhaps even factions with a leader should follow our leader
-- and his target, not their leader.
tacticHuman :: MonadClientUI m => m (SlideOrCmd RequestUI)
tacticHuman = do
  fid <- getsClient sside
  fromT <- getsState $ ftactic . gplayer . (EM.! fid) . sfactionD
  let toT = if fromT == maxBound then minBound else succ fromT
  go <- displayMore ColorFull
        $ "Switching tactic to"
          <+> T.pack (show toT)  -- tshow eats up parens
          <> ". (This clears targets.)"
  if not go
    then failWith "Tactic change canceled."
    else return $ Right $ ReqUITactic toT

-- * Automate; does not take time

automateHuman :: MonadClientUI m => m (SlideOrCmd RequestUI)
automateHuman = do
  -- BFS is not updated while automated, which would lead to corruption.
  modifyClient $ \cli -> cli {stgtMode = Nothing}
  escAI <- getsClient sescAI
  if escAI == EscAIExited then return $ Right ReqUIAutomate
  else do
    go <- displayMore ColorBW "Ceding control to AI (ESC to regain)."
    if not go
      then failWith "Automation canceled."
      else return $ Right ReqUIAutomate
