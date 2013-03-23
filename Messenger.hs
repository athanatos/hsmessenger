{-# LANGUAGE TypeFamilies #-}
module Messenger ( Messenger
                 , makeMessenger
                 , bind
                 , queueMessageEntity
                 , queueMessageConn
                 ) where

import qualified Data.Binary as DP
import Data.Maybe
import qualified Data.ByteString.Lazy as BS
import qualified Transport as T
import qualified Channel as C
import Control.Monad.State
import qualified Data.Sequence as S
import qualified Data.Map as M

import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Concurrent.STM.TVar
import Data.Int

import Channel

-- Messenger
data Messenger t a =
  Messenger
  { getTransport :: t
  }

makeMessenger :: T.Transport t => DP.Binary a =>
                 T.Entity t ->
                 [(Messenger t a -> T.Connection t -> a -> Maybe (IO ()))] ->
                 [(Messenger t a -> T.Connection t ->
                   T.ConnException -> Maybe (IO ()))] ->
                 IO (Messenger t a)
makeMessenger addr _mActions _eActions = 
  let
    firstJust [] = Nothing
    firstJust (x:xs) = case x of
      Just x -> Just x
      Nothing -> firstJust xs

    collapse ms trans conn bs = firstJust [x trans conn bs | x <- ms]

    decodify x = \t conn bs ->
      x (Messenger { getTransport = t }) conn (DP.decode bs)

    eActions = collapse $
               [\t -> y (Messenger { getTransport = t }) | y <- _eActions]
    mActions = collapse $ map decodify _mActions
  in
   do
     trans <- T.makeTransport addr mActions eActions
     T.startTransport trans
     return $ Messenger { getTransport = trans }

bind :: T.Transport t => DP.Binary a => Messenger t a -> IO ()
bind msgr = do
  T.bind (getTransport msgr)

queueMessageEntity :: T.Transport t => DP.Binary a => 
                      Messenger t a -> T.Entity t -> a -> IO ()
queueMessageEntity msger entity msg = do
  T.queueMessageEntity (getTransport msger) entity (DP.encode msg)

queueMessageConn :: T.Transport t => DP.Binary a =>
                    Messenger t a -> T.Connection t -> a -> IO ()
queueMessageConn messenger conn message =
  T.queueMessage (getTransport messenger) conn (DP.encode message)


