{-# LANGUAGE FlexibleContexts, TypeFamilies #-}
module IOStateMachineR where

import Control.Concurrent.STM
import Data.Int
import Data.Maybe
import Control.Monad
import Control.Monad.Cont
import Control.Monad.State.Lazy
import Channel

class (Eq e, Show e) => Event e

data SRState =
  SRState { srCont :: () -> SR ()
          }

type SR = StateT SRState (ContT () IO)

yield :: SR ()
yield = do
  callCC $ \cc -> do
    (SRState escape) <- get
    put $ SRState cc
    escape ()
    return ()
  return ()

spawn :: SR () -> SR ()
spawn t = do
  (SRState exit) <- get
  callCC $ \cc -> do
    callCC $ \c2 -> do
      put $ SRState c2
      cc ()
    t
    exit ()

runSR :: SR () -> IO ()
runSR = y . x . wrap
  where
    x = (`evalStateT` (SRState (\x -> return x)))
    y = (`runContT` (\x -> (return :: () -> IO ()) x))
    wrap t = do
      callCC $ \x -> do
        put $ SRState x
        t

x = do
  liftIO $ print "hi"
  yield
  liftIO $ print "ho"
  yield

y = do
  spawn x
  liftIO $ print "1"
  yield
  liftIO $ print "2"
  yield
  liftIO $ print "3"

z = do
  runSR y

--x = do
--  o <- callCC $ \c1 -> (`evalStateT` c1) $ do
--    y <- get
--    return $ callCC $ \c2 -> do
--      y c2
--      return c2
--  return o

data CCont = CCont (Maybe (() -> SR CCont))

class (Eq s, Show s) => MState s where
  type Info s :: *
  sEnter :: s -> IO ()
  sRun :: s -> SR CCont
  sExit :: s -> IO ()

--doNext :: CCont -> ISR CCont
--doNext (CCont cont) = do
--  case cont of
--    Nothing -> return $ CCont Nothing
--    Just _cont ->
--      callCC $ \x -> (`evalStateT` x) $ do
--        _cont ()

data StateMachine e s =
  StateMachine { smTable :: s -> e -> s
               , smPendingEvts :: Channel e
               }

makeStateMachine :: Event e => MState s =>
                     s -> (s -> e -> s) -> IO (StateMachine e s)
makeStateMachine start table = do
  chan <- atomically $ makeChannel 10
  return $ StateMachine { smTable = table
                        , smPendingEvts = chan
                        }

nextState :: MState s => Event e => StateMachine e s -> s -> STM (Maybe s)
nextState mach state = do
  evt <- tryGetItem $ smPendingEvts mach
  case evt of
    Just x -> return $ Just $ (smTable mach) state x
    Nothing -> return Nothing

loopState :: MState s => Event e => StateMachine e s -> s -> IO (Maybe s)
loopState mach state = do
  nstate <- atomically $ nextState mach state
  case nstate of
    Just x -> return nstate
    Nothing -> return Nothing
      

runState :: MState s => Event e => StateMachine e s -> s -> IO ()
runState mach state = do
  sEnter state
  newState <- loopState mach state
  sExit state
  return ()
  where
    table = smTable mach
