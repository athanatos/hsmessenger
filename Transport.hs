{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, 
TemplateHaskell, DeriveGeneric #-}
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
                 , ReactOnFault
                 , TInit
                 , transType
                 , onMsgRec
                 , onError
                 , handleFault
                 , connToPrivate
                 ) where

import Data.Monoid
import Data.Int
import Data.ByteString.Lazy
import Data.Serialize
import GHC.Generics

data ConnException  = Closed | Reset
                    deriving Show

type ConnID = Int64

data ReactOnFault = Drop | Reconnect Int64 | WaitAccept

data TransType = Client | Server
               deriving (Eq, Show, Generic)
instance Serialize TransType
isClient = (== Client)
isServer = (== Server)

class (Serialize s, Monoid s) => Transport m s where
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
        , onMsgRec :: m -> Connection m s -> ByteString -> IO ()
        , onError :: m -> Connection m s -> ConnException -> IO ()
        , handleFault :: m -> Connection m s -> Int64 -> ReactOnFault
        , handlePrivate :: m -> Connection m s -> ByteString -> s
        }
