{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, 
TemplateHaskell, DeriveGeneric #-}
-- Messenger abstraction
module Transport ( ConnException
                 , Transport
                 , Connection
                 , TransType (Client, Server)
                 , Addr
                 , Priv
                 , makeTransport
                 , startTransport
                 , getConnection
                 , queueMessage
                 , queueMessageEntity
                 , ConnID
                 , connToEntity
                 , ReactOnFault (Drop, Reconnect, WaitAccept)
                 , TInit (TInit)
                 , transType
                 , onMsgRec
                 , onError
                 , faultPolicy
                 , connToPrivate
                 , handleConnect
                 ) where

import qualified Control.Concurrent.STM as STM
import Data.Int
import Data.ByteString.Lazy
import Data.Serialize
import GHC.Generics

data ConnException  = Closed | Reset
                    deriving Show

type ConnID = Int64

data ReactOnFault = Drop | Reconnect | WaitAccept

data TransType = Client | Server
               deriving (Eq, Show, Generic)
instance Serialize TransType
isClient = (== Client)
isServer = (== Server)

class Transport m where
  type Connection m :: *
  type Addr m :: *
  type Priv m :: *
  makeTransport :: Addr m -> TInit m -> IO m

  getConnection :: m -> Addr m -> IO (Connection m)
  connToEntity :: Connection m -> Addr m
  connToPrivate :: Connection m -> Priv m

  queueMessage  :: m -> Connection m -> ByteString -> IO ()
  queueMessageEntity  :: m -> Addr m -> ByteString -> IO ()

  startTransport :: m -> IO ()

data TInit m =
  TInit { transType :: TransType
        , onMsgRec :: m -> Connection m -> ByteString -> STM.STM ()
        , onError :: m -> Connection m -> ConnException -> STM.STM ()
        , faultPolicy :: m -> Connection m -> ReactOnFault
        , handleConnect :: m -> Addr m -> STM.STM (Priv m)
        }
