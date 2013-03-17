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
  { getTransport :: t
  , mActions :: [(Messenger t a -> T.Connection t -> a -> Maybe (IO ()))]
  , eActions :: [(Messenger t a -> T.Connection t ->
                  T.ConnException -> Maybe (IO ()))]
  }

makeMessenger :: T.Transport t => Serialize a =>
                 [(Messenger t a -> T.Connection t -> a -> Maybe (IO ()))] ->
                 [(Messenger t a -> T.Connection t ->
                   T.ConnException -> Maybe (IO ()))] ->
                 IO (Messenger t a)
makeMessenger _mActions _eActions = 
  let
    firstJust [] = Nothing
    firstJust (x:xs) = case x of
      Just x -> Just x
      Nothing -> firstJust xs

    collapse ms trans conn bs = firstJust [x trans conn bs | x <- ms]

    decodify msgr x = \_ conn bs -> case decode bs of
      Left _ -> Nothing
      Right msg -> x msgr conn msg

    eActions msgr = collapse $ [\_ -> y msgr | y <- _eActions]
    mActions msgr = collapse $ map (decodify msgr) _mActions

    msger = Messenger { getTransport =
                           T.makeTransport (mActions msger) (eActions msger)
                      , mActions = _mActions
                      , eActions = _eActions
                      }
  in
   do
     T.startTransport $ getTransport msger
     return msger
     

queueMessage :: T.Transport t => Serialize a =>
                Messenger t a -> T.Connection t -> a -> IO ()
queueMessage messenger conn message =
  T.queueMessage (getTransport messenger) conn (encode message)


