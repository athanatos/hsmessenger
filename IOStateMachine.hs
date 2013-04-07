{-# LANGUAGE
FlexibleContexts,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification, 
FunctionalDependencies #-}
module IOStateMachineR where

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
_notTrans x = case x of
  Trans x -> False
  _ -> True
  
data MState e =
  MState { _msRun :: StateMachine e -> IOTree ()
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
_smPush sm ar = do
  st <- readTVar (smStack sm)
  writeTVar (smStack sm) (ar : st)
_smPop sm = readTVar (smStack sm) >>= (writeTVar (smStack sm)) . tail
_smHandle sm e = do
  st <- readTVar (smStack sm)
  case (span (_notTrans . (`_msTrans` e) . arState ) st) of
    (_, []) -> return ()
    (done, x:xs) -> do
      sequence_ $ (`map` done) $ \todone -> do
        writeTVar (arStop todone) True
      writeTVar (smStack sm) (x:xs)
      _arQueueEvent x e
