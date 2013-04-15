{-# LANGUAGE TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}
module TCPTransport ( TCPTransport
                    , TCPAddr
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
import System.IO.Error
import qualified Data.Serialize as DP

import qualified Transport as T
import qualified TCPTransportMessages as TM
import qualified Channel as C
import IOStateMachine
import IOTree

import TCPTransportTypes

wrapIO conn t = do
  join $ liftIO $ catchIOError (t >>= return . return) $ \_ -> 
    return $ do
      x <- stopOrRun $ handleEvent (connStatus conn) TReset
      liftIO x
      (waitDone :: IOTree a)
  

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
  , msDesc = "(sInit)"
  }

onReset gseq lseq trans conn =
  case (T.faultPolicy . tInit) trans trans conn of
    T.Reconnect -> case connType conn of
      T.Client -> Trans $ sClose gseq lseq trans conn
      T.Server -> Trans $ sOpen gseq (lseq + 1) trans conn
    T.Drop -> Trans $ sClose gseq lseq trans conn
    T.WaitAccept -> Trans $ sWaitAccept gseq lseq trans conn

sClose gseq lseq trans conn = MState
  { msRun = do
       join $ stopOrRun $ do
         removeConnection trans (connPAddr conn)
         stopMachine (connStatus conn)
  , msTrans = \evt -> case evt of
       TAccept _ entity sock _ r_lseq mseq ->
         Trans $ sAccept gseq r_lseq mseq trans conn sock
       _ -> Forward
  , msSubState = Nothing
  , msDesc = "(sClose)"
  }

sWaitAccept gseq lseq trans conn = MState
  { msRun = return ()
  , msTrans = \evt -> case evt of
       TAccept _ entity sock _ r_lseq mseq ->
         Trans $ sAccept gseq r_lseq mseq trans conn sock
       _ -> Forward
  , msSubState = Nothing
  , msDesc = "(sWaitAccept)"
  }

sOpen gseq lseq trans conn = MState
  { msRun = do
       maybeStop
       sock <- wrapIO conn $ S.socket (family trans) S.Stream S.defaultProtocol
       deferOnExit $ S.sClose sock
       wrapIO conn $ S.connect sock (connPAddr conn)
       toack <- stopOrRun $ STM.readTVar (connLastRcvd conn)
       wrapIO conn $
         TM.writeCont sock $
           TM.ReqOpen (selfAddr trans) ((T.transType . tInit) trans)
             gseq lseq toack
       resp <- wrapIO conn $ TM.readMsg sock
       case resp of
         TM.ReqClose -> do
           wrapIO conn $ TM.writeCont sock TM.ConfClose
           (stopOrRun $ handleEvent (connStatus conn) TReset) >>= liftIO
         TM.ConfOpen lseq mseq -> do
           stopOrRun $ advanceAckd conn mseq
           -- handle new lseq
           (stopOrRun $ handleEvent (connStatus conn) $ TOpened sock) >>= liftIO
         _ -> CE.throw $ TCPLogicException "sOpen can't get Payload"
       waitDone
  , msTrans = \evt -> case evt of
       TReset -> onReset gseq lseq trans conn
       TAccept _ entity sock _ r_lseq mseq ->
         case compare (lseq, entity) (r_lseq, selfAddr trans) of
           EQ -> CE.throw $ TCPLogicException "same entity??"
           LT -> Drop
           GT -> Trans $ sAccept gseq r_lseq mseq trans conn sock
       _ -> CE.throw $ TCPLogicException ("wrong evt sOpen " ++ (show evt))
  , msSubState = Just $ sWaitSocket trans conn
  , msDesc = "(sOpen)"
  }

sAccept gseq lseq mseq trans conn sock = MState
  { msRun = do
       deferOnExit $ S.sClose sock
       toack <- stopOrRun $
                advanceAckd conn mseq >> STM.readTVar (connLastRcvd conn)
       wrapIO conn $ TM.writeCont sock $ TM.ConfOpen gseq toack
       (stopOrRun $ handleEvent (connStatus conn) $ TAccepted) >>= liftIO
       waitDone
  , msTrans = \evt -> case evt of 
       TReset -> onReset gseq lseq trans conn
       TAccept _ entity sock _ r_lseq mseq ->
         case compare (lseq, selfAddr trans) (r_lseq, entity) of
           EQ -> CE.throw $ TCPLogicException "same entity??"
           LT -> Drop
           GT -> Trans $ sAccept gseq r_lseq mseq trans conn sock
  , msSubState = Just $ sWaitReady trans conn sock
  , msDesc = "(sAccept)"
  }

sWaitReady trans conn socket = MState
  { msRun = do
       return ()
  , msTrans = \evt -> case evt of
       TAccepted -> Trans $ sRunning trans conn socket
       _ -> Forward
  , msSubState = Nothing
  , msDesc = "(sWaitReady)"
  }

sWaitSocket trans conn = MState
  { msRun = return ()
  , msTrans = \evt -> case evt of
       TOpened sock -> Trans $ sRunning trans conn sock
       _ -> Forward
  , msSubState = Nothing
  , msDesc = "(sWaitSocket)"
  }

sRunning trans conn socket = MState
  { msRun = do
       stopOrRun $ flipSent conn
       sequence_ $ map spawn [reader, writer]
       waitDone
  , msTrans = \_ -> Forward
  , msSubState = Nothing
  , msDesc = "(sRunning)"
  }
  where
    reader = do
      wDebug "reader"
      msg <- wrapIO conn $ TM.readMsg socket
      case msg of
        TM.Payload mseq ack payload -> do
          wDebug "reader -- got Payload"
          stopOrRun $ do
            advanceAckd conn ack
            ((T.onMsgRec . tInit) trans) trans conn payload
            advanceRcvd conn mseq
          reader
        TM.ReqClose -> do
          wrapIO conn $ TM.writeCont socket TM.ConfClose
          (stopOrRun $ handleEvent (connStatus conn) $ TClosed) >>= liftIO
        _ -> CE.throw $ TCPLogicException ("wrong msg")
    writer = do
      wDebug "writer"
      (seq, toack, msg) <- stopOrRun $ getNextMsg conn
      wrapIO conn $ TM.writeCont socket $ TM.Payload seq toack msg
      writer

doaccept :: (Show s) => TCPTransport s -> S.Socket -> S.SockAddr -> IO ()
doaccept trans socket addr = do
  req <- TM.readMsg socket
  (entity, ttype, gseq, lseq, mseq) <- return $ case req of
    TM.ReqOpen entity ttype gseq lseq mseq ->
      (entity, ttype, gseq, lseq, mseq)
    _ -> CE.throw $ TCPLogicException ("wrong msg")
  raddr <- return $ case ttype of
    T.Client -> addr
    T.Server -> entity
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup raddr cmap of
      Nothing -> do
        priv <- ((T.handleConnect . tInit) trans trans entity)
        (conn, act) <- makeConnection raddr
                       priv
                       ttype $
                       sInit gseq lseq trans
        act2 <-
          handleEvent (connStatus conn) $
          TAccept conn entity socket gseq lseq mseq
        STM.writeTVar (openConns trans) (M.insert raddr conn cmap)
        return (act >> act2)
      Just conn -> do
        handleEvent (connStatus conn) $
          TAccept conn entity socket gseq lseq mseq

accepter :: (Show s) => TCPTransport s -> IO ()
accepter trans = do
  sock <- S.socket (family trans) S.Stream S.defaultProtocol
  S.bindSocket sock (sockAddr trans)
  S.listen sock 0
  forever $ do
    (csock, caddr) <- S.accept sock
    forkIO $ doaccept trans csock caddr
    return ()

bindTransport :: (Show s) => TCPTransport s -> IO ()
bindTransport trans = do
  accepter trans

getConnection :: (Show s) => TCPTransport s ->
                 TCPAddr -> IO (TCPConnection s)
getConnection trans peer = do
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup peer cmap of
      Nothing -> do
        priv <- ((T.handleConnect . tInit) trans trans peer)
        (conn, act) <- makeConnection peer priv T.Server $ sInit 0 0 trans
        act2 <- handleEvent (connStatus conn) $ TDoOpen conn
        return $ act >> act2 >> return conn
      Just x -> return $ return x

queueMessage :: TCPTransport s -> TCPConnection s ->
                BS.ByteString -> IO ()
queueMessage trans conn msg = STM.atomically $ do
  queueOnConnection conn msg

queueMessageEntity :: (Show s) => TCPTransport s ->
                      TCPAddr -> BS.ByteString -> IO ()
queueMessageEntity trans peer msg = do
  conn <- getConnection trans peer
  queueMessage trans conn msg

startTransport :: (Show s) => TCPTransport s -> IO ()
startTransport trans = case ((T.transType . tInit) trans) of
  T.Client -> return ()
  T.Server -> accepter trans

instance (Show s, DP.Serialize s) =>
         T.Transport (TCPTransport s) where
  type Connection (TCPTransport s) = TCPConnection s
  type Addr (TCPTransport s) = TCPAddr
  type Priv (TCPTransport s) = s
  makeTransport = makeTransport
  startTransport = startTransport
  getConnection = getConnection
  queueMessage = queueMessage
  queueMessageEntity = queueMessageEntity
  connToEntity = connPAddr
  connToPrivate = connPrivate
