{-# LANGUAGE FlexibleContexts, TypeFamilies, MultiParamTypeClasses #-}
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

class (Eq e, Show e) => Event e

data SRState e s =
  SRState { srCont :: () -> SR e s ()
          , srDone :: TVar Bool
          , srStateMachine :: StateMachine e s
          }

type SR e s = StateT (SRState e s) (ContT () IO)

yield :: SR e s ()
yield = do
  state <- get
  done <- liftIO $ atomically $ do
    readTVar $ srDone state
  if done
    then (srCont state) ()
    else return ()

spawn' :: SR e s () -> SRState e s -> IO ()
spawn' t state = do
  forkIO $ do
      (`runContT` (\x -> return x)) $ (`evalStateT` (state)) $ callCC $ \x -> do
        put state { srCont = x }
        t
  return ()

spawn :: SR e s () -> SR e s ()
spawn t = do
  state <- get
  liftIO $ spawn' t state

class (Eq s, Show s, Event e) => MState s e where
  type Info s :: *
  sEnter :: s -> IO ()
  sRun :: s -> SR e s ()
  sExit :: s -> IO ()

data StateMachine e s =
  StateMachine { smTable :: s -> e -> s
               , smPendingEvts :: Channel e
               }

makeStateMachine :: Event e => MState s e =>
                     s -> (s -> e -> s) -> IO (StateMachine e s)
makeStateMachine start table = do
  chan <- atomically $ makeChannel 10
  return $ StateMachine { smTable = table
                        , smPendingEvts = chan
                        }

nextState :: MState s e => Event e => StateMachine e s -> s -> STM (Maybe s)
nextState mach state = do
  evt <- tryGetItem $ smPendingEvts mach
  case evt of
    Just x -> return $ Just $ (smTable mach) state x
    Nothing -> return Nothing

loopState :: MState s e => Event e => StateMachine e s -> s -> IO (Maybe s)
loopState mach state = do
  nstate <- atomically $ nextState mach state
  case nstate of
    Just x -> return nstate
    Nothing -> return Nothing
      

runState :: MState s e => Event e => StateMachine e s -> s -> IO ()
runState mach state = do
  --sEnter state
  newState <- loopState mach state
  --sExit state
  return ()
  where
    table = smTable mach
