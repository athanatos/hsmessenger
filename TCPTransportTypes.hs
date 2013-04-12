{-# LANGUAGE TypeFamilies, DeriveDataTypeable, DeriveGeneric #-}
module TCPTransportTypes where

import qualified Data.Serialize as DP
import qualified IOStateMachine as SM
import qualified Network.Socket as S
import qualified Control.Concurrent.STM as STM
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as M
import qualified Control.Exception as CE
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TChan as TC
import qualified Control.Concurrent.MVar as CM
import Data.Typeable
import qualified Data.Traversable as DT
import qualified Data.Sequence as DS
import Data.Ord
import Data.Int
import Control.Monad
import Control.Concurrent (MVar)
import GHC.Generics
import Data.Word

import qualified Transport as T
import qualified Channel as C

-- Entity
data NotASockAddr = NotSockAddrInet Word16 S.HostAddress
                  | NotSockAddrInet6 Word16 S.FlowInfo S.HostAddress6 S.ScopeID
                  | NotSockAddrUnix String
                    deriving (Generic, Typeable)
toNotASockAddr :: S.SockAddr -> NotASockAddr
toNotASockAddr x = case x of
  S.SockAddrInet (S.PortNum x) y -> NotSockAddrInet x y
  S.SockAddrInet6 (S.PortNum x) y z a -> NotSockAddrInet6 x y z a
  S.SockAddrUnix x -> NotSockAddrUnix x
fromNotASockAddr :: NotASockAddr -> S.SockAddr
fromNotASockAddr x = case x of
  NotSockAddrInet x y -> S.SockAddrInet (S.PortNum x) y
  NotSockAddrInet6 x y z a -> S.SockAddrInet6 (S.PortNum x) y z a
  NotSockAddrUnix x -> S.SockAddrUnix x
instance DP.Serialize NotASockAddr
instance DP.Serialize S.SockAddr where
  put = DP.put . toNotASockAddr
  get = DP.get >>= (return . fromNotASockAddr)

data TCPEntity =
  TCPEntity { entityAddr :: S.SockAddr
            }
  deriving (Eq, Show, Typeable, Generic)
instance DP.Serialize TCPEntity

type CSeq = Int64 -- connection sequence
type GSeq = Int64 -- global sequence
type MSeq = Int64 -- message sequence

familyTCPEntity :: TCPEntity -> S.Family
familyTCPEntity addr = case (entityAddr addr) of
  S.SockAddrInet _ _ -> S.AF_INET
  S.SockAddrInet6 _ _ _ _ -> S.AF_INET6
  S.SockAddrUnix _ -> S.AF_UNIX

tcpEntityFromStrWPort :: String -> Int -> IO TCPEntity
tcpEntityFromStrWPort str port = do
  addrInfo:_ <- S.getAddrInfo Nothing (Just str) Nothing
  return $
    TCPEntity { entityAddr = setPort
                             (S.addrAddress addrInfo) (fromIntegral port)
              }

tcpEntityFromStr :: String -> IO TCPEntity
tcpEntityFromStr str = do
  addrInfo:_ <- S.getAddrInfo Nothing (Just str) Nothing
  return $ TCPEntity { entityAddr = (S.addrAddress addrInfo) }

makeTuple :: TCPEntity ->
             (Int, S.PortNumber, S.FlowInfo,
              S.HostAddress, S.HostAddress6, S.ScopeID,
              String)
makeTuple = (\x -> case x of
  S.SockAddrInet a b -> (0, a, 0, b, (0,0,0,0), 0, "")
  S.SockAddrInet6 a b c d -> (1, a, b, 0, c, d, "")
  S.SockAddrUnix e -> (2, S.PortNum 0, 0, 0, (0,0,0,0), 0, e)) . entityAddr

setPort addr port = case addr of
  S.SockAddrInet a b -> S.SockAddrInet (S.PortNum port) b 
  S.SockAddrInet6 a b c d -> S.SockAddrInet6 (S.PortNum port) b c d
  S.SockAddrUnix e -> addr

instance Ord TCPEntity where
  compare a b = compare (makeTuple a) (makeTuple b)


-- TCPConnection
data ConnInit = None | Remote | Local
  deriving (Eq, Show)
toInt x = case x of
  None -> 0
  Remote -> 1
  Local -> 2
instance Ord ConnInit where
  compare x y = compare (toInt x) (toInt y)

data TCPEvt = TOpen
            | TReset
            | TOpened S.Socket
            | TClosed
            | TAccepted
            | TAccept TCPConnection TCPEntity S.Socket GSeq CSeq MSeq
            | TDoOpen TCPConnection
            deriving Show
instance SM.MEvent TCPEvt

data TCPConnection =
  TCPConnection { connHost :: TCPEntity
                , connPeer :: TCPEntity
                , connQueue :: C.Channel (MSeq, BS.ByteString)
                , connSent :: STM.TVar (DS.Seq (MSeq, BS.ByteString))
                , connStatus :: SM.StateMachine TCPEvt
                , connLastRcvd :: STM.TVar MSeq
                , connLastQueued :: STM.TVar MSeq
                , connLastAckd :: STM.TVar MSeq
                }
instance Show TCPConnection where
  show x = (show (connHost x)) ++ "-->" ++ (show (connPeer x))

modifyTVar :: STM.TVar a -> (a -> a) -> STM.STM a
modifyTVar tvar f = do
  x <- STM.readTVar tvar
  STM.writeTVar tvar (f x)
  return x

flipSent :: TCPConnection -> STM.STM()
flipSent conn = do
  sent <- modifyTVar (connSent conn) (\_ -> DS.empty)
  DT.sequence $ fmap (\x -> C.unGet (connQueue conn)
                           (fromIntegral $ BS.length $ snd x, x))
    (DS.viewl sent)
  return ()

advanceRcvd :: TCPConnection -> MSeq -> STM.STM ()
advanceRcvd conn seq = STM.writeTVar (connLastRcvd conn) seq

advanceAckd :: TCPConnection -> MSeq -> STM.STM ()
advanceAckd conn seq = do
  STM.writeTVar (connLastAckd conn) seq
  modifyTVar (connSent conn) (DS.dropWhileR ((< seq) . fst))
  return ()

queueOnConnection :: TCPConnection -> BS.ByteString -> STM.STM ()
queueOnConnection conn msg = do
  seq <- modifyTVar (connLastQueued conn) (+ 1)
  C.putItem (connQueue conn) (seq, msg) $ fromIntegral $ BS.length msg

getNextMsg :: TCPConnection -> STM.STM (MSeq, MSeq, BS.ByteString)
getNextMsg conn = do
  empty <- C.channelEmpty (connQueue conn)
  when empty STM.retry
  (mseq, bs) <- C.getItem (connQueue conn)
  modifyTVar (connSent conn) ((DS.<|) (mseq, bs))
  toack <- STM.readTVar (connLastRcvd conn)
  return (mseq, toack, bs)

makeConnection :: TCPEntity -> TCPEntity -> SM.MState TCPEvt ->
                  STM.STM (TCPConnection, IO ())
makeConnection me addr st = do
  queue <- C.makeChannel 10000
  sentq <- STM.newTVar $ DS.empty
  (sm, todo) <- SM.createMachine st
  recvd <- STM.newTVar 0
  qd <- STM.newTVar 0
  acked <- STM.newTVar 0
  return $ (\x -> (x, todo)) $ TCPConnection { connHost = me
                                             , connPeer = addr
                                             , connQueue = queue
                                             , connSent = sentq
                                             , connStatus = sm 
                                             , connLastRcvd = recvd
                                             , connLastQueued = qd
                                             , connLastAckd = acked
                                             }

data TCPLogicException = 
  TCPLogicException String
  deriving (Show, Typeable)
instance CE.Exception TCPLogicException

-- TCPTransport
data TCPTransport =
  TCPTransport { selfAddr :: TCPEntity
               , openConns :: STM.TVar (M.Map TCPEntity TCPConnection)
               , mAction :: (TCPTransport -> TCPConnection ->
                             BS.ByteString -> Maybe (IO ()))
               , eAction :: (TCPTransport -> TCPConnection ->
                             T.ConnException -> Maybe (IO ()))
               }

sockAddr :: TCPTransport -> S.SockAddr
sockAddr = entityAddr . selfAddr

family :: TCPTransport -> S.Family
family = familyTCPEntity . selfAddr

makeTransport :: TCPEntity ->
                 (TCPTransport -> TCPConnection ->
                  BS.ByteString -> Maybe (IO ())) ->
                 (TCPTransport -> TCPConnection ->
                  T.ConnException -> Maybe (IO ())) ->
                 IO TCPTransport
makeTransport addr mAction eAction = do
  oConns <- STM.atomically $ STM.newTVar M.empty
  sock <- S.socket (familyTCPEntity addr) S.Stream S.defaultProtocol
  cVar <- CM.newMVar sock
  return $ TCPTransport { selfAddr = addr
                        , openConns = oConns
                        , mAction = mAction
                        , eAction = eAction
                        }
