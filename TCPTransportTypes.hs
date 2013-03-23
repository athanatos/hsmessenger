{-# LANGUAGE TypeFamilies #-}
module TCPTransportTypes where

import qualified Network.Socket as S
import qualified Control.Concurrent.STM as STM
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as M
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.MVar as CM
import Control.Concurrent (MVar)

import qualified Transport as T
import qualified Channel as C

-- Entity
data TCPEntity =
  TCPEntity { entityAddr :: S.SockAddr
            }
  deriving Eq

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
data Status = Openning
            | Accepting
            | Open
            | Closing
            | Closed
data ConnInit = Remote | Local
data TCPConnection =
  TCPConnection { connPeer :: TCPEntity
                , connInit :: ConnInit
                , connQueue :: C.Channel BS.ByteString
                , connStatus :: STM.TVar Status
                , writerRunning :: STM.TVar Bool
                , readerRunning :: STM.TVar Bool
                }

queueOnConnection :: TCPConnection -> BS.ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ fromIntegral $ BS.length msg

makeConnection :: S.Socket -> S.SockAddr -> STM.STM TCPConnection
makeConnection socket addr = do
  status <- STM.newTVar Open
  queue <- C.makeChannel 100
  sock <- STM.newTVar socket
  w <- STM.newTVar True
  r <- STM.newTVar True
  return $ TCPConnection { connStatus = status
                         , connPeer = TCPEntity { entityAddr = addr }
                         , connQueue = queue
                         , writerRunning = w
                         , readerRunning = r
                         }


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

maybeAddConnection :: TCPTransport ->
                      TCPEntity ->
                      S.Socket ->
                      ConnInit ->
                      STM.STM Maybe Connection
maybeAddConnection trans peer init = do

