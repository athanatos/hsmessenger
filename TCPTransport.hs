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
import qualified Data.Map as M
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
sInit trans = MState
  { msRun = return ()
  , 
       

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
        TM.Control TM.ReqClose -> do
          liftIO $ TM.writeCont socket TM.ConfClose
          (stopOrRun $ handleEvent (connStatus conn) $ TClosed) >>= liftIO
        _ -> CE.throw TM.RecvErr
    writer = do
      msg <- stopOrRun $ getItem conn
      liftIO $ TM.writeMsg socket msg
      writer

doaccept :: TCPTransport -> S.Socket -> S.SockAddr -> IO ()
doaccept trans socket addr = do
  req <- TM.readMsg socket
  case req of
    _ -> CE.throw TM.RecvErr
    TM.Control TM.ReqOpen -> return ()
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup (TCPEntity addr) cmap of
      Nothing -> do
        (conn, act) <- makeConnection (selfAddr trans) (TCPEntity addr) $
                       sAccept trans conn socket
        return act
      Just _ -> do
        return $ return ()

{-
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
