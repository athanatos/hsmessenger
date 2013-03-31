{-# LANGUAGE
FlexibleContexts,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification #-}
module IOStateMachineR where

import Control.Concurrent.STM
import Control.Concurrent
import Data.Int
import Data.Maybe
import Control.Monad
import Control.Monad.Cont
import Control.Monad.Reader
import Control.Monad.State.Lazy
import Channel

class (Show e, Eq e) => MEvent e

class (Show s, Eq s, MEvent e) => MState_ e s where
  smRun_ :: s -> SR e ()
  smTrans_ :: s -> e -> s

data MState e =
  forall s. MState_ e s => MState { smRun :: s -> SR e ()
                                  , smTrans :: s -> e -> Maybe (MState e)
                                  }

data StateMachine e =
  StateMachine { smQueue :: Channel e
               , smStop :: TVar Bool
               }

makeStateMachine :: IO (StateMachine e)
makeStateMachine = do
  q <- atomically $ makeChannel 10
  s <- atomically $ newTVar False
  return $ StateMachine q s

data SRState e =
  SRState { srCont :: () -> SR e ()
          , srInner :: StateMachine e
          , srOuter :: StateMachine e
          , srOnExit :: IO ()
          , srRunning :: TVar Int
          }

change :: (Int -> Int) -> TVar Int -> STM ()
change f x = do
  cur <- readTVar x
  writeTVar x $ f cur
inc = change $ \x -> x + 1
dec = change $ \x -> x - 1

isZero :: TVar Int -> STM Bool
isZero y = readTVar y >>= \x -> return $ x == 0

type SR e = StateT (SRState e) (ContT () IO)

yield :: SR e ()
yield = do
  state <- get
  done <- liftIO $ atomically $ do
    readTVar $ smStop $ srInner state
  if done
    then (srCont state) ()
    else return ()

deferOnExit :: IO () -> SR e ()
deferOnExit t = do
  cur <- get
  put cur { srOnExit = t >> srOnExit cur }

spawn' :: SR e () -> SRState e -> IO ThreadId
spawn' t state = do
  atomically $ inc $ srRunning state
  forkIO $ do
    counter <- atomically $ newTVar 0
    (`runContT` (\x -> return x)) $ (`evalStateT` (state)) $ do
      callCC $ \x -> do
        put state { srCont = x, srRunning = counter }
        deferOnExit $ atomically $ do
          continue <- isZero counter
          when (not continue) retry
        deferOnExit $ do
          atomically $ dec $ srRunning state
        t
      st <- get
      liftIO $ srOnExit st

spawn :: SR e () -> SR e ()
spawn t = do
  state <- get
  liftIO $ spawn' t state
  return ()
