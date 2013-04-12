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
sInit gseq lseq trans = MState
  { msRun = do
       return ()
  , msTrans = \evt -> case evt of
       TDoOpen conn -> Trans $ sOpen gseq lseq trans conn
       TAccept conn entity sock gseq lseq mseq ->
         Trans $ sAccept gseq lseq mseq trans conn sock
       _ -> CE.throw $ TCPLogicException ("wrong state" ++ (show evt))
  , msSubState = Nothing
  }
       

sOpen gseq lseq trans conn = MState
  { msRun = do
       maybeStop
       sock <- liftIO $ S.socket (family trans) S.Stream S.defaultProtocol
       deferOnExit $ S.sClose sock
       liftIO $ S.connect sock (entityAddr $ connPeer conn)
       liftIO $ TM.writeCont sock $ TM.ReqOpen (connHost conn) gseq lseq 0
       resp <- liftIO $ TM.readMsg sock
       case resp of
         TM.ReqClose -> do
           liftIO $ TM.writeCont sock TM.ConfClose
           (stopOrRun $ handleEvent (connStatus conn) TReset) >>= liftIO
         TM.ConfOpen lseq mseq -> do
           -- handle new lseq
           (stopOrRun $ handleEvent (connStatus conn) $ TOpened sock) >>= liftIO
         _ -> CE.throw $ TCPLogicException "sOpen can't get Payload"
       waitDone
  , msTrans = \evt -> case evt of
       TReset -> Trans $ sOpen gseq (lseq + 1) trans conn
       TAccept _ entity sock _ r_lseq mseq ->
         case compare (lseq, entity) (r_lseq, connHost conn) of
           EQ -> CE.throw $ TCPLogicException "same entity??"
           LT -> Drop
           GT -> Trans $ sAccept gseq r_lseq mseq trans conn sock
       _ -> CE.throw $ TCPLogicException ("wrong evt sOpen " ++ (show evt))
  , msSubState = Just $ sWaitSocket trans conn
  }

sAccept gseq lseq mseq trans conn sock = MState
 { msRun = do
      deferOnExit $ S.sClose sock
      liftIO $ TM.writeCont sock $ TM.ConfOpen 0 0
      (stopOrRun $ handleEvent (connStatus conn) $ TAccepted) >>= liftIO
      waitDone
 , msTrans = \evt -> case evt of 
      TReset -> Trans $ sOpen gseq (lseq + 1) trans conn
      TAccept _ entity sock _ r_lseq mseq ->
        case compare (lseq, connHost conn) (r_lseq, entity) of
          EQ -> CE.throw $ TCPLogicException "same entity??"
          LT -> Drop
          GT -> Trans $ sAccept gseq r_lseq mseq trans conn sock
 , msSubState = Just $ sWaitReady trans conn sock
 }

sWaitReady trans conn socket = MState
  { msRun = do
       return ()
  , msTrans = \evt -> case evt of
       TAccepted -> Trans $ sRunning trans conn socket
       _ -> Forward
  , msSubState = Nothing
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
        TM.ReqClose -> do
          liftIO $ TM.writeCont socket TM.ConfClose
          (stopOrRun $ handleEvent (connStatus conn) $ TClosed) >>= liftIO
        _ -> CE.throw TM.RecvErr
    writer = do
      msg <- stopOrRun $ getItem conn
      liftIO $ TM.writeMsg socket 0 msg
      writer

doaccept :: TCPTransport -> S.Socket -> S.SockAddr -> IO ()
doaccept trans socket addr = do
  req <- TM.readMsg socket
  (entity, gseq, lseq, mseq) <- return $ case req of
    TM.ReqOpen entity gseq lseq mseq -> (entity, gseq, lseq, mseq)
    _ -> CE.throw TM.RecvErr
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup (TCPEntity addr) cmap of
      Nothing -> do
        (conn, act) <- makeConnection (selfAddr trans) (TCPEntity addr) $
                       sInit gseq 0 trans
        act2 <-
          handleEvent (connStatus conn) $
          TAccept conn entity socket gseq lseq mseq
        return (act >> act2)
      Just _ -> do
        return $ return ()

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

getConnection :: TCPTransport -> TCPEntity -> IO TCPConnection
getConnection trans peer = do
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup peer cmap of
      Nothing -> do
        (conn, act) <- makeConnection (selfAddr trans) peer $ sInit 0 0 trans
        act2 <- handleEvent (connStatus conn) $ TDoOpen conn
        return $ act >> act2 >> return conn
      Just x -> return $ return x

queueMessage :: TCPTransport -> TCPConnection -> BS.ByteString -> IO ()
queueMessage trans conn msg = STM.atomically $ do
  C.putItem (connQueue conn) msg (fromIntegral $ BS.length msg)

queueMessageEntity :: TCPTransport -> TCPEntity -> BS.ByteString -> IO ()
queueMessageEntity trans peer msg = do
  conn <- getConnection trans peer
  queueMessage trans conn msg

instance T.Transport TCPTransport where
  type Entity TCPTransport = TCPEntity
  type Connection TCPTransport = TCPConnection
  makeTransport = makeTransport
  startTransport = \x -> return ()
  getConnection = getConnection
  queueMessage = queueMessage
  queueMessageEntity = queueMessageEntity
  bind = bindTransport
