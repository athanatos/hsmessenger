import qualified TCPTransport as TCPT
import qualified Messenger as MSGR
import Data.Int
import System.Environment
import Data.Serialize
import qualified Data.Serialize.Put as SP
import qualified Data.Serialize.Get as SG
import qualified Data.ByteString.Lazy as BS
import qualified Control.Concurrent.MVar as CM

data Msg =
  Msg { msgNum      :: Int64
      , msgContents :: String
      }
instance Serialize Msg where
  put a = do
    put $ msgNum a
    put $ msgContents a
  get = do
    num <- get
    contents <- get
    return $ Msg { msgNum = num, msgContents = contents }

eAction msgr conn err = do
  Just $ return ()

cAction var msgr conn msg = Just $ do
  print $ "Got msg " ++ (msgContents msg)
  CM.putMVar var 0
  return ()

sAction msgr conn msg = Just $ do
  print $ "Got msg " ++ (msgContents msg)
  MSGR.queueMessageConn msgr conn (Msg { msgNum = 1, msgContents = "Pong" } )
  return ()

setup self action = do
  selfAddr <- TCPT.tcpEntityFromStr self
  msgr <- (MSGR.makeMessenger selfAddr [action] [eAction])
          :: IO (MSGR.Messenger TCPT.TCPTransport Msg)
  return msgr
  
client self target = do
  var <- CM.newMVar 0
  _ <- CM.takeMVar var
  msgr <- setup self $ cAction var
  targetAddr <- TCPT.tcpEntityFromStr target
  MSGR.queueMessageEntity msgr targetAddr
    (Msg { msgNum = 0, msgContents = "Ping" } )

server self = do
  msgr <- setup self sAction
  MSGR.bind msgr

main = do
  args <- getArgs
  case args of
    ["client", self, target] -> client self target
    ["server", self] -> server self
    _ -> print "Error"
