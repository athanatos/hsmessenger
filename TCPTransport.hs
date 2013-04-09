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
import IOStateMachine
import IOTree

import TCPTransportTypes

-- States
sOpen trans conn = MState
  { msRun = do
       maybeStop
       sock <- liftIO $ S.socket (family trans) S.Stream S.defaultProtocol
       deferOnExit $ S.sClose sock
       liftIO $ S.connect sock (entityAddr $ connPeer conn)
       liftIO $ TM.sput sock $ TM.MSGRequestConn { TM.rlastSeqReceived = 0 }
       resp <- liftIO $ TM.readMsg sock
       case resp of
         TM.Payload _ _ -> CE.throw TM.RecvErr
         TM.Control TM.ReqClose -> do
           liftIO $ TM.writeCont sock TM.ConfClose
           (stopOrRun $ handleEvent (connStatus conn) TReset) >>= liftIO
         TM.Control TM.ConfOpen -> do
           (stopOrRun $ handleEvent (connStatus conn) $ TOpened sock) >>= liftIO
         _ -> CE.throw TM.RecvErr
  , msTrans = \evt -> case evt of
       TReset -> Trans $ sOpen trans conn
       TAccept sock -> Trans $ sAccept trans conn sock
       _ -> CE.throw TM.RecvErr
  , msSubState = Just $ sWaitSocket trans conn
  }

sAccept trans conn sock = MState
 { msRun = do
      return ()
 , msTrans = \_ -> Forward
 , msSubState = Just $ sRunning trans conn sock
 }

sWaitSocket trans conn = MState
  { msRun = return ()
  , msTrans = \evt -> case evt of
       TOpened sock -> Trans $ sRunning trans conn sock
       _ -> Forward
  , msSubState = Nothing
  }

sRunning trans conn socket = MState
  { msRun = do
       sequence_ $ map spawn [reader, writer]
       waitDone
  , msTrans = \_ -> Forward
  , msSubState = Nothing
  }
  where
    reader = do
      -- TODO: handle error
      msg <- liftIO $ TM.readMsg socket
      case msg of
        TM.Payload _ payload -> do
          liftIO $ fromMaybe (return ()) $
            (mAction trans) trans conn payload
          maybeStop
          reader
        TM.Control x -> case x of
          TM.ReqClose -> do
            liftIO $ TM.writeCont socket TM.ConfClose
            (stopOrRun $ handleEvent (connStatus conn) $ TClosed) >>= liftIO
          _ -> CE.throw TM.RecvErr
    writer = do
      msg <- stopOrRun $ getItem conn
      liftIO $ TM.writeMsg socket msg
      writer

{-
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
-}
