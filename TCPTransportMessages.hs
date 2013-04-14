{-# LANGUAGE TypeFamilies, DeriveDataTypeable, DeriveGeneric #-}
module TCPTransportMessages where
                            

import Data.Int
import Data.Word
import Control.Monad
import qualified Data.Serialize as DP
import qualified Data.Serialize.Put as DPP
import qualified Network.Socket.ByteString.Lazy as NSS
import qualified Network.Socket as NS
import qualified Data.ByteString.Lazy as BS
import qualified Control.Exception as CE
import qualified Control.Concurrent.MVar as CM
import Data.Typeable
import GHC.Generics (Generic)
import System.IO.Error

import TCPTransportTypes
import qualified Transport as T

safeSend :: NS.Socket -> BS.ByteString -> IO ()
safeSend socket bs = do
  sent <- NSS.send socket bs
  when (sent == 0) $
    ioError (userError "Send Error")
  if sent < (BS.length bs)
    then safeSend socket (BS.drop sent bs)
    else return ()

sendMsg :: DP.Serialize x => NS.Socket -> x -> IO ()
sendMsg socket x  = do
  safeSend socket $ DP.encodeLazy x

recvMsg :: DP.Serialize x => Int64 -> NS.Socket -> IO x
recvMsg size socket = do
  bs <- NSS.recv socket size
  case DP.decodeLazy bs of
    Right x -> return x
    Left _ -> ioError (userError "RecvError")

class DP.Serialize x => NMessageFixed x where
  empty :: x -> x

  size :: x -> Int64
  size y = (BS.length . DP.encodeLazy) (empty y)

  sput :: NS.Socket -> x -> IO ()
  sput = sendMsg

  sget :: x -> NS.Socket -> IO x
  sget dummy = recvMsg (size dummy)

-- Request to open conn
data MSGRequestConn =
  MSGRequestConn { rlastSeqReceived :: Int64
                 }
  deriving (Show, Generic, Typeable)
instance DP.Serialize MSGRequestConn
instance NMessageFixed MSGRequestConn where
  empty _ = MSGRequestConn { rlastSeqReceived = 0 }

-- Payload header (or close)
newtype PayloadHeader =
  PayloadHeader { plastSeqReceived :: Int64
                }
  deriving (Show, Generic, Typeable)
instance DP.Serialize PayloadHeader
instance NMessageFixed PayloadHeader where
  empty _ = PayloadHeader 0

data TMessage = ReqClose
              | ConfClose
              | ConfOpen GSeq MSeq
              | ReqOpen TCPAddr T.TransType GSeq CSeq MSeq BS.ByteString
              | Payload MSeq MSeq BS.ByteString
              deriving (Show, Generic)
instance DP.Serialize TMessage

readMsg :: NS.Socket -> IO TMessage
readMsg sock = do
  PayloadHeader len <- sget (undefined :: PayloadHeader) sock
  recvMsg len sock 

writeCont :: NS.Socket -> TMessage -> IO ()
writeCont sock act = do
  bss <- return $ DP.encodeLazy act
  sput sock $ PayloadHeader $ BS.length bss
  safeSend sock bss
