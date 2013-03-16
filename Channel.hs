{-# LANGUAGE TypeFamilies #-}

module Channel
       (Channel
       ,canPutItem
       ,putItem
       ,channelEmpty
       ,getItem
       ,tryGetItem
       ,makeChannel
       ) where

import Control.Monad.State
import qualified Data.Sequence as S
import qualified Data.Map as M

import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Concurrent.STM.TVar
import Data.Int

-- Channel
data Channel a =
  Channel
  {channelQ :: (TChan (Int, a))
  ,channelSize :: (TVar Int)
  ,channelMaxSize :: Int
  }

makeChannel :: Int -> STM (Channel a)
makeChannel maxSize = do
  chanQ <- newTChan
  chanSize <- newTVar 0
  return $ Channel {channelQ = chanQ
                   ,channelSize = chanSize
                   ,channelMaxSize = maxSize
                   }
  

canPutItem :: Channel a -> Int -> STM Bool
canPutItem chan amt = do
  curSize <- readTVar $ channelSize chan
  return $ (curSize + amt) <= (channelMaxSize chan)

putItem :: Channel a -> a -> Int -> STM ()
putItem chan item cost = do
  full <- canPutItem chan cost
  if full
    then retry
    else do
      incCost chan cost
      writeTChan (channelQ chan) (cost, item)

channelEmpty :: Channel a -> STM Bool
channelEmpty chan = isEmptyTChan $ channelQ chan

incCost :: Channel a -> Int -> STM ()
incCost chan amt = do
  cur <- readTVar $ channelSize chan
  writeTVar (channelSize chan) (cur + amt)

decCost :: Channel a -> Int -> STM ()
decCost chan amt = incCost chan (0 - amt)

getItem :: Channel a -> STM a
getItem chan = do
  (cost, item) <- readTChan $ channelQ chan
  decCost chan cost
  return item

tryGetItem :: Channel a -> STM (Maybe a)
tryGetItem chan = do
  empty <- channelEmpty chan
  if empty
    then return Nothing
    else getItem chan >>= \x -> return $ Just x

