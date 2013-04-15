{-# LANGUAGE TypeFamilies, RankNTypes, FlexibleContexts #-}
module Messenger ( Messenger
                 , makeMessenger
                 , start
                 , queueMessageEntity
                 , queueMessageConn
                 , MConfig (MConfig)
                 , transType
                 , msgHandler
                 , onError
                 , handleConnect
                 , faultPolicy
                 ) where

import qualified Data.Serialize as DP
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
  Messenger { getTransport :: t
            }

data MConfig t a = 
  MConfig { transType :: T.TransType
          , msgHandler :: [Messenger t a -> T.Connection t ->
                           a -> Maybe (STM ())]
          , onError :: [Messenger t a -> T.Connection t ->
                        T.ConnException -> Maybe (STM ())]
          , handleConnect :: Messenger t a -> T.Addr t -> STM (T.Priv t)
          , faultPolicy :: Messenger t a -> T.Connection t -> T.ReactOnFault
          }

makeMessenger :: (T.Transport t,  DP.Serialize a) =>
                 T.Addr t -> MConfig t a -> IO (Messenger t a)
makeMessenger addr mconf = 
  let
    firstJust [] = Nothing
    firstJust (x:xs) = case x of
      Just x -> Just x
      Nothing -> firstJust xs

    collapse ms trans conn bs = case firstJust [x trans conn bs | x <- ms] of
      Nothing -> return ()
      Just x -> x

    decodify x = \t conn bs -> case (DP.decodeLazy bs) of
      Left err -> Nothing
      Right y -> x (Messenger { getTransport = t }) conn y
      

    eActions = collapse $
               [\t -> y (Messenger { getTransport = t }) | y <- onError mconf]
    mActions = collapse $ map decodify (msgHandler mconf)
  in
   do
     trans <- T.makeTransport addr $ T.TInit {
       T.transType = transType mconf,
       T.onMsgRec = mActions,
       T.onError = eActions,
       T.faultPolicy = \t -> (faultPolicy mconf) $ Messenger { getTransport = t},
       T.handleConnect = \t -> (handleConnect mconf) $ Messenger { getTransport = t}
       }
     return $ Messenger { getTransport = trans }

start :: (T.Transport t, DP.Serialize a) => Messenger t a -> IO ()
start msgr = do
  T.startTransport (getTransport msgr)

queueMessageEntity :: (T.Transport t, DP.Serialize a) => 
                      Messenger t a -> T.Addr t -> a -> IO ()
queueMessageEntity msger entity msg = do
  T.queueMessageEntity (getTransport msger) entity (DP.encodeLazy msg)

queueMessageConn :: (T.Transport t, DP.Serialize a) =>
                    Messenger t a -> T.Connection t -> a -> IO ()
queueMessageConn messenger conn message =
  T.queueMessage (getTransport messenger) conn (DP.encodeLazy message)


