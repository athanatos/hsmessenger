{-# LANGUAGE
FlexibleContexts,
FlexibleInstances,
TypeFamilies,
MultiParamTypeClasses,
ExistentialQuantification #-}
module IOTree ( IOTree
              , waitStopped
              , stopChild
              , stopWaitChild
              , runIOTree
              , spawnIOTree
              , lSpawnIOTree
              , lSpawnNamedIOTree
              , maybeStop
              , waitDone
              , stopOrRun
              , deferOnExit
              , spawn
              , liftIO
              , wDebug
              , wError
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
import System.Log.Logger

type SR = StateT SRState (ContT () IO)

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

data SRState =
  SRState { srChild :: Child
          , srCont :: () -> SR ()
          , srOnExit :: [SRState -> IO ()]
          , srCMap :: TVar (M.Map ThreadId Child)
          , srName :: [String]
          }
_getName :: SR String
_getName = do
  st <- get
  case srName st of
    [] -> return ""
    x:xs -> return $ concat $ x : (map ('.' :) xs)

_makeEmptySRState :: STM SRState
_makeEmptySRState = do
  c <- _makeEmptyChild
  a <- newTVar M.empty
  return $ SRState { srChild = c
                   , srCont = return
                   , srOnExit = []
                   , srCMap = a
                   , srName = []
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

newtype IOTree a = IOTree (SR a)
_down (IOTree a) = a
instance Monad IOTree where
  a >>= f = IOTree $ _down a >>= \x -> _down $ f x
  return x = IOTree (return x)

instance MonadIO IOTree where
  liftIO x = IOTree (liftIO x)

_runSR :: SR () -> SRState -> IO ()
_runSR t s = (`runContT` return) $ (`evalStateT` s) $ t

runIOTree :: IOTree () -> IO ()
runIOTree b = atomically _makeEmptySRState >>= _runIOTree b >> return ()

lSpawnNamedIOTree :: [String] -> IOTree () -> STM (Child, IO ())
lSpawnNamedIOTree tag b = do
  st <- _makeEmptySRState >>= (\x -> return $ x { srName = tag })
  return (srChild st, (forkIO $ _runIOTree b st) >> return ())

lSpawnIOTree :: IOTree () -> STM (Child, IO ())
lSpawnIOTree b = do
  st <- _makeEmptySRState
  return (srChild st, (forkIO $ _runIOTree b st) >> return ())

spawnIOTree :: IOTree () -> IO (Child, ThreadId)
spawnIOTree b = do
  st <- atomically _makeEmptySRState
  tid <- forkIO $ _runIOTree b st
  return $ (srChild st, tid)

spawnNamedIOTree :: [String] -> IOTree () -> IO (Child, ThreadId)
spawnNamedIOTree name t = do
  st <- (atomically _makeEmptySRState) >>= (\x -> return $ x { srName = name })
  tid <- forkIO $ _runIOTree t st
  return $ (srChild st, tid)

_runIOTree (IOTree t) news = do
  (`_runSR` news) $ do
    callCC $ \x -> do
      modify $ \y -> y { srCont = x }
      _deferOnExit $ atomically $ _completeStop $ srChild news
      _deferOnExitWState _stopChildren
      t
    st <- get
    sequence_ $ map (\x -> get >>= \y -> liftIO $ x y) (srOnExit st)
  return ()

waitDone :: IOTree a
waitDone = IOTree $ do
  state <- get
  liftIO $ atomically $ do
    done <- readTVar $ cStop $ srChild state
    when (not done) retry
  srCont state ()
  return (undefined :: a) -- can't happen

maybeStop :: IOTree ()
maybeStop = IOTree $ do
  state <- get
  done <- liftIO $ atomically $ do
    readTVar $ cStop $ srChild state
  if done
    then (srCont state) ()
    else return ()

stopOrRun :: STM a -> IOTree a
stopOrRun t = IOTree $ do
  state <- get
  join $ liftIO $ atomically $ do
    done <- readTVar $ cStop $ srChild state
    case done of
      True -> return $ do
        srCont state ()
        return (undefined :: a) -- this will never happen
      False -> t >>= (return . return)

deferOnExit :: IO () -> IOTree ()
deferOnExit t = IOTree $ _deferOnExit t
_deferOnExit t =
  modify $ \cur -> cur { srOnExit = (\_->t):(srOnExit cur) }
_deferOnExitWState t = do
  cur <- get
  put cur { srOnExit = t:(srOnExit cur) }

spawn :: IOTree () -> IOTree Child
spawn t = IOTree $ do
  state <- get
  gate <- liftIO $ atomically $ newTVar False
  (newc, tid) <- liftIO $ spawnNamedIOTree (srName state) $ do
    liftIO $ atomically $ do
      go <- readTVar gate
      when (not go) retry
    t
  liftIO $ atomically $ _insertTid state tid newc
  liftIO $ atomically $ writeTVar gate True
  return newc

wDebug :: String -> IOTree ()
wDebug msg = IOTree $ do
  tag <- _getName
  liftIO $ debugM tag (tag ++ ": " ++ msg)

wError :: String -> IOTree ()
wError msg = IOTree $ do
  tag <- _getName
  liftIO $ errorM tag (tag ++ ": " ++ msg)
