{-# LANGUAGE
FlexibleContexts,
FlexibleInstances,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification #-}
module IOTree ( waitStopped
              , stopChild
              , stopWaitChild
              , runIOTree
              , spawnIOTree
              , yield
              , deferOnExit
              , deferOnExitWState
              , spawn
              ) where

import Control.Concurrent.STM
import Control.Concurrent hiding (yield)
import Data.Int
import Data.Maybe
import qualified Data.Map as M
import Control.Monad
import Control.Monad.Cont
import Control.Monad.Reader.Class
import Control.Monad.State.Lazy
import Channel

type SR s = StateT (SRState s) (ContT () IO)

data Child =
  Child { cStop :: TVar Bool
        , cStopped :: TVar Bool
        }
_makeEmptyChild :: STM Child
_makeEmptyChild = do
  cStop <- newTVar False
  cStopped <- newTVar False
  return $ Child { cStop = cStop
                 , cStopped = cStopped
                 }

waitStopped :: Child -> STM ()
waitStopped c = do
  val <- readTVar $ cStop c
  when (not val) retry

stopChild :: Child -> STM ()
stopChild c = writeTVar (cStop c) True

stopWaitChild :: Child -> IO ()
stopWaitChild c = sequence_ $ map (atomically . ($ c)) [stopChild, waitStopped]

_completeStop :: Child -> STM ()
_completeStop c = writeTVar (cStopped c) True

_isDone :: Child -> STM Bool
_isDone c = readTVar (cStop c)

data SRState s =
  SRState { srChild :: Child
          , srCont :: () -> SR s ()
          , srOnExit :: [SRState s -> IO ()]
          , srContents :: s
          , srCMap :: TVar (M.Map ThreadId Child)
          }
_makeEmptySRState :: s -> IO (SRState s)
_makeEmptySRState s = do
  c <- atomically _makeEmptyChild
  a <- atomically $ newTVar M.empty
  return $ SRState { srChild = c
                   , srCont = return
                   , srOnExit = []
                   , srContents = s
                   , srCMap = a
                   }
_insertTid sr tid child = do
  m <- readTVar $ srCMap sr
  writeTVar (srCMap sr) (M.insert tid child m)
_eraseTid sr tid = do
  m <- readTVar $ srCMap sr
  writeTVar (srCMap sr) (M.delete tid m)
_stopChildren sr = do
  m <- atomically $ readTVar $ srCMap sr
  sequence_ $ map stopWaitChild (M.elems $ m)

_makeSubSRState :: Child -> SRState s -> SRState s
_makeSubSRState c old =
  old { srChild = c, srOnExit = [], srCont = return }

newtype IOTree s a = IOTree (SR s a)
_down (IOTree a) = a
instance Monad (IOTree s) where
  a >>= f = IOTree $ _down a >>= \x -> _down $ f x
    
  return x = IOTree (return x)

instance MonadIO (IOTree s) where
  liftIO x = IOTree (liftIO x)

instance MonadReader s (IOTree s) where
  ask = IOTree $ do
    st <- get
    return $ srContents st
  local f (IOTree t) = IOTree $ do
    st <- get
    put st { srContents = f $ srContents st }
    x <- t
    put st
    return x

_runSR :: SR s () -> SRState s -> IO ()
_runSR t s = (`runContT` return) $ (`evalStateT` s) $ t

runIOTree :: s -> IOTree s () -> IO ()
runIOTree a b = _makeEmptySRState a >>= _runIOTree a b >> return ()
spawnIOTree :: s -> IOTree s () -> IO Child
spawnIOTree a b = do
  st <- _makeEmptySRState a
  forkIO $ _runIOTree a b st
  return $ srChild st
_runIOTree s (IOTree t) news = do
  (`_runSR` news) $ do
    callCC $ \x -> do
      modify $ \y -> y { srCont = x }
      _deferOnExitWState _stopChildren
      t
    st <- get
    sequence_ $ map (\x -> get >>= \y -> liftIO $ x y) (srOnExit st)
  return ()

yield :: IOTree s ()
yield = IOTree $ do
  state <- get
  done <- liftIO $ atomically $ do
    readTVar $ cStop $ srChild state
  if done
    then (srCont state) ()
    else return ()

deferOnExit :: IO () -> IOTree s ()
deferOnExit t = IOTree $ _deferOnExit t
_deferOnExit t =
  modify $ \cur -> cur { srOnExit = (\_->t):(srOnExit cur) }

deferOnExitWState :: (s -> IO ()) -> IOTree s ()
deferOnExitWState t = IOTree $ _deferOnExitWState (\st -> t $ srContents st)
_deferOnExitWState t = do
  cur <- get
  put cur { srOnExit = t:(srOnExit cur) }

spawn :: IOTree s () -> IOTree s Child
spawn (IOTree t) = IOTree $ do
  state <- get
  gate <- liftIO $ atomically $ newTVar False
  (c, tid) <- liftIO $ do 
    newc <- atomically _makeEmptyChild
    tid <- forkIO $ do
      atomically $ do
        go <- readTVar gate
        when (not go) retry
      (`_runSR` (_makeSubSRState newc state)) $ do
        callCC $ \x -> do
          modify $ \y -> y { srCont = x }
          _deferOnExit $ do
            tid <- myThreadId
            liftIO $ atomically $ _eraseTid state tid
          _deferOnExitWState _stopChildren
          t
        st <- get
        sequence_ $ map (\x -> get >>= \y -> liftIO $ x y) (srOnExit st)
    return (newc, tid)
  liftIO $ atomically $ _insertTid state tid c
  liftIO $ atomically $ writeTVar gate True
  return c

