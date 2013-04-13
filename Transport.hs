{-# LANGUAGE TypeFamilies, MultiParamTypeClasses #-}
-- Messenger abstraction
module Transport ( ConnException
                 , Transport
                 , Connection
                 , makeTransport
                 , startTransport
                 , getConnection
                 , queueMessage
                 , queueMessageEntity
                 , ConnID
                 , bind
                 , connToEntity
                 ) where

import Data.Int
import Data.ByteString.Lazy

data ConnException  = Closed | Reset
                    deriving Show

type ConnID = Int64

class Transport m e where
  type Connection m :: *
  makeTransport ::
    e ->
    (m -> Connection m -> ByteString -> Maybe (IO ())) ->
    (m -> Connection m -> ConnException -> Maybe (IO ())) ->
    IO m
  startTransport :: m -> IO ()
  getConnection :: m -> e -> IO (Connection m)
  connToEntity :: Connection m -> e
  queueMessage  :: m -> Connection m -> ByteString -> IO ()
  queueMessageEntity  :: m -> e -> ByteString -> IO ()
  bind :: m -> IO ()
