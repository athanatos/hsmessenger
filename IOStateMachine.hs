{-# LANGUAGE
FlexibleContexts,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification, 
FunctionalDependencies #-}
module IOStateMachineR where

import Control.Concurrent.STM
import Control.Concurrent hiding (yield)
import Data.Int
import Data.Maybe
import Control.Monad
import Control.Monad.Cont
import Control.Monad.Reader
import Control.Monad.State.Lazy
import Channel
import IOTree

class (Show e, Eq e) => MEvent e
class (Show s, Eq s, MEvent e) => IMState i e s | s -> i e where
  smRun :: s -> IOTree i ()
  smTrans :: s -> e -> Maybe (MState e)
data MState i e =
  forall s. IMState i e s => MState { smState_ :: s
                                    , smRun_ :: s -> IOTree i ()
                                    , smTrans_ :: s -> e -> Maybe (MState e)
                                    }
makeState :: IMState i e s => s -> MState i e
makeState st =
  MState { smState_ = st
         , smRun_ = smRun
         , smTrans_ = smTrans
         }
_smRun :: MState i e -> IOTree i ()
_smRun state = case state of
  MState a b c -> b a
_smTrans :: MState i e -> (e -> Maybe (MState i e))
_smTrans' state = case state of
  MState a b c -> c a

data StateMachine e =
  StateMachine { smQueue :: Channel e
               , smStop :: TVar Bool
               }

makeStateMachine' :: IO (StateMachine e)
makeStateMachine' = do
  q <- atomically $ makeChannel 10
  s <- atomically $ newTVar False
  return $ StateMachine q s

runStateMachine' :: StateMachine e -> MState e -> SR e ()
runStateMachine' sm st = do
  liftIO $ atomically $ do
    return ()
  where
    trans = smTrans' st
    run = smTrans' st
    chan = smQueue sm
    check = do
      if not $ channelEmpty chan
        then 
