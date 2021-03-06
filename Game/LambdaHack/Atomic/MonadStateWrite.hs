-- | The monad for writing to the game state and related operations.
module Game.LambdaHack.Atomic.MonadStateWrite
  ( MonadStateWrite(..)
  , updateLevel, updateActor, updateFaction
  , insertItemContainer, insertItemActor, deleteItemContainer, deleteItemActor
  , updatePrio, updateFloor, updateTile, updateSmell
  ) where

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Strict as EM

import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State

class MonadStateRead m => MonadStateWrite m where
  modifyState :: (State -> State) -> m ()
  putState    :: State -> m ()

-- | Update the actor time priority queue.
updatePrio :: (ActorPrio -> ActorPrio) -> Level -> Level
updatePrio f lvl = lvl {lprio = f (lprio lvl)}

-- | Update the items on the ground map.
updateFloor :: (ItemFloor -> ItemFloor) -> Level -> Level
updateFloor f lvl = lvl {lfloor = f (lfloor lvl)}

-- | Update the items embedded in a tile on the level.
updateEmbed :: (ItemFloor -> ItemFloor) -> Level -> Level
updateEmbed f lvl = lvl {lembed = f (lembed lvl)}

-- | Update the tile map.
updateTile :: (TileMap -> TileMap) -> Level -> Level
updateTile f lvl = lvl {ltile = f (ltile lvl)}

-- | Update the smell map.
updateSmell :: (SmellMap -> SmellMap) -> Level -> Level
updateSmell f lvl = lvl {lsmell = f (lsmell lvl)}

-- | Update a given level data within state.
updateLevel :: MonadStateWrite m => LevelId -> (Level -> Level) -> m ()
updateLevel lid f = modifyState $ updateDungeon $ EM.adjust f lid

updateActor :: MonadStateWrite m => ActorId -> (Actor -> Actor) -> m ()
updateActor aid f = do
  let alt Nothing = assert `failure` "no body to update" `twith` aid
      alt (Just b) = Just $ f b
  modifyState $ updateActorD $ EM.alter alt aid

updateFaction :: MonadStateWrite m => FactionId -> (Faction -> Faction) -> m ()
updateFaction fid f = do
  let alt Nothing = assert `failure` "no faction to update" `twith` fid
      alt (Just fact) = Just $ f fact
  modifyState $ updateFactionD $ EM.alter alt fid

insertItemContainer :: MonadStateWrite m
                    => ItemId -> ItemQuant -> Container -> m ()
insertItemContainer iid kit c = case c of
  CFloor lid pos -> insertItemFloor iid kit lid pos
  CEmbed lid pos -> insertItemEmbed iid kit lid pos
  CActor aid store -> insertItemActor iid kit aid store
  CTrunk{} -> return ()

-- New @kit@ lands at the front of the list.
insertItemFloor :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
insertItemFloor iid kit lid pos =
  let bag = EM.singleton iid kit
      mergeBag = EM.insertWith (EM.unionWith mergeItemQuant) pos bag
  in updateLevel lid $ updateFloor mergeBag

insertItemEmbed :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
insertItemEmbed iid kit lid pos =
  let bag = EM.singleton iid kit
      mergeBag = EM.insertWith (EM.unionWith mergeItemQuant) pos bag
  in updateLevel lid $ updateEmbed mergeBag

insertItemActor :: MonadStateWrite m
                => ItemId -> ItemQuant -> ActorId -> CStore -> m ()
insertItemActor iid kit aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    insertItemFloor iid kit (blid b) (bpos b)
  COrgan -> insertItemBody iid kit aid
  CEqp -> insertItemEqp iid kit aid
  CInv -> insertItemInv iid kit aid
  CSha -> do
    b <- getsState $ getActorBody aid
    insertItemSha iid kit (bfid b)

insertItemBody :: MonadStateWrite m
               => ItemId -> ItemQuant -> ActorId -> m ()
insertItemBody iid kit aid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b -> b {borgan = upd (borgan b)}

insertItemEqp :: MonadStateWrite m
              => ItemId -> ItemQuant -> ActorId -> m ()
insertItemEqp iid kit aid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b -> b {beqp = upd (beqp b)}

insertItemInv :: MonadStateWrite m
              => ItemId -> ItemQuant -> ActorId -> m ()
insertItemInv iid kit aid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b -> b {binv = upd (binv b)}

insertItemSha :: MonadStateWrite m
              => ItemId -> ItemQuant -> FactionId -> m ()
insertItemSha iid kit fid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateFaction fid $ \fact -> fact {gsha = upd (gsha fact)}

deleteItemContainer :: MonadStateWrite m
                    => ItemId -> Int -> Container -> m ()
deleteItemContainer iid k c = case c of
  CFloor lid pos -> deleteItemFloor iid k lid pos
  CEmbed lid pos -> deleteItemEmbed iid k lid pos
  CActor aid store -> deleteItemActor iid k aid store
  CTrunk{} -> return ()

deleteItemFloor :: MonadStateWrite m
                => ItemId -> Int -> LevelId -> Point -> m ()
deleteItemFloor iid k lid pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag k iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = assert `failure` "item already removed"
                                   `twith` (iid, k, lid, pos)
  in updateLevel lid $ updateFloor $ EM.alter rmFromFloor pos

deleteItemEmbed :: MonadStateWrite m
                => ItemId -> Int -> LevelId -> Point -> m ()
deleteItemEmbed iid k lid pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag k iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = assert `failure` "item already removed"
                                   `twith` (iid, k, lid, pos)
  in updateLevel lid $ updateEmbed $ EM.alter rmFromFloor pos

deleteItemActor :: MonadStateWrite m
                => ItemId -> Int -> ActorId -> CStore -> m ()
deleteItemActor iid k aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    deleteItemFloor iid k (blid b) (bpos b)
  COrgan -> deleteItemBody iid k aid
  CEqp -> deleteItemEqp iid k aid
  CInv -> deleteItemInv iid k aid
  CSha -> do
    b <- getsState $ getActorBody aid
    deleteItemSha iid k (bfid b)

deleteItemBody :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemBody iid k aid = do
  updateActor aid $ \b -> b {borgan = rmFromBag k iid (borgan b) }

deleteItemEqp :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemEqp iid k aid = do
  updateActor aid $ \b -> b {beqp = rmFromBag k iid (beqp b)}

deleteItemInv :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemInv iid k aid = do
  updateActor aid $ \b -> b {binv = rmFromBag k iid (binv b)}

deleteItemSha :: MonadStateWrite m => ItemId -> Int -> FactionId -> m ()
deleteItemSha iid k fid = do
  updateFaction fid $ \fact -> fact {gsha = rmFromBag k iid (gsha fact)}

-- Removing the part of the kit from the front of the list,
-- so that @DestroyItem kit (CreateItem kit x) == x@.
rmFromBag :: Int -> ItemId -> ItemBag -> ItemBag
rmFromBag k iid bag =
  let rfb Nothing = assert `failure` "rm from empty slot" `twith` (k, iid, bag)
      rfb (Just (n, it)) =
        case compare n k of
          LT -> assert `failure` "rm more than there is"
                       `twith` (n, k, iid, bag)
          EQ -> Nothing
          GT -> Just (n - k, drop k it)
  in EM.alter rfb iid bag
