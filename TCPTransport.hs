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
import Control.Concurrent
import Data.Int
import Data.Maybe
import Control.Monad

import qualified Transport as T
import qualified TCPTransportMessages as TM
import qualified Channel as C

import TCPTransportTypes

-- States
accepting :: TCPTransport -> S.Socket -> S.SockAddr -> IO ()
accepting trans socket addr = do
  req <- TM.sget (undefined :: TM.MSGRequestConn) socket
  return ()
  where
    entity = TCPEntity { entityAddr = addr }
  

accepter :: TCPTransport -> IO ()
accepter trans = do
  sock <- S.socket (family trans) S.Stream S.defaultProtocol
  S.bindSocket sock (sockAddr trans)
  S.listen sock 0
  forever $ do
    (csock, caddr) <- S.accept sock
    forkIO $ accepting trans csock caddr
    return ()

bindTransport :: TCPTransport -> IO ()
bindTransport trans = do
  accepter trans

--instance T.Transport TCPTransport where
--  type Entity TCPTransport = TCPEntity
--  type Connection TCPTransport = TCPConnection
--  makeTransport = makeTransport
--  startTransport = \x -> return ()
--  getConnection = getConnection
--  queueMessage = queueMessage
--  queueMessageEntity = queueMessageTCPEntity
--  bind = bindTransport
