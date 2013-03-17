{-# LANGUAGE TypeFamilies #-}
-- Messenger abstraction
module Transport ( ConnException
                 , Transport
                 , Connection
                 , Entity
                 , makeTransport
                 , startTransport
                 , getConnection
                 , queueMessage
                 , ConnID
                 , getEntity
                 ) where

import Data.Int
import Data.ByteString.Lazy

data ConnException  = Closed | Reset

type ConnID = Int64

class Transport m where
  type Entity m :: *
  type Connection m :: *
  makeTransport ::
    Entity m ->
    (m -> Connection m -> ByteString -> Maybe (IO ())) ->
    (m -> Connection m -> ConnException -> Maybe (IO ())) ->
    IO m
  startTransport :: m -> IO ()
  getConnection :: m -> Entity m -> IO (Connection m)
  queueMessage  :: m -> Connection m -> ByteString -> IO ()
  getEntity :: m -> Connection m -> Entity m
  bind :: m -> IO ()
