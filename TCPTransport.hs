{-# LANGUAGE TypeFamilies #-}
module TCPMessenger ( TCPTransport
                    , TCPEntity
                    , TCPConnection
                    ) where

import qualified Transport as T
import qualified Network.Socket.ByteString.Lazy as BSS
import qualified Network.Socket as S
import Data.Int
import Data.ByteString.Lazy as BS
import qualified Control.Concurrent.STM as STM
import Data.Maybe
import qualified Data.Map as M
import qualified System.IO as SIO
import qualified Data.Binary.Put as BP
import qualified Data.Binary.Get as BG
import qualified Control.Exception as CE
import Control.Concurrent
import qualified Control.Concurrent.MVar as CM
import Control.Monad

import qualified Channel as C

-- TCPTransport
data TCPEntity =
  TCPEntity { entityAddr :: S.SockAddr
         }
  deriving Eq

makeTuple :: TCPEntity ->
             (Int, S.PortNumber, S.FlowInfo,
              S.HostAddress, S.HostAddress6, S.ScopeID,
              String)
makeTuple = (\x -> case x of
  S.SockAddrInet a b -> (0, a, 0, b, (0,0,0,0), 0, "")
  S.SockAddrInet6 a b c d -> (1, a, b, 0, c, d, "")
  S.SockAddrUnix e -> (2, S.PortNum 0, 0, 0, (0,0,0,0), 0, e)) . entityAddr

instance Ord TCPEntity where
  compare a b = compare (makeTuple a) (makeTuple b)

data Status = Open | Closed
data TCPConnection =
  TCPConnection { connStatus :: STM.TVar Status
                , connPeer :: TCPEntity
                , connQueue :: C.Channel ByteString
                , connSocket :: S.Socket
                }

makeConnection :: (S.Socket, S.SockAddr) -> STM.STM TCPConnection
makeConnection (socket, addr) = do
  status <- STM.newTVar Open
  queue <- C.makeChannel 100
  return $ TCPConnection { connStatus = status
                         , connPeer = TCPEntity { entityAddr = addr }
                         , connQueue = queue
                         , connSocket = socket
                         }

queueOnConnection :: TCPConnection -> ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ fromIntegral $ BS.length msg

makeMessage :: ByteString -> ByteString
makeMessage msg = BP.runPut $ do
  -- header
  BP.putWord64be $ fromIntegral $ BS.length msg -- length

  -- payload 
  BP.putLazyByteString msg

  -- footer
  BP.putWord64be $ fromIntegral $ BS.length msg -- length

readMessage :: ByteString -> Either (ByteString, ByteString) T.ConnException
readMessage raw = 
  let
    parser = do
      -- header
      length <- BG.getWord64be -- length

      -- payload
      msg <- BG.getLazyByteString $ fromIntegral length

      -- footer
      length <- BG.getWord64be -- length

      return msg

    (msg, rest, read) = BG.runGetState parser raw 0
  in
   Left (msg, rest)

recvForever :: TCPTransport -> ByteString -> IO (Maybe T.ConnException)
recvForever trans bs =
  let
    res = readMessage bs
  in
   case res of
     Left (msg, rest) -> do
       recvForever trans rest
     Right ex -> return $ Just ex

sendForever :: TCPConnection -> IO (Maybe IOError)
sendForever conn = do
  nextMsg <- STM.atomically $ C.getItem (connQueue conn)
  err <- CE.catch 
    (BSS.send (connSocket conn) (makeMessage nextMsg) >> return Nothing)
    (return . Just)
  case err of
    Nothing -> sendForever conn
    Just err -> return $ Just err

initConnection :: TCPTransport -> TCPConnection -> IO ()
initConnection trans conn = do
  forkIO $ sendForever conn >> return ()
  bs <- BSS.getContents $ connSocket conn
  forkIO $ recvForever trans bs >> return ()
  return ()

data TCPTransport =
  TCPTransport { selfAddr :: TCPEntity
               , openConns :: STM.TVar (M.Map TCPEntity TCPConnection)
               , mAction :: (TCPTransport -> TCPConnection ->
                             ByteString -> Maybe (IO ()))
               , eAction :: (TCPTransport -> TCPConnection ->
                             T.ConnException -> Maybe (IO ()))
               , cachedSocket :: MVar S.Socket
               }

sockAddr :: TCPTransport -> S.SockAddr
sockAddr = entityAddr . selfAddr

familyTCPEntity :: TCPEntity -> S.Family
familyTCPEntity addr = case (entityAddr addr) of
  S.SockAddrInet _ _ -> S.AF_INET
  S.SockAddrInet6 _ _ _ _ -> S.AF_INET6
  S.SockAddrUnix _ -> S.AF_UNIX

family :: TCPTransport -> S.Family
family = familyTCPEntity . selfAddr

makeTransport :: TCPEntity ->
                 (TCPTransport -> TCPConnection ->
                  ByteString -> Maybe (IO ())) ->
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
                        , cachedSocket = cVar
                        }

