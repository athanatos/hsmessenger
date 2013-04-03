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
data Reaction i e = Forward | Drop | Trans (State i e)
_notTrans x = case x of
  Trans x -> False
  _ -> True
  
class (Show s, Eq s, MEvent e) => IMState i e s | s -> i e where
  imRun :: s -> IOTree i ()
  imTrans :: s -> e -> Reaction i e
data MState i e =
  forall s. IMState i e s => MState { msState :: s
                                    , msRun :: s -> IOTree i ()
                                    , msTrans :: s -> e -> Reaction i e
                                    }
makeState :: IMState i e s => s -> MState i e
makeState st =
  MState { msState = st
         , msRun = imRun
         , msTrans = imTrans
         }
_msRun state = case state of
  MState a b c -> b a
_msTrans state = case state of
  MState a b c -> c a

data ActivationRecord i e =
  ActivationRecord { arQueue :: TChan e
                   , arStop :: TVar Bool
                   , arState :: MState i e
                   }
_arMake st = do
  q <- newTChan
  s <- newTVar False
  return ActivationRecord { arQueue = q
                          , arStop = s
                          , arState = st
                          }
_arQueueEvent ar e = writeTChan (arQueue ar) e
_arGetEvent ar = do
  empty <- isEmptyTChan $ arQueue ar
  case empty of
    True -> return Nothing
    False -> readTChan (arQueue ar) >>= return . Just
_arStopped ar = readTVar (arStop ar)
_arMapEvent = _msTrans . arState

data StateMachine i e =
  StateMachine { smStop :: TVar Bool
               , smStack :: TVar [ActivationRecord i e]
               }
_smStop sm = writeTVar (smStop sm) True
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
