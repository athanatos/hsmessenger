{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, 
TemplateHaskell, DeriveGeneric, FunctionalDependencies #-}
-- Messenger abstraction
module Transport ( ConnException
                 , Transport
                 , Connection
                 , TransType (Client, Server)
                 , Addr
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

class (Serialize s) => Transport m s | m -> s where
  type Connection m s :: *
  type Addr m :: *
  makeTransport :: Addr m -> TInit m s -> IO m

  getConnection :: m -> Addr m -> IO (Connection m s)
  connToEntity :: Connection m s -> Addr m
  connToPrivate :: Connection m s -> s

  queueMessage  :: m -> Connection m s -> ByteString -> IO ()
  queueMessageEntity  :: m -> Addr m -> ByteString -> IO ()

  startTransport :: m -> IO ()

data TInit m s =
  TInit { transType :: TransType
        , onMsgRec :: m -> Connection m s -> ByteString -> STM.STM ()
        , onError :: m -> Connection m s -> ConnException -> STM.STM ()
        , faultPolicy :: m -> Connection m s -> ReactOnFault
        , handleConnect :: m -> Addr m -> STM.STM s
        }
