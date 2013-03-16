{-# LANGUAGE TypeFamilies #-}
module Messenger (
                 ) where

import Data.Serialize
import Data.Maybe
import qualified Data.ByteString as BS
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
  {getTransport :: t
  ,channelMap :: TVar (M.Map T.ConnID (Channel a))
  ,perChannelMax :: Int
  }

mkMessenger Transport m => m

deliverMessage :: T.Transport t => Serialize a =>
                  Messenger t a -> T.Connection t -> BS.ByteString -> IO ()
deliverMessage messenger conn message = atomically $ do
  cmap <- readTVar $ channelMap messenger
  fromMaybe (return ()) $ do
    chan' <- M.lookup (T.getConnID (getTransport messenger) conn) cmap
    decoded <- eitherToMaybe $ decode message
    return $ C.putItem chan' decoded (BS.length message)
  where
    eitherToMaybe x = case x of
      Left _ -> Nothing
      Right x -> Just x

queueMessage :: T.Transport t => Serialize a =>
                Messenger t a -> T.Connection t -> a -> IO ()
queueMessage messenger conn message =
  T.queueMessage (getTransport messenger) conn (encode message)


