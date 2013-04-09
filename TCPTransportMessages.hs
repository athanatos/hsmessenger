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

-- Payload header (or close)
data HAction = ReqClose | ConfClose | ConfOpen | ReqOpen
             deriving (Show)
toTag :: Maybe HAction -> DP.Word8
toTag act = case act of
  Just cont -> case cont of
    ReqClose -> 0
    ConfClose -> 1
    ConfOpen -> 2
    ReqOpen -> 3
  Nothing -> 4
fromTag :: DP.Word8 -> Maybe HAction
fromTag tag = case tag of
  0 -> Just ReqClose
  1 -> Just ConfClose
  2 -> Just ConfOpen
  4 -> Just ReqOpen
  5 -> Nothing
  _ -> CE.throw RecvErr
data PayloadHeader =
  PayloadHeader { pAction :: Maybe HAction
                , pLength :: Int64
                , pSeqNum :: Int64
                , plastSeqReceived :: Int64
                }
instance DP.Binary PayloadHeader where
  get = do
    tag <- DP.getWord8
    len <- DP.get
    seq <- DP.get
    rec <- DP.get
    return $ PayloadHeader { pAction = fromTag tag
                           , pLength = len
                           , pSeqNum = seq
                           , plastSeqReceived = rec
                           }
  put x = do
    DP.putWord8 $ toTag $ pAction x
    (DP.put . pLength) x
    (DP.put . pSeqNum) x
    (DP.put . plastSeqReceived) x

instance NMessageFixed PayloadHeader where
  empty _ = PayloadHeader (Just ReqClose) 0 0 0

-- Payload
type Payload = BS.ByteString

-- Footer
type PayloadFooter = PayloadHeader

-- Full msg
data Msg =
  Payload { mlastSeqReceieved :: Int64
          , mPayload :: BS.ByteString
          }
  | Control HAction

readMsg :: NS.Socket -> IO Msg
readMsg sock = do
  header <- sget (undefined :: PayloadHeader) sock
  case pAction header of
    Nothing -> do
      msg <- recvMsg (pLength header) sock
      sget (undefined :: PayloadHeader) sock
      return $ Payload { mlastSeqReceieved  = plastSeqReceived header 
                       , mPayload = msg
                       }
    Just cont -> return $ Control cont

writeMsg :: NS.Socket -> BS.ByteString -> IO ()
writeMsg sock msg = do
  sendMsg sock $ PayloadHeader Nothing (BS.length msg) 0 0
  safeSend sock msg
  sendMsg sock $ PayloadHeader Nothing 0 0 0

writeCont :: NS.Socket -> HAction -> IO ()
writeCont sock act = sendMsg sock $ PayloadHeader (Just act) 0 0 0
