{-# LANGUAGE CPP #-}
-- | Field Of View scanning with a variety of algorithms.
-- See <https://github.com/LambdaHack/LambdaHack/wiki/Fov-and-los>
-- for discussion.
module Game.LambdaHack.Server.Fov
  ( dungeonPerception, fidLidPerception
  , PersLit, litInDungeon
#ifdef EXPOSE_INTERNAL
  , PerceptionLit, ActorEqpBody
#endif
  ) where

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Lazy as EML
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Function
import Data.List
import Data.Maybe
import Data.Ord

import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Server.Fov.Common
import qualified Game.LambdaHack.Server.Fov.Digital as Digital
import qualified Game.LambdaHack.Server.Fov.Permissive as Permissive
import qualified Game.LambdaHack.Server.Fov.Shadow as Shadow
import Game.LambdaHack.Server.State

-- | Visually reachable position (light passes through them to the actor).
newtype PerceptionReachable = PerceptionReachable
    {preachable :: [Point]}
  deriving Show

-- | All lit positions on a level.
newtype PerceptionLit = PerceptionLit
    {plit :: ES.EnumSet Point}
  deriving Show

type ActorEqpBody = [((ActorId, Actor), [ItemFull])]

type PersLit = EML.EnumMap LevelId ( PerceptionLit
                                   , EM.EnumMap FactionId ActorEqpBody
                                   , PointArray.Array Bool )

-- | Calculate faction's perception of a level.
levelPerception :: Kind.COps
                -> PerceptionLit -> ActorEqpBody -> PointArray.Array Bool
                -> FovMode -> Level
                -> Perception
levelPerception cops litHere actorEqpBody blockers
                fovMode lvl@Level{lxsize, lysize} =
  let -- Dying actors included, to let them see their own demise.
      ours = filter (not . bproj . snd . fst) actorEqpBody
      ourR = preachable . reachableFromActor blockers fovMode
      totalReachable = PerceptionReachable $ concatMap ourR ours
      pAndVicinity p = p : vicinity lxsize lysize p
      -- All actors feel adjacent positions, even dark (for easy exploration).
      noctoBodies = map (\aEB@((_, b), _) -> (pAndVicinity (bpos b), aEB)) ours
      nocto = concat $ map fst noctoBodies
      ptotal = visibleOnLevel cops totalReachable litHere nocto lvl
      canSmellAround (_, allAssocs) =
        let radius = sumSlotNoFilter IK.EqpSlotAddSmell allAssocs
        in radius >= 2
      -- TODO: handle smell radius < 2, that is only under the actor
      -- TODO: filter out tiles that are solid and so can't hold smell.
      psmell = PerceptionVisible $ ES.fromList
               $ concat $ map fst $ filter (canSmellAround . snd) noctoBodies
  in Perception ptotal psmell

-- | Calculate faction's perception of a level based on the lit tiles cache.
fidLidPerception :: Kind.COps -> FovMode -> PersLit
                 -> FactionId -> LevelId -> Level
                 -> Perception
fidLidPerception cops fovMode persLit fid lid lvl =
  let (litHere, bodyMap, blockers) = persLit EML.! lid
      actorEqpBody = EM.findWithDefault [] fid bodyMap
  in levelPerception cops litHere actorEqpBody blockers fovMode lvl

-- | Calculate perception of a faction.
factionPerception :: FovMode -> PersLit -> FactionId -> State -> FactionPers
factionPerception fovMode persLit fid s =
  EM.mapWithKey (fidLidPerception (scops s) fovMode persLit fid) $ sdungeon s

-- | Calculate the perception of the whole dungeon.
dungeonPerception :: FovMode -> State -> StateServer -> Pers
dungeonPerception fovMode s ser =
  let persLit = litInDungeon fovMode s ser
      f fid _ = factionPerception fovMode persLit fid s
  in EM.mapWithKey f $ sfactionD s

-- | Compute positions visible (reachable and seen) by the party.
-- A position can be directly lit by an ambient shine or by a weak, portable
-- light source, e.g,, carried by an actor. A reachable and lit position
-- is visible. Additionally, positions directly adjacent to an actor are
-- assumed to be visible to him (through sound, touch, noctovision, whatever).
visibleOnLevel :: Kind.COps -> PerceptionReachable
               -> PerceptionLit -> [Point] -> Level
               -> PerceptionVisible
visibleOnLevel Kind.COps{cotile}
               PerceptionReachable{preachable} PerceptionLit{plit}
               nocto lvl =
  -- TODO: costly
  -- TODO: make a vector mask from isVisible; possibly of PerceptionVisible, too
  let isVisible pos = Tile.isLit cotile (lvl `at` pos) || pos `ES.member` plit
  in PerceptionVisible $ ES.fromList $ nocto ++ filter isVisible preachable

-- | Compute positions reachable by the actor. Reachable are all fields
-- on a visually unblocked path from the actor position.
reachableFromActor :: PointArray.Array Bool -> FovMode
                   -> ((ActorId, Actor), [ItemFull])
                   -> PerceptionReachable
reachableFromActor blockers fovMode ((_, body), allItems) =
  let sumSight = sumSlotNoFilter IK.EqpSlotAddSight allItems
      radius = min (fromIntegral $ bcalm body `div` (5 * oneM)) sumSight
  in PerceptionReachable $ fullscan blockers fovMode radius (bpos body)

-- | Compute all lit positions on a level, whether lit by actors or floor items.
-- Note that an actor can be blind or a projectile, in which case he doesn't see
-- his own light (but others, from his or other factions, possibly do).
litByItems :: Kind.COps -> PointArray.Array Bool -> FovMode -> Level
           -> [(Point, [ItemFull])]
           -> PerceptionLit
litByItems Kind.COps{cotile} blockers fovMode lvl allItems =
  let litPos :: (Point, [ItemFull]) -> [Point]
      litPos (p, is) =
        let radius = sumSlotNoFilter IK.EqpSlotAddLight is
            scan = fullscan blockers fovMode radius p
            -- Optimization: filter out positions already having ambient light.
            opt = filter (\pos -> not $ Tile.isLit cotile $ lvl `at` pos) scan
        in opt
      litAll = concatMap litPos allItems
  in PerceptionLit $ ES.fromList litAll

-- | Compute all lit positions in the dungeon
litInDungeon :: FovMode -> State -> StateServer -> PersLit
litInDungeon fovMode s ser =
  let cops@Kind.COps{cotile} = scops s
      itemsInActors :: Level -> EM.EnumMap FactionId ActorEqpBody
      itemsInActors lvl =
        let asLid = map (\aid -> (aid, getActorBody aid s))
                    $ concat $ EM.elems $ lprio lvl
            asGrouped = groupBy ((==) `on` (bfid . snd))
                        $ sortBy (comparing (bfid . snd)) asLid
            bodyFid :: [(ActorId, Actor)] -> (FactionId, ActorEqpBody)
            bodyFid [] = assert `failure` asGrouped
            bodyFid asFid@((_, bFid) : _) =
              let fid = bfid bFid
                  eqpBody (aid, b) =
                    ( (aid, b)
                    , map snd $ fullAssocs cops (sdiscoKind ser) (sdiscoEffect ser)
                                           aid [COrgan, CEqp] s )
              in (fid, map eqpBody asFid)
        in EM.fromDistinctAscList $ map bodyFid asGrouped
      itemsOnFloor :: Level -> [(Point, [ItemFull])]
      itemsOnFloor lvl =
        let iToFull (iid, (item, kit)) =
              itemToFull cops (sdiscoKind ser) (sdiscoEffect ser) iid item kit
            processPos (p, bag) =
              (p, map iToFull $ bagAssocsK s bag)
        in map processPos $ EM.assocs $ lfloor lvl  -- lembed are covered
      -- Note that an actor can be blind or a projectile,
      -- in which case he doesn't see his own light
      -- (but others, from his or other factions, possibly do).
      litOnLevel :: Level -> ( PerceptionLit
                             , EM.EnumMap FactionId ActorEqpBody
                             , PointArray.Array Bool )
      litOnLevel lvl@Level{ltile} =
        let bodyMap = itemsInActors lvl
            allBodies = concat $ EM.elems bodyMap
            blockingTiles = PointArray.mapA (Tile.isClear cotile) ltile
            blockFromBody ((_, b), _) =
              if bproj b then Nothing else Just (bpos b, False)
            -- TODO: keep it in server state and update when tiles change
            -- and actors are born/move/die. Actually, do this for PersLit.
            blockingActors = mapMaybe blockFromBody allBodies
            blockers = blockingTiles PointArray.// blockingActors
            actorItems = map (\((_, b), iis) -> (bpos b, iis)) allBodies
            floorItems = itemsOnFloor lvl
            allItems = floorItems ++ actorItems
        in (litByItems cops blockers fovMode lvl allItems, bodyMap, blockers)
      litLvl (lid, lvl) = (lid, litOnLevel lvl)
  in EML.fromDistinctAscList $ map litLvl $ EM.assocs $ sdungeon s

-- | Perform a full scan for a given position. Returns the positions
-- that are currently in the field of view. The Field of View
-- algorithm to use is passed in the second argument.
-- The actor's own position is considred reachable by him.
fullscan :: PointArray.Array Bool  -- ^ the array with non-clear points
         -> FovMode    -- ^ scanning mode
         -> Int        -- ^ scanning radius
         -> Point      -- ^ position of the spectator
         -> [Point]
fullscan blockers fovMode radius spectatorPos =
  if radius <= 0 then []
  else if radius == 1 then [spectatorPos]
  else spectatorPos : case fovMode of
    Shadow ->
      concatMap (\tr -> map tr (Shadow.scan (isCl . tr) 1 (0, 1))) tr8
    Permissive ->
      concatMap (\tr -> map tr (Permissive.scan (isCl . tr))) tr4
    Digital ->
      concatMap (\tr -> map tr (Digital.scan (radius - 1) (isCl . tr))) tr4
 where
  isCl :: Point -> Bool
  {-# INLINE isCl #-}
  isCl = (blockers PointArray.!)

  -- This function is cheap, so no problem it's called twice
  -- for each point: once with @isCl@, once via @concatMap@.
  trV :: X -> Y -> Point
  {-# INLINE trV #-}
  trV x y = shift spectatorPos $ Vector x y

  -- | The translation, rotation and symmetry functions for octants.
  tr8 :: [(Distance, Progress) -> Point]
  {-# INLINE tr8 #-}
  tr8 =
    [ \(p, d) -> trV   p    d
    , \(p, d) -> trV (-p)   d
    , \(p, d) -> trV   p  (-d)
    , \(p, d) -> trV (-p) (-d)
    , \(p, d) -> trV   d    p
    , \(p, d) -> trV (-d)   p
    , \(p, d) -> trV   d  (-p)
    , \(p, d) -> trV (-d) (-p)
    ]

  -- | The translation and rotation functions for quadrants.
  tr4 :: [Bump -> Point]
  {-# INLINE tr4 #-}
  tr4 =
    [ \B{..} -> trV   bx  (-by)  -- quadrant I
    , \B{..} -> trV   by    bx   -- II (we rotate counter-clockwise)
    , \B{..} -> trV (-bx)   by   -- III
    , \B{..} -> trV (-by) (-bx)  -- IV
    ]
