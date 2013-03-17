{-# LANGUAGE TypeFamilies #-}
module TCPMessenger (
                    ) where

import qualified Transport as T
import qualified Network.Socket as S
import Data.Int
import Data.ByteString as BS
import qualified Control.Concurrent.STM as STM
import Data.Maybe
import qualified Data.Map as M
import qualified GHC.IO.Handle as H
import qualified System.IO as SIO

import qualified Channel as C

-- TCPTransport
data Entity =
  Entity { entityAddr :: S.SockAddr
         }
  deriving Eq

data Status = Open | Closed
data TCPConnection =
  TCPConnection { connStatus :: STM.TVar Status
                , connPeer :: Entity
                , connQueue :: C.Channel ByteString
                , connSocket :: H.Handle
                }

makeConnection :: (S.Socket, S.SockAddr) -> IO TCPConnection
makeConnection (socket, addr) = do
  status <- STM.atomically $ STM.newTVar Open
  queue <- STM.atomically $ C.makeChannel 100
  handle <- S.socketToHandle socket SIO.ReadWriteMode
  return $ TCPConnection { connStatus = status
                         , connPeer = Entity { entityAddr = addr }
                         , connQueue = queue
                         , connSocket = handle
                         }

queueOnConnection :: TCPConnection -> ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ BS.length msg

sendNextMessage :: TCPConnection -> IO ()
sendNextMessage conn = do
  nextMsg <- STM.atomically $ C.getItem (connQueue conn)
  BS.hPut (connSocket conn) nextMsg
  return ()

data TCPTransport =
  TCPTransport { selfAddr :: S.SockAddr
               , openConns :: STM.TVar (M.Map Entity TCPConnection)
               }


