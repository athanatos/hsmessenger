{-# LANGUAGE
FlexibleContexts,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification, 
FunctionalDependencies #-}
module IOStateMachine ( Reaction
                      , MState
                      , StateMachine
                      , handleEvent
                      , handleEventIO
                      , createMachine
                      , createMachineIO
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

class (Show e, Eq e) => MEvent e
data Reaction e = Forward | Drop | Trans (MState e)
data MState e =
  MState { _msRun :: IOTree ()
         , _msTrans :: e -> Reaction e
         , _msSubState :: Maybe (MState e)
         }

data ActivationRecord e =
  ActivationRecord { _arState :: MState e
                   , _arCleanup :: IOTree ()
                   }
_arMapEvent = _msTrans . _arState

data StateMachine e =
  StateMachine { smStack :: TVar [ActivationRecord e]
               }

createMachine :: MState e -> STM (StateMachine e, IO ())
createMachine st = do
  ars <- newTVar []
  sm <- return $ StateMachine ars
  todo <- _enterState sm [] [] st
  return (sm, todo)

createMachineIO :: MState e -> IO (StateMachine e)
createMachineIO st = do
  (sm, todo) <- atomically $ createMachine st
  todo
  return sm

handleEvent :: StateMachine e -> e -> STM (IO ())
handleEvent sm e = do
  st <- readTVar (smStack sm)
  case span isForward $ toReactions e $ st of
    (_, []) -> return $ return ()
    (done, (ar,x):xs) -> case x of
      Trans state -> _enterState sm (ar:(map fst done)) (map fst xs) state
      _ -> return $ return ()
  where
    isForward (_, x) = case x of
      Forward -> True
      _ -> False
    toReactions e = map $ \x -> (x, (`_msTrans` e) $ _arState x)

handleEventIO :: StateMachine e -> e -> IO ()
handleEventIO sm ev = join $ atomically $ handleEvent sm ev

_enterState :: StateMachine e -> [ActivationRecord e] -> [ActivationRecord e] ->
               MState e -> STM (IO ())
_enterState sm done notdone state = do
  setup <- setupRun $ subSt state
  ars <- return $ toArs setup
  writeTVar (smStack sm) ((map fst ars) ++ notdone)
  return $ do
    runIOTree $ sequence_ $ map _arCleanup done
    sequence_ $ map snd ars
  where
    subSt st = (`unfoldr` st) $ \x -> do
      sub <- (_msSubState x)
      return (sub, sub)
    setupRun sts = sequence $ (`map` sts) $ \x -> do
      (child, t) <- lSpawnIOTree $ _msRun x
      return (x, (liftIO $ atomically $ stopChild child, t))
    toArs =
      map (\(st, (cleanup, run)) -> (ActivationRecord st cleanup, run))
    run sts = sequence_ $ map _msRun sts
