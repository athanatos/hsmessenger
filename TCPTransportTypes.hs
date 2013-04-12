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
better :: ConnInit -> ConnInit -> TCPEntity -> TCPEntity -> Bool
better i1 i2 e1 e2 =
  case i1 `compare` i2 of
    LT -> case e1 `compare` e2 of
      LT -> True
      GT -> False
      _ -> False
    GT -> case e2 `compare` e1 of
      LT -> True
      GT -> False
      _ -> False
    _ -> True

data TCPEvt = TOpen
            | TMarkDown
            | TReset
            | TOpened S.Socket
            | TClosed
            | TAccepted
            | TAccept TCPConnection S.Socket GSeq CSeq MSeq
            | TDoOpen TCPConnection
            deriving Show
instance SM.MEvent TCPEvt

data TCPConnection =
  TCPConnection { connHost :: TCPEntity
                , connPeer :: TCPEntity
                , connQueue :: C.Channel BS.ByteString
                , connSent :: TC.TChan BS.ByteString
                , connStatus :: SM.StateMachine TCPEvt
                , connLastRcvd :: STM.TVar MSeq
                }
instance Show TCPConnection where
  show x = (show (connHost x)) ++ "-->" ++ (show (connPeer x))

queueOnConnection :: TCPConnection -> BS.ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ fromIntegral $ BS.length msg

getItem :: TCPConnection -> STM.STM BS.ByteString
getItem conn = do
  empty <- C.channelEmpty (connQueue conn)
  when empty STM.retry
  C.getItem (connQueue conn)

makeConnection :: TCPEntity -> TCPEntity -> SM.MState TCPEvt ->
                  STM.STM (TCPConnection, IO ())
makeConnection me addr st = do
  queue <- C.makeChannel 100
  sent <- TC.newTChan
  (sm, todo) <- SM.createMachine st
  recvd <- STM.newTVar 0
  return $ (\x -> (x, todo)) $ TCPConnection { connHost = me
                                             , connPeer = addr
                                             , connQueue = queue
                                             , connSent = sent 
                                             , connStatus = sm 
                                             , connLastRcvd = recvd
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
