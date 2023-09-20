{-# LANGUAGE NamedFieldPuns #-}
module Control.Monad.IOSimPOR.Types
  ( -- * Effects
    Effect (..)
  , readEffects
  , writeEffects
  , forkEffect
  , throwToEffect
  , wakeupEffects
  , onlyReadEffect
  , racingEffects
    -- * Schedules
  , ScheduleControl (..)
  , isDefaultSchedule
  , ScheduleMod (..)
    -- * Steps
  , StepId
  , Step (..)
  , StepInfo (..)
    -- * Races
  , Races (..)
  , noRaces
  ) where

import qualified Data.List as List
import           Data.Set (Set)
import qualified Data.Set as Set

import           Control.Monad.IOSim.CommonTypes

--
-- Effects
--

-- | An `Effect` aggregates effects performed by a thread in a given
-- execution step.  Only used by *IOSimPOR*.
--
data Effect = Effect {
    effectReads  :: !(Set TVarId),
    effectWrites :: !(Set TVarId),
    effectForks  :: !(Set ThreadId),
    effectThrows :: ![ThreadId],
    effectWakeup :: ![ThreadId]
  }
  deriving Eq

instance Show Effect where
    show Effect { effectReads, effectWrites, effectForks, effectThrows, effectWakeup } =
      concat $ [ "Effect { " ]
            ++ [ "reads = " ++ show effectReads ++ ", "   | not (null effectReads) ]
            ++ [ "writes = " ++ show effectWrites ++ ", " | not (null effectWrites) ]
            ++ [ "forks = " ++ show effectForks ++ ", "   | not (null effectForks)]
            ++ [ "throws = " ++ show effectThrows ++ ", " | not (null effectThrows) ]
            ++ [ "wakeup = " ++ show effectWakeup ++ ", " | not (null effectWakeup) ]
            ++ [ "}" ]


instance Semigroup Effect where
  Effect r w s ts wu <> Effect r' w' s' ts' wu' =
    Effect (r <> r') (w <> w') (s <> s') (ts ++ ts') (wu++wu')

instance Monoid Effect where
  mempty = Effect Set.empty Set.empty Set.empty [] []

--
-- Effect smart constructors
--

-- readEffect :: SomeTVar s -> Effect
-- readEffect r = mempty{effectReads = Set.singleton $ someTvarId r }

readEffects :: [SomeTVar s] -> Effect
readEffects rs = mempty{effectReads = Set.fromList (map someTvarId rs)}

-- writeEffect :: SomeTVar s -> Effect
-- writeEffect r = mempty{effectWrites = Set.singleton $ someTvarId r }

writeEffects :: [SomeTVar s] -> Effect
writeEffects rs = mempty{effectWrites = Set.fromList (map someTvarId rs)}

forkEffect :: ThreadId -> Effect
forkEffect tid = mempty{effectForks = Set.singleton tid}

throwToEffect :: ThreadId -> Effect
throwToEffect tid = mempty{ effectThrows = [tid] }

wakeupEffects :: [ThreadId] -> Effect
wakeupEffects tids = mempty{effectWakeup = tids}

--
-- Utils
--

someTvarId :: SomeTVar s -> TVarId
someTvarId (SomeTVar r) = tvarId r

onlyReadEffect :: Effect -> Bool
onlyReadEffect e = e { effectReads = effectReads mempty } == mempty

-- | Check if two effects race.  The two effects are assumed to come from
-- different threads, from steps which do not wake one another, see
-- `racingSteps`.
--
racingEffects :: Effect -> Effect -> Bool
racingEffects e e' =

       -- both effects throw to the same threads
       effectThrows e `intersectsL` effectThrows e'

       -- concurrent reads & writes of the same TVars
    || effectReads  e `intersects`  effectWrites e'
    || effectWrites e `intersects`  effectReads  e'

       -- concurrent writes to the same TVars
    || effectWrites e `intersects`  effectWrites e'

  where
    intersects :: Ord a => Set a -> Set a -> Bool
    intersects a b = not $ a `Set.disjoint` b

    intersectsL :: Eq a => [a] -> [a] -> Bool
    intersectsL a b = not $ null $ a `List.intersect` b


---
--- Schedules
---

-- | Modified execution schedule.
--
data ScheduleControl = ControlDefault
                     -- ^ default scheduling mode
                     | ControlAwait [ScheduleMod]
                     -- ^ if the current control is 'ControlAwait', the normal
                     -- scheduling will proceed, until the thread found in the
                     -- first 'ScheduleMod' reaches the given step.  At this
                     -- point the thread is put to sleep, until after all the
                     -- steps are followed.
                     | ControlFollow [StepId] [ScheduleMod]
                     -- ^ follow the steps then continue with schedule
                     -- modifications.  This control is set by 'followControl'
                     -- when 'controlTargets' returns true.
  deriving (Eq, Ord, Show)


isDefaultSchedule :: ScheduleControl -> Bool
isDefaultSchedule ControlDefault        = True
isDefaultSchedule (ControlFollow [] []) = True
isDefaultSchedule _                     = False

-- | A schedule modification inserted at given execution step.
--
data ScheduleMod = ScheduleMod{
    -- | Step at which the 'ScheduleMod' is activated.
    scheduleModTarget    :: StepId,
    -- | 'ScheduleControl' at the activation step.  It is needed by
    -- 'extendScheduleControl' when combining the discovered schedule with the
    -- initial one.
    scheduleModControl   :: ScheduleControl,
    -- | Series of steps which are executed at the target step.  This *includes*
    -- the target step, not necessarily as the last step.
    scheduleModInsertion :: [StepId]
  }
  deriving (Eq, Ord)


-- | Execution step is identified by the thread id and a monotonically
-- increasing number (thread specific).
--
type StepId = (ThreadId, Int)

instance Show ScheduleMod where
  showsPrec d (ScheduleMod tgt ctrl insertion) =
    showParen (d>10) $
      showString "ScheduleMod " .
      showsPrec 11 tgt .
      showString " " .
      showsPrec 11 ctrl .
      showString " " .
      showsPrec 11 insertion

--
-- Steps
--

data Step = Step {
    stepThreadId :: !ThreadId,
    stepStep     :: !Int,
    stepEffect   :: !Effect,
    stepVClock   :: !VectorClock
  }
  deriving Show


--
-- StepInfo
--

-- | As we execute a simulation, we collect information about each step.  This
-- information is updated as the simulation evolves by
-- `Control.Monad.IOSimPOR.Types.updateRaces`.
--
data StepInfo = StepInfo {
    -- | Step that we want to reschedule to run after a step in `stepInfoRaces`
    -- (there will be one schedule modification per step in
    -- `stepInfoRaces`).
    stepInfoStep       :: !Step,

    -- | Control information when we reached this step.
    stepInfoControl    :: !ScheduleControl,

    -- | Threads that are still concurrent with this step.
    stepInfoConcurrent :: !(Set ThreadId),

    -- | Steps following this one that did not happen after it
    -- (in reverse order).
    stepInfoNonDep     :: ![Step],

    -- | Later steps that race with `stepInfoStep`.
    stepInfoRaces      :: ![Step]
  }
  deriving Show

--
-- Races
--

data Races = Races { -- These steps may still race with future steps
                     activeRaces   :: ![StepInfo],
                     -- These steps cannot be concurrent with future steps
                     completeRaces :: ![StepInfo]
                   }
  deriving Show

noRaces :: Races
noRaces = Races [] []
