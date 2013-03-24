{-# LANGUAGE TypeFamilies, DeriveDataTypeable #-}
module TCPTransportTypes where

import qualified Network.Socket as S
import qualified Control.Concurrent.STM as STM
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as M
import qualified Control.Exception as CE
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.MVar as CM
import Data.Typeable
import Data.Ord
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
data Status = New
            | Opening
            | Accepting
            | Open
            | Closing
            | Closed
data ConnInit = None | Remote | Local
  deriving (Eq)
toInt x = case x of
  None -> 0
  Remote -> 1
  Local -> 2
instance Ord ConnInit where
  compare x y = compare (toInt x) (toInt y)

data TCPConnection =
  TCPConnection { connHost :: TCPEntity
                , connPeer :: TCPEntity
                , connQueue :: C.Channel BS.ByteString
                , connStatus :: STM.TVar Status
                , connInit :: STM.TVar ConnInit
                , socket :: STM.TVar (Maybe S.Socket)
                }

queueOnConnection :: TCPConnection -> BS.ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ fromIntegral $ BS.length msg

makeConnection :: TCPEntity -> TCPEntity -> STM.STM TCPConnection
makeConnection me addr = do
  status <- STM.newTVar New
  queue <- C.makeChannel 100
  init <- STM.newTVar None
  sock <- STM.newTVar Nothing
  return $ TCPConnection { connHost = me
                         , connPeer = addr
                         , connQueue = queue
                         , connStatus = status
                         , connInit = init
                         , socket = sock
                         }

data TCPLogicException = 
  TCPLogicException String
  deriving (Show, Typeable)
instance CE.Exception TCPLogicException

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

maybeAcceptSocket :: TCPConnection -> S.Socket ->
                     STM.STM (Maybe S.Socket)
maybeAcceptSocket conn newsock = do
  status <- STM.readTVar $ connStatus conn
  init <- STM.readTVar $ connInit conn
  oldsock <- STM.readTVar $ socket conn
  case status of
    New -> do
      STM.writeTVar (connStatus conn) Accepting
      STM.writeTVar (connInit conn) Remote
      STM.writeTVar (socket conn) (Just newsock)
      return oldsock
    Closing -> 
      CE.throw (
        TCPLogicException "Closing should not be visible"
        ) >> return Nothing
    Closed ->
      CE.throw (
        TCPLogicException "Closed should not be visible"
        ) >> return Nothing
    _ -> if better Remote init (connHost conn) (connPeer conn)
         then do
           STM.writeTVar (connStatus conn) Accepting
           STM.writeTVar (connInit conn) Remote
           STM.writeTVar (socket conn) (Just newsock)
           return oldsock
         else do
           return $ Just newsock

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

getAddConnection :: TCPTransport ->
                    TCPEntity ->
                    STM.STM (TCPConnection, IO ())
getAddConnection trans entity = do
  cmap <- STM.readTVar $ openConns trans
  case M.lookup entity cmap of
    Just x -> return (x, return ())
    Nothing -> do
      conn <- makeConnection (selfAddr trans) entity
      STM.writeTVar (openConns trans) (M.insert entity conn cmap)
      return (conn, return ())
