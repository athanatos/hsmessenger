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
class (Show s, Eq s, MEvent e) => IMState e s where
  smRun :: s -> SR e ()
  smTrans :: s -> e -> Maybe (MState e)
data MState e =
  forall s. IMState e s => MState { smState_ :: s
                                  , smRun_ :: s -> SR e ()
                                  , smTrans_ :: s -> e -> Maybe (MState e)
                                  }
makeState :: IMState e s => s -> MState e
makeState st =
  MState { smState_ = st
         , smRun_ = smRun
         , smTrans_ = smTrans
         }
smRun' :: MState e -> SR e ()
smRun' state = case state of
  MState a b c -> b a
smTrans' :: MState e -> (e -> Maybe (MState e))
smTrans' state = case state of
  MState a b c -> c a

data SRState e s =
  SRState { srCont :: () -> SR e ()
          , srOnExit :: IO ()
          , srRunning :: TVar Int
          , srContents :: s
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

runSR :: SR e () -> SRState e -> IO ()
runSR t s = (`runContT` (\x -> return x)) $ (`evalStateT` s) $ t

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

spawn :: SR e () -> SR e ()
spawn t = do
  state <- get
  liftIO $ atomically $ inc $ srRunning state
  liftIO $ forkIO $ do
    counter <- atomically $ newTVar 0
    (`runSR` state) $ do
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
  return ()

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
        
