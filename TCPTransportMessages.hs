{-# LANGUAGE TypeFamilies, DeriveDataTypeable, DeriveGeneric #-}
module TCPTransportMessages where
                            

import Data.Int
import Control.Monad
import qualified Data.Binary as DP
import qualified Network.Socket.ByteString.Lazy as NSS
import qualified Network.Socket as NS
import qualified Data.ByteString.Lazy as BS
import qualified Control.Exception as CE
import qualified Control.Concurrent.MVar as CM
import Data.Typeable
import GHC.Generics (Generic)

data TCPException = 
  SendErr |
  RecvErr
  deriving (Show, Typeable)
instance CE.Exception TCPException

safeSend :: NS.Socket -> BS.ByteString -> IO ()
safeSend socket bs = do
  sent <- NSS.send socket bs
  when (sent == 0)
    (CE.throwIO SendErr >> return ())
  if sent < (BS.length bs)
    then safeSend socket (BS.drop sent bs)
    else return ()

sendMsg :: DP.Binary x => NS.Socket -> x -> IO ()
sendMsg socket x  = do
  safeSend socket $ DP.encode x

recvMsg :: DP.Binary x => Int64 -> NS.Socket -> IO x
recvMsg size socket = do
  bs <- NSS.recv socket size
  return $ DP.decode bs

class DP.Binary x => NMessageFixed x where
  empty :: x -> x

  size :: x -> Int64
  size y = (BS.length . DP.encode) (empty y)

  sput :: NS.Socket -> x -> IO ()
  sput = sendMsg

  sget :: x -> NS.Socket -> IO x
  sget dummy = recvMsg (size dummy)

-- Request to open conn
data MSGRequestConn =
  MSGRequestConn { rlastSeqReceived :: Int64
                 }
instance DP.Binary MSGRequestConn where
  get = do
    seq <- DP.get
    return $ MSGRequestConn { rlastSeqReceived = seq }
  put = (DP.put . rlastSeqReceived)
instance NMessageFixed MSGRequestConn where
  empty _ = MSGRequestConn { rlastSeqReceived = 0 }

-- Response to open conn
data Result = Accept | Deny
data MSGAcceptConn =
  MSGAcceptConn { result :: Result
                , alastSeqReceived :: Int64
                }
  deriving (Generic, Typeable)
instance DP.Binary MSGAcceptConn where
  get = do
    tag <- DP.getWord8
    seq <- DP.get
    return $ case tag of
      0 -> MSGAcceptConn { result = Accept, alastSeqReceived = seq }
      1 -> MSGAcceptConn { result = Deny, alastSeqReceived = seq }
      _ -> CE.throw RecvErr
  put x = do
    DP.putWord8 $ case result x of
      Accept -> 0
      Deny -> 1
    DP.put $ alastSeqReceived x
instance NMessageFixed MSGAcceptConn where
  empty _ = MSGAcceptConn { result = Deny, alastSeqReceived = 0 }

-- Payload header (or close)
data HAction = Close | Intro
toTag :: HAction -> DP.Word8
toTag act = case act of
  Close -> 0
  Intro -> 1
fromTag :: DP.Word8 -> Maybe HAction
fromTag tag = case tag of
  0 -> Just Close
  1 -> Just Intro
  _ -> Nothing
data PayloadHeader =
  PayloadHeader { pAction :: HAction
                , pLength :: Int64
                , plastSeqReceived :: Int64
                }
instance DP.Binary PayloadHeader where
  get = do
    tag <- DP.getWord8
    len <- DP.get
    rec <- DP.get
    case fromTag tag of
      Just x -> return $ PayloadHeader { pAction = Close
                                       , pLength = len 
                                       , plastSeqReceived = rec
                                       }
      Nothing -> CE.throw RecvErr
  put x = do
    DP.putWord8 $ case pAction x of
      Close -> 0
      Intro -> 1
    (DP.put . pLength) x
    (DP.put . plastSeqReceived) x
instance NMessageFixed PayloadHeader where
  empty _ = PayloadHeader { pAction = Close
                          , pLength = 0
                          , plastSeqReceived = 0
                          }

-- Payload
type Payload = BS.ByteString

-- Footer
type PayloadFooter = PayloadHeader
