{-# LANGUAGE TypeFamilies #-}
module TCPTransport ( TCPTransport
                    , TCPEntity
                    , TCPConnection
                    , tcpEntityFromStr
                    , tcpEntityFromStrWPort
                    ) where

import qualified Data.Binary as DP
import qualified Network.Socket.ByteString.Lazy as BSS
import qualified Network.Socket as S
import qualified Data.ByteString.Lazy as BS
import qualified Control.Concurrent.STM as STM
import qualified Data.Map as M
import qualified System.IO as SIO
import qualified Data.Binary as DP
import qualified Control.Exception as CE
import qualified Control.Concurrent.MVar as CM
import qualified Data.List as DL
import Control.Concurrent
import Data.Int
import Data.Maybe
import Control.Monad

import qualified Transport as T
import qualified TCPTransportMessages as TM
import qualified Channel as C

import TCPTransportTypes

-- States
sOpen trans conn = MState {
  msInit = return $ do
     yield
     sock <- liftIO $ S.socket (family trans) S.Stream S.defaultProtocol
     liftIO $ S.connect sock (entityAddr $ connPeer conn)
     liftIO $ TM.sput sock $ TM.MSGRequestConn { TM.rlastSeqReceived = 0 }
     resp <- liftIO $ TM.sget (undefined :: TM.PayloadHeader) sock
     case TM.pAction resp of
       TM.ReqClose -> do
         liftIO $ TM.sput sock $ TM.PayloadHeader { TM.pAction = TM.ConfClose
                                                  , TM.pLength = 0
                                                  , TM.plastSeqReceived = 0 }
         S.sClose sock
       TM.ConfOpen -> do
         
      next

sClose :: TCPTransport -> TCPConnection -> IO ()
sClose trans conn = do
  sock <- STM.atomically $ STM.readTVar (socket conn)
  case sock of
    Nothing -> return ()
    Just _sock -> doclose _sock
  STM.atomically $ do
    STM.writeTVar (socket conn) Nothing
    STM.writeTVar (connStatus conn) Closed

sAccept :: TCPTransport -> TCPConnection -> IO ()
sAccept trans conn = do
  next <- STM.atomically $ do
    state <- STM.readTVar $ connStatus conn
    case state of
      Accepting -> do
        _sock <- STM.readTVar $ socket conn
        case _sock of
          Just sock -> do
            STM.writeTVar (connStatus conn) Open
            return $ do
              acceptSock sock
              selectState [Open] Open trans conn
          Nothing -> return $ CE.throwIO $ TCPLogicException (
            "state " ++ (show state) ++ " must have socket!"
            )
      _ -> return $ do
        selectState [Accepting, Closing] state trans conn
  next
  where
    acceptSock sock = do
      req <- TM.sget (undefined :: TM.MSGRequestConn) sock
      TM.sput sock $ TM.PayloadHeader { TM.pAction = TM.ConfOpen
                                      , TM.pLength = 0
                                      , TM.plastSeqReceived = 0
                                      }

data ReaderStat = Run | Stop | Stopped
sRunning :: TCPTransport -> TCPConnection -> IO ()
sRunning trans conn = do
  stopReader <- STM.atomically $ STM.newTVar Run
  return ()

sNew :: TCPTransport -> TCPConnection -> IO ()
sNew trans conn = do
  state <- STM.atomically $ do
    _state <- STM.readTVar $ connStatus conn
    case _state of
      New -> STM.retry
      _ -> return _state
  selectState [Opening, Accepting, Closing] state trans conn

selectState :: [Status] -> Status -> TCPTransport -> TCPConnection -> IO ()
selectState statuses status = 
  if status `elem` statuses
  then case status of
    New -> sNew
    Opening -> sOpen
    Accepting -> sAccept
    Open -> sRunning
    Closing -> sClose
    Closed -> \_ _ -> return ()
  else CE.throw $ TCPLogicException (
    "_state " ++ (show status) ++ " not valid here"
    )

-- Utility
doclose :: S.Socket -> IO ()
doclose sock = do
  TM.sput sock $ TM.PayloadHeader { TM.pAction = TM.ReqClose
                                  , TM.pLength = 0
                                  , TM.plastSeqReceived = 0
                                  }
  waitClose
  S.sClose sock
  where
    waitClose = do
      msg <- TM.getMsg sock
      case TM.mAction msg of
        TM.ConfClose -> return ()
        _ -> waitClose

doaccept :: TCPTransport -> S.Socket -> S.SockAddr -> IO ()
doaccept trans socket addr = do
  req <- TM.sget (undefined :: TM.MSGRequestConn) socket
  (msock, newconn, new) <- STM.atomically $ do
    (newconn, new) <- getAddConnection trans entity
    msock <- maybeAcceptSocket newconn socket
    return (msock, newconn, new)
  when new $ do
    forkIO $ sNew trans newconn
    return ()
  case msock of
    Nothing -> return ()
    Just sock -> forkIO (doclose sock) >> return ()
  return ()
  where
    entity = TCPEntity { entityAddr = addr }

accepter :: TCPTransport -> IO ()
accepter trans = do
  sock <- S.socket (family trans) S.Stream S.defaultProtocol
  S.bindSocket sock (sockAddr trans)
  S.listen sock 0
  forever $ do
    (csock, caddr) <- S.accept sock
    forkIO $ doaccept trans csock caddr
    return ()

bindTransport :: TCPTransport -> IO ()
bindTransport trans = do
  accepter trans

--instance T.Transport TCPTransport where
--  type Entity TCPTransport = TCPEntity
--  type Connection TCPTransport = TCPConnection
--  makeTransport = makeTransport
--  startTransport = \x -> return ()
--  getConnection = getConnection
--  queueMessage = queueMessage
--  queueMessageEntity = queueMessageTCPEntity
--  bind = bindTransport
