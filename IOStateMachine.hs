{-# LANGUAGE
FlexibleContexts,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification, 
FunctionalDependencies #-}
module IOStateMachine ( Reaction(Forward, Drop, Handle, Trans)
                      , MEvent
                      , MState(MState, msRun, msTrans, msSubState, msDesc)
                      , StateMachine
                      , handleEvent
                      , handleEventIO
                      , createMachine
                      , createMachineIO
                      , stopMachine
                      ) where

import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Concurrent hiding (yield)
import Data.Int
import Data.List
import Data.Maybe
import Control.Monad
import Control.Monad.Cont
import Control.Monad.Reader
import Control.Monad.State.Lazy
import IOTree

class (Show e) => MEvent e
data Reaction e = Forward | Drop | Handle (e -> IOTree ()) | Trans (MState e)
data MState e =
  MState { msRun :: IOTree ()
         , msTrans :: e -> Reaction e
         , msSubState :: Maybe (MState e)
         , msDesc :: String
         }
instance Show (MState e) where
  show = msDesc

data ActivationRecord e =
  ActivationRecord { _arState :: MState e
                   , _arCleanup :: IOTree ()
                   }
_arMapEvent = msTrans . _arState

data StateMachine e =
  StateMachine { smStack :: TVar [ActivationRecord e]
               , smName :: [String]
               }

createMachine :: [String] -> MState e -> STM (StateMachine e, IO ())
createMachine name st = do
  ars <- newTVar []
  sm <- return $ StateMachine ars name
  todo <- _enterState sm [] [] st
  return (sm, todo)

stopMachine :: StateMachine e -> STM (IOTree ())
stopMachine sm = do
  st <- readTVar (smStack sm)
  cleanup <- return $ sequence_ $ map _arCleanup st
  writeTVar (smStack sm) []
  return cleanup

createMachineIO :: MEvent e => [String] -> MState e -> IO (StateMachine e)
createMachineIO name st = do
  (sm, todo) <- atomically $ createMachine name st
  todo
  return sm

handleEvent :: MEvent e => StateMachine e -> e -> STM (IO ())
handleEvent sm e = do
  st <- readTVar (smStack sm)
  case span isForward $ toReactions e $ st of
    (_, []) -> return $ return ()
    (done, (ar,x):xs) -> case x of
      Trans state -> _enterState sm (ar:(map fst done)) (map fst xs) state
      Handle handler -> return (runIOTree $ handler e)
      _ -> return $ return ()
  where
    isForward (_, x) = case x of
      Forward -> True
      _ -> False
    toReactions e = map $ \x -> (x, (`msTrans` e) $ _arState x)

handleEventIO :: MEvent e => StateMachine e -> e -> IO ()
handleEventIO sm ev = join $ atomically $ handleEvent sm ev

_enterState :: StateMachine e -> [ActivationRecord e] -> [ActivationRecord e] ->
               MState e -> STM (IO ())
_enterState sm done notdone state = do
  sts <- return $ subSt state
  setup <- setupRun (zip (tail $ reverse $ tails (map msDesc sts)) sts)
  ars <- return $ toArs setup
  writeTVar (smStack sm) ((map fst ars) ++ notdone)
  return $ do
    runIOTree $ sequence_ $ map _arCleanup done
    sequence_ $ map snd ars
  where
    subSt st = reverse $ (st :) $ (`unfoldr` st) $ \x -> do
      sub <- (msSubState x)
      return (sub, sub)
    setupRun sts = sequence $ (`map` sts) $ \(name, x) -> do
      (child, t) <- lSpawnNamedIOTree
                    ((smName sm) ++
                     (reverse $ map (msDesc . _arState) notdone) ++
                     (reverse name)) $ do
        wDebug "Entering State"
        msRun x
      return (x, (liftIO $ atomically $ stopChild child, t))
    toArs =
      map (\(st, (cleanup, run)) -> (ActivationRecord st cleanup, run))
    run sts = sequence_ $ map msRun sts
