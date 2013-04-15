{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, 
TemplateHaskell, DeriveGeneric #-}

import qualified TCPTransport as TCPT
import qualified Transport as T
import qualified Messenger as MSGR
import Data.Int
import GHC.Generics
import System.Environment
import Data.Serialize
import qualified Data.ByteString.Lazy as BS
import qualified Control.Concurrent.MVar as CM
import Control.Concurrent.STM.TChan
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import System.Log.Logger
import Debug.Trace

data Msg =
  Msg { msgNum      :: Int64
      , msgContents :: String
      }
  deriving (Generic)
instance Serialize Msg

eAction msgr conn err = do
  Just $ return ()

mAction q msgr conn msg = Just $ do
  writeTChan q (msgr, conn, msg)
  return ()

cActR q var = do
  (msgr, conn, msg) <- atomically $ readTChan q
  print $ "Got msg " ++ (msgContents msg)
  CM.putMVar var 0
  
sActR q = forever $ do
  (msgr, conn, msg) <- atomically $ readTChan q
  print $ "Got msg " ++ (msgContents msg)
  MSGR.queueMessageConn msgr conn (Msg { msgNum = 1, msgContents = "Pong" } )
  return ()

client :: String -> String -> Int -> IO ()
client self target port = do
  selfAddr <- TCPT.tcpEntityFromStr self
  q <- atomically newTChan
  var <- CM.newMVar 0
  _ <- CM.takeMVar var
  msgr <- (MSGR.makeMessenger selfAddr $ MSGR.MConfig {
              MSGR.transType = T.Client,
              MSGR.msgHandler = [mAction q],
              MSGR.onError = [eAction],
              MSGR.handleConnect = \_ _ -> return (),
              MSGR.faultPolicy = \_ _ -> T.Reconnect
              }
          ) :: IO (MSGR.Messenger (TCPT.TCPTransport ()) Msg)
  targetAddr <- TCPT.tcpEntityFromStrWPort target port
  MSGR.queueMessageEntity msgr targetAddr
    (Msg { msgNum = 0, msgContents = "Ping" } )
  forkIO $ cActR q var
  _ <- CM.takeMVar var
  return ()

server :: String -> Int -> IO ()
server self port = do
  q <- atomically newTChan
  selfAddr <- TCPT.tcpEntityFromStrWPort self port
  msgr <- (MSGR.makeMessenger selfAddr $ MSGR.MConfig {
              MSGR.transType = T.Server,
              MSGR.msgHandler = [mAction q], 
              MSGR.onError = [eAction],
              MSGR.handleConnect = \_ _ -> return (),
              MSGR.faultPolicy = \_ _ -> T.Reconnect
              }
          ) :: IO (MSGR.Messenger (TCPT.TCPTransport ()) Msg)
  forkIO $ sActR q
  MSGR.start msgr
  return ()

main = do
  updateGlobalLogger "" $ setLevel DEBUG
  args <- getArgs
  case args of
    ["client", self, shost, sport] -> client self shost (read sport)
    ["server", shost, sport] -> server shost (read sport)
    _ -> print "Error"
