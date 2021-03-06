{-# LANGUAGE DeriveFunctor, DeriveGeneric #-}
-- | The type of kinds of weapons, treasure, organs, blasts and actors.
module Game.LambdaHack.Content.ItemKind
  ( ItemKind(..)
  , Effect(..), TimerDice(..)
  , Aspect(..), ThrowMod(..)
  , Feature(..), EqpSlot(..)
  , aspectTrav
  , toVelocity, toLinger, toOrganGameTurn, toOrganActorTurn, toOrganNone
  , validateSingleItemKind, validateAllItemKind
  ) where

import qualified Control.Monad.State as St
import Data.Binary
import Data.Hashable (Hashable)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import qualified NLP.Miniutter.English as MU

import qualified Game.LambdaHack.Common.Ability as Ability
import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Misc

-- | Item properties that are fixed for a given kind of items.
data ItemKind = ItemKind
  { isymbol  :: !Char              -- ^ map symbol
  , iname    :: !Text              -- ^ generic name
  , ifreq    :: !(Freqs ItemKind)  -- ^ frequency within groups
  , iflavour :: ![Flavour]         -- ^ possible flavours
  , icount   :: !Dice.Dice         -- ^ created in that quantity
  , irarity  :: !Rarity            -- ^ rarity on given depths
  , iverbHit :: !MU.Part           -- ^ the verb for applying and melee
  , iweight  :: !Int               -- ^ weight in grams
  , iaspects :: ![Aspect Dice.Dice]
                                   -- ^ keep the aspect continuously
  , ieffects :: ![Effect]
                                   -- ^ cause the effect when triggered
  , ifeature :: ![Feature]         -- ^ public properties
  , idesc    :: !Text              -- ^ description
  , ikit     :: ![(GroupName ItemKind, CStore)]
                                   -- ^ accompanying organs and items
  }
  deriving Show  -- No Eq and Ord to make extending it logically sound

-- TODO: document each constructor
-- | Effects of items. Can be invoked by the item wielder to affect
-- another actor or the wielder himself. Many occurences in the same item
-- are possible. Constructors are sorted vs increasing impact/danger.
data Effect =
    -- Ordinary effects.
    NoEffect !Text
  | Hurt !Dice.Dice
  | Burn !Int  -- Dice.Dice? generalize to other elements? ignite terrain?
  | Explode !(GroupName ItemKind)
                          -- ^ explode, producing this group of blasts
  | RefillHP !Int
  | OverfillHP !Int
  | RefillCalm !Int
  | OverfillCalm !Int
  | Dominate
  | Impress
  | CallFriend !Dice.Dice
  | Summon !(Freqs ItemKind) !Dice.Dice
  | Ascend !Int
  | Escape !Int           -- ^ the Int says if can be placed on last level, etc.
  | Paralyze !Dice.Dice
  | InsertMove !Dice.Dice
  | Teleport !Dice.Dice
  | CreateItem !CStore !(GroupName ItemKind) !TimerDice
                          -- ^ create an item of the group and insert into
                          --   the store with the given random timer
  | DropItem !CStore !(GroupName ItemKind) !Bool
                          -- ^ @DropItem CGround x True@ means stomp on items
  | PolyItem !CStore
  | Identify !CStore
  | SendFlying !ThrowMod
  | PushActor !ThrowMod
  | PullActor !ThrowMod
  | DropBestWeapon
  | ActivateInv !Char     -- ^ symbol @' '@ means all
  | ApplyPerfume
    -- Exotic effects follow.
  | OneOf ![Effect]
  | OnSmash !Effect       -- ^ trigger if item smashed (not applied nor meleed)
  | Recharging !Effect    -- ^ this effect inactive until timeout passes
  | Temporary !Text       -- ^ the item is temporary, vanishes at even void
                          --   Periodic activation, unless Durable
  deriving (Show, Read, Eq, Ord, Generic)

data TimerDice =
    TimerNone
  | TimerGameTurn !Dice.Dice
  | TimerActorTurn !Dice.Dice
  deriving (Read, Eq, Ord, Generic)

instance Show TimerDice where
  show TimerNone = "0"
  show (TimerGameTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "turn" else "turns"
  show (TimerActorTurn nDm) =
    show nDm ++ " " ++ if nDm == 1 then "move" else "moves"

-- | Aspects of items. Those that are named @Add*@ are additive
-- (starting at 0) for all items wielded by an actor and they affect the actor.
data Aspect a =
    Periodic           -- ^ in equipment, activate as often as @Timeout@ permits
  | Timeout !a         -- ^ some effects will be disabled until item recharges
  | AddHurtMelee !a    -- ^ percentage damage bonus in melee
  | AddArmorMelee !a   -- ^ percentage armor bonus against melee
  | AddHurtRanged !a   -- ^ percentage damage bonus in ranged
  | AddArmorRanged !a  -- ^ percentage armor bonus against ranged
  | AddMaxHP !a        -- ^ maximal hp
  | AddMaxCalm !a      -- ^ maximal calm
  | AddSpeed !a        -- ^ speed in m/10s
  | AddSkills !Ability.Skills  -- ^ skills in particular abilities
  | AddSight !a        -- ^ FOV radius, where 1 means a single tile
  | AddSmell !a        -- ^ smell radius, where 1 means a single tile
  | AddLight !a        -- ^ light radius, where 1 means a single tile
  deriving (Show, Read, Eq, Ord, Generic, Functor)

-- | Parameters modifying a throw. Not additive and don't start at 0.
data ThrowMod = ThrowMod
  { throwVelocity :: !Int  -- ^ fly with this percentage of base throw speed
  , throwLinger   :: !Int  -- ^ fly for this percentage of 2 turns
  }
  deriving (Show, Read, Eq, Ord, Generic)

-- | Features of item. Affect only the item in question, not the actor,
-- and so not additive in any sense.
data Feature =
    Fragile                 -- ^ drop and break at target tile, even if no hit
  | Durable                 -- ^ don't break even when hitting or applying
  | ToThrow !ThrowMod       -- ^ parameters modifying a throw
  | Identified              -- ^ the item starts identified
  | Applicable              -- ^ AI and UI flag: consider applying
  | EqpSlot !EqpSlot !Text  -- ^ AI and UI flag: goes to inventory
  | Precious                -- ^ can't throw or apply if not calm enough;
                            --   AI and UI flag: don't risk identifying by use
  | Tactic !Tactic          -- ^ overrides actor's tactic (TODO)
  deriving (Show, Eq, Ord, Generic)

data EqpSlot =
    EqpSlotPeriodic
  | EqpSlotTimeout
  | EqpSlotAddHurtMelee
  | EqpSlotAddArmorMelee
  | EqpSlotAddHurtRanged
  | EqpSlotAddArmorRanged
  | EqpSlotAddMaxHP
  | EqpSlotAddMaxCalm
  | EqpSlotAddSpeed
  | EqpSlotAddSkills Ability.Ability
  | EqpSlotAddSight
  | EqpSlotAddSmell
  | EqpSlotAddLight
  | EqpSlotWeapon
  deriving (Show, Eq, Ord, Generic)

instance Hashable Effect

instance Hashable TimerDice

instance Hashable a => Hashable (Aspect a)

instance Hashable ThrowMod

instance Hashable Feature

instance Hashable EqpSlot

instance Binary Effect

instance Binary TimerDice

instance Binary a => Binary (Aspect a)

instance Binary ThrowMod

instance Binary Feature

instance Binary EqpSlot

-- TODO: Traversable?
-- | Transform an aspect using a stateful function.
aspectTrav :: Aspect a -> (a -> St.State s b) -> St.State s (Aspect b)
aspectTrav Periodic _ = return Periodic
aspectTrav (Timeout a) f = do
  b <- f a
  return $! Timeout b
aspectTrav (AddMaxHP a) f = do
  b <- f a
  return $! AddMaxHP b
aspectTrav (AddMaxCalm a) f = do
  b <- f a
  return $! AddMaxCalm b
aspectTrav (AddSpeed a) f = do
  b <- f a
  return $! AddSpeed b
aspectTrav (AddSkills as) _ = return $! AddSkills as
aspectTrav (AddHurtMelee a) f = do
  b <- f a
  return $! AddHurtMelee b
aspectTrav (AddHurtRanged a) f = do
  b <- f a
  return $! AddHurtRanged b
aspectTrav (AddArmorMelee a) f = do
  b <- f a
  return $! AddArmorMelee b
aspectTrav (AddArmorRanged a) f = do
  b <- f a
  return $! AddArmorRanged b
aspectTrav (AddSight a) f = do
  b <- f a
  return $! AddSight b
aspectTrav (AddSmell a) f = do
  b <- f a
  return $! AddSmell b
aspectTrav (AddLight a) f = do
  b <- f a
  return $! AddLight b

toVelocity :: Int -> Feature
toVelocity n = ToThrow $ ThrowMod n 100

toLinger :: Int -> Feature
toLinger n = ToThrow $ ThrowMod 100 n

toOrganGameTurn :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganGameTurn grp nDm = CreateItem COrgan grp (TimerGameTurn nDm)

toOrganActorTurn :: GroupName ItemKind -> Dice.Dice -> Effect
toOrganActorTurn grp nDm = CreateItem COrgan grp (TimerActorTurn nDm)

toOrganNone :: GroupName ItemKind -> Effect
toOrganNone grp = CreateItem COrgan grp TimerNone

-- | Catch invalid item kind definitions.
validateSingleItemKind :: ItemKind -> [Text]
validateSingleItemKind ItemKind{..} =
  [ "iname longer than 23" | T.length iname > 23 ]
  ++ validateRarity irarity
  -- Reject duplicate Timeout and Periodic. Otherwise the behaviour
  -- may not agree with the item's in-game description.
  ++ let periodicAspect :: Aspect a -> Bool
         periodicAspect Periodic = True
         periodicAspect _ = False
         ps = filter periodicAspect iaspects
     in if length ps > 1 then ["more than one Periodic specification"] else []
  ++ let timeoutAspect :: Aspect a -> Bool
         timeoutAspect Timeout{} = True
         timeoutAspect _ = False
         ts = filter timeoutAspect iaspects
     in if length ts > 1 then ["more than one Timeout specification"] else []

-- TODO: if "treasure" stays wired-in, assure there are some treasure items
-- TODO: (spans multiple contents) check that there is at least one item
-- in each ifreq group for each level (thought more precisely we'd need
-- to lookup caves and modes and only check at the levels the caves
-- can appear at).
-- | Validate all item kinds.
validateAllItemKind :: [ItemKind] -> [Text]
validateAllItemKind _ = []
