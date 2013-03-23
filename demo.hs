import qualified TCPTransport as TCPT
import qualified Messenger as MSGR
import Data.Int
import System.Environment
import Data.Binary
import qualified Data.ByteString.Lazy as BS
import qualified Control.Concurrent.MVar as CM

data Msg =
  Msg { msgNum      :: Int64
      , msgContents :: String
      }
instance Binary Msg where
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

client :: String -> String -> Int -> IO ()
client self target port = do
  selfAddr <- TCPT.tcpEntityFromStr self
  var <- CM.newMVar 0
  _ <- CM.takeMVar var
  msgr <- (MSGR.makeMessenger selfAddr [cAction var] [eAction])
          :: IO (MSGR.Messenger TCPT.TCPTransport Msg)
  targetAddr <- TCPT.tcpEntityFromStrWPort target port
  MSGR.queueMessageEntity msgr targetAddr
    (Msg { msgNum = 0, msgContents = "Ping" } )
  _ <- CM.takeMVar var
  return ()

server :: String -> Int -> IO ()
server self port = do
  selfAddr <- TCPT.tcpEntityFromStrWPort self port
  msgr <- (MSGR.makeMessenger selfAddr [sAction] [eAction])
          :: IO (MSGR.Messenger TCPT.TCPTransport Msg)
  MSGR.bind msgr

main = do
  args <- getArgs
  case args of
    ["client", self, shost, sport] -> client self shost (read sport)
    ["server", shost, sport] -> server shost (read sport)
    _ -> print "Error"
