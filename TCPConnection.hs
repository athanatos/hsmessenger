
-- TCPConnection
data Status = New
            | Opening
            | Accepting
            | Open
            | Closing
            | Closed
data ConnInit = None | Remote | Local
data TCPConnection =
  TCPConnection { connPeer :: TCPEntity
                , connQueue :: C.Channel BS.ByteString
                , connStatus :: STM.TVar Status
                , connInit :: STM.TVar ConnInit
                , socket :: STM.TVar (Maybe S.Socket)
                }

queueOnConnection :: TCPConnection -> BS.ByteString -> STM.STM ()
queueOnConnection conn msg = do
  C.putItem (connQueue conn) msg $ fromIntegral $ BS.length msg

makeConnection :: TCPEntity -> STM.STM TCPConnection
makeConnection addr = do
  status <- STM.newTVar New
  queue <- C.makeChannel 100
  init <- STM.newTVar None
  sock <- STM.newTVar Nothing
  return $ TCPConnection { connPeer = addr
                         , connQueue = queue
                         , connStatus = status
                         , connInit = init
                         , socket = sock
                         }

acceptConnection :: TCPConnection -> S.Socket -> ConnInit ->
                    STM.STM ()
acceptConnection conn sock init = do
  

