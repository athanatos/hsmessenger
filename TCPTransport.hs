{-# LANGUAGE TypeFamilies #-}
module TCPMessenger (
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
import Control.Concurrent.MVar
import Control.Monad

import qualified Channel as C

-- TCPTransport
data Entity =
  Entity { entityAddr :: S.SockAddr
         }
  deriving Eq

makeTuple :: Entity ->
             (Int, S.PortNumber, S.FlowInfo,
              S.HostAddress, S.HostAddress6, S.ScopeID,
              String)
makeTuple = (\x -> case x of
  S.SockAddrInet a b -> (0, a, 0, b, (0,0,0,0), 0, "")
  S.SockAddrInet6 a b c d -> (1, a, b, 0, c, d, "")
  S.SockAddrUnix e -> (2, S.PortNum 0, 0, 0, (0,0,0,0), 0, e)) . entityAddr

instance Ord Entity where
  compare a b = compare (makeTuple a) (makeTuple b)

data Status = Open | Closed
data TCPConnection =
  TCPConnection { connStatus :: STM.TVar Status
                , connPeer :: Entity
                , connQueue :: C.Channel ByteString
                , connSocket :: S.Socket
                }

makeConnection :: (S.Socket, S.SockAddr) -> STM.STM TCPConnection
makeConnection (socket, addr) = do
  status <- STM.newTVar Open
  queue <- C.makeChannel 100
  return $ TCPConnection { connStatus = status
                         , connPeer = Entity { entityAddr = addr }
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

initConnection :: TCPTransport TCPConnection -> IO ()
initConnection trans conn = do
  forkIO $ sendForever conn
  bs <- BSS.getContents $ connSocket conn
  forkIO $ recvForever bs

data TCPTransport =
  TCPTransport { selfAddr :: Entity
               , openConns :: STM.TVar (M.Map Entity TCPConnection)
               , mAction :: (TCPTransport -> TCPConnection ->
                             ByteString -> Maybe (IO ()))
               , eAction :: (TCPTransport -> TCPConnection ->
                             T.ConnException -> Maybe (IO ()))
               , cachedSocket :: MVar S.Socket
               }

sockAddr :: TCPTransport -> S.SockAddr
sockAddr = entityAddr . selfAddr

family :: TCPTransport -> S.Family
family trans = case (sockAddr trans) of
  S.SockAddrInet _ _ -> S.AF_INET
  S.SockAddrInet6 _ _ _ _ -> S.AF_INET6
  S.SockAddrUnix _ -> S.AF_UNIX

makeTransport :: Entity ->
                 (TCPTransport -> TCPConnection ->
                  ByteString -> Maybe (IO ())) ->
                 (TCPTransport -> TCPConnection ->
                  T.ConnException -> Maybe (IO ())) ->
                 IO TCPTransport
makeTransport addr mAction eAction = do
  oConns <- STM.atomically $ STM.newTVar M.empty
  return $ TCPTransport { selfAddr = addr
                        , openConns = oConns
                        , mAction = mAction
                        , eAction = eAction
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
        (M.insert (Entity { entityAddr = caddr} ) conn map)
      return conn
    return ()

bindTransport :: TCPTransport -> IO ()
bindTransport trans = do
  forkIO $ accepter trans
  return ()

queueMessage :: TCPTransport -> TCPConnection -> ByteString -> IO ()
queueMessage trans conn msg = do
  STM.atomically $ queueOnConnection conn msg

queueMessageEntity :: TCPTransport -> Entity -> ByteString -> IO ()
queueMessageEntity trans entity msg = do
  sock <- readMVar $ cachedSocket trans
  queued <- STM.atomically $ do
    conns <- STM.readTVar (openConns trans)
    case lookup entity conns of
      Just conn -> queueMessage trans conn msg >> return Nothing
      Nothing -> do
        conn <- makeConnection (sock, entityAddr entity)
        STM.writeTVar
          (openConns trans)
          (M.insert entity conn conns)
        return $ Just conn
  case queued of
    Nothing -> writeMVar (cachedSocket trans) sock
    Just conn -> do
      initConnection trans conn
      socknew <- S.socket (family trans) S.Stream S.defaultProtocol
      writeMVar (cachedSocket trans) sock
      
      
