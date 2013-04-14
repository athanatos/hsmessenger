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
import Data.Monoid
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
             gseq lseq toack BS.empty
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
       TReset -> Trans $ sOpen gseq (lseq + 1) trans conn
       TAccept _ entity sock _ r_lseq mseq ->
         case compare (lseq, entity) (r_lseq, selfAddr trans) of
           EQ -> CE.throw $ TCPLogicException "same entity??"
           LT -> Drop
           GT -> Trans $ sAccept gseq r_lseq mseq trans conn sock
       _ -> CE.throw $ TCPLogicException ("wrong evt sOpen " ++ (show evt))
  , msSubState = Just $ sWaitSocket trans conn
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
       TReset -> Trans $ sOpen gseq (lseq + 1) trans conn
       TAccept _ entity sock _ r_lseq mseq ->
         case compare (lseq, selfAddr trans) (r_lseq, entity) of
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
       stopOrRun $ flipSent conn
       sequence_ $ map spawn [reader, writer]
       waitDone
  , msTrans = \_ -> Forward
  , msSubState = Nothing
  }
  where
    reader = do
      msg <- wrapIO conn $ TM.readMsg socket
      case msg of
        TM.Payload mseq ack payload -> do
          stopOrRun $ advanceAckd conn ack
          liftIO $
            ((T.onMsgRec . tInit) trans) trans conn payload
          stopOrRun $ advanceRcvd conn mseq
          maybeStop
          reader
        TM.ReqClose -> do
          wrapIO conn $ TM.writeCont socket TM.ConfClose
          (stopOrRun $ handleEvent (connStatus conn) $ TClosed) >>= liftIO
        _ -> CE.throw $ TCPLogicException ("wrong msg")
    writer = do
      (seq, toack, msg) <- stopOrRun $ getNextMsg conn
      wrapIO conn $ TM.writeCont socket $ TM.Payload seq toack msg
      writer

doaccept :: (Monoid s, Show s) => TCPTransport s -> S.Socket -> S.SockAddr -> IO ()
doaccept trans socket addr = do
  req <- TM.readMsg socket
  (entity, ttype, gseq, lseq, mseq, priv) <- return $ case req of
    TM.ReqOpen entity ttype gseq lseq mseq priv ->
      (entity, ttype, gseq, lseq, mseq, priv)
    _ -> CE.throw $ TCPLogicException ("wrong msg")
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup entity cmap of
      Nothing -> do
        (conn, act) <- makeConnection entity mempty ttype $
                       sInit gseq lseq trans
        act2 <-
          handleEvent (connStatus conn) $
          TAccept conn entity socket gseq lseq mseq
        return (act >> act2)
      Just _ -> do
        return $ return ()

accepter :: (Monoid s, Show s) => TCPTransport s -> IO ()
accepter trans = do
  sock <- S.socket (family trans) S.Stream S.defaultProtocol
  S.bindSocket sock (sockAddr trans)
  S.listen sock 0
  forever $ do
    (csock, caddr) <- S.accept sock
    forkIO $ doaccept trans csock caddr
    return ()

bindTransport :: (Monoid s, Show s) => TCPTransport s -> IO ()
bindTransport trans = do
  accepter trans

getConnection :: (Monoid s, Show s) => TCPTransport s ->
                 TCPAddr -> IO (TCPConnection s)
getConnection trans peer = do
  join $ STM.atomically $ do
    cmap <- STM.readTVar (openConns trans)
    case M.lookup peer cmap of
      Nothing -> do
        (conn, act) <- makeConnection peer mempty T.Server $ sInit 0 0 trans
        act2 <- handleEvent (connStatus conn) $ TDoOpen conn
        return $ act >> act2 >> return conn
      Just x -> return $ return x

queueMessage :: TCPTransport s -> TCPConnection s ->
                BS.ByteString -> IO ()
queueMessage trans conn msg = STM.atomically $ do
  queueOnConnection conn msg

queueMessageEntity :: (Show s, Monoid s) => TCPTransport s ->
                      TCPAddr -> BS.ByteString -> IO ()
queueMessageEntity trans peer msg = do
  conn <- getConnection trans peer
  queueMessage trans conn msg

instance (Monoid s, Show s, DP.Serialize s) =>
         T.Transport (TCPTransport s) s where
  type Connection (TCPTransport s) s = TCPConnection s
  type Addr (TCPTransport s) = TCPAddr
  makeTransport = makeTransport
  startTransport = \x -> return ()
  getConnection = getConnection
  queueMessage = queueMessage
  queueMessageEntity = queueMessageEntity
  connToEntity = connPAddr
  connToPrivate = connPrivate