accepter :: TCPTransport -> IO ()
accepter trans = do
  sock <- S.socket (family trans) S.Stream S.defaultProtocol
  S.bindSocket sock (sockAddr trans)
  S.listen sock 0
  forever $ do
    (csock, caddr) <- S.accept sock
    conn <- STM.atomically $ do
      conn <- makeConnection (csock, caddr)
      map <- STM.readTVar $ openConns trans
      STM.writeTVar
        (openConns trans)
        (M.insert (TCPEntity { entityAddr = caddr} ) conn map)
      return conn
    return ()

bindTransport :: TCPTransport -> IO ()
bindTransport trans = do
  forkIO $ accepter trans
  return ()

queueMessage :: TCPTransport -> TCPConnection -> ByteString -> IO ()
queueMessage trans conn msg = do
  STM.atomically $ queueOnConnection conn msg

getOrCreateConnection :: S.Socket -> TCPTransport -> TCPEntity->
                         STM.STM (Bool, TCPConnection)
getOrCreateConnection sock trans addr = do
  conns <- STM.readTVar (openConns trans)
  case M.lookup addr conns of
    Just conn -> return (False, conn)
    Nothing -> do
      newConn <- makeConnection (sock, entityAddr addr)
      STM.writeTVar
        (openConns trans)
        (M.insert addr newConn conns)
      return (True, newConn)

queueMessageTCPEntity :: TCPTransport -> TCPEntity -> ByteString -> IO ()
queueMessageTCPEntity trans entity msg = do
  sock <- CM.takeMVar $ cachedSocket trans
  (created, conn) <- STM.atomically $ getOrCreateConnection sock trans entity
  STM.atomically $ queueOnConnection conn msg
  if not created
    then CM.putMVar (cachedSocket trans) sock
    else do
      initConnection trans conn
      socknew <- S.socket (family trans) S.Stream S.defaultProtocol
      CM.putMVar (cachedSocket trans) sock

getConnection :: TCPTransport -> TCPEntity -> IO TCPConnection
getConnection trans entity = do
  sock <- CM.takeMVar $ cachedSocket trans
  (created, conn) <- STM.atomically $ getOrCreateConnection sock trans entity
  if created
    then CM.putMVar (cachedSocket trans) sock >> return conn
    else do
      socknew <- S.socket (family trans) S.Stream S.defaultProtocol
      CM.putMVar (cachedSocket trans) sock
      return conn
    
instance T.Transport TCPTransport where
  type Entity TCPTransport = TCPEntity
  type Connection TCPTransport = TCPConnection
  makeTransport = makeTransport
  startTransport = \x -> return ()
  getConnection = getConnection
  queueMessage = queueMessage
  queueMessageEntity = queueMessageTCPEntity
  bind = bindTransport
