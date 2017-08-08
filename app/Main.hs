{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TChan
import Control.Monad.STM

import Data.Map as Map

import System.IO

import Lib

type ClientName = String

data Client = Client
  { clientName   :: ClientName
  , clientHandle :: Handle
  , clientKicked :: TVar (Maybe String)
  , clientSendChan :: TChan Message
  }

data Message = Notice String
             | Tell ClientName String
             | Broadcast ClientName String
             | Command String

newClient :: ClientName -> Handle -> STM Client
newClient name handle = do
  c <- newTChan
  k <- newTVar Nothing
  return Client {clientName     = name
                ,clientHandle   = handle
                ,clientKicked   = k
                ,clientSendChan = c
                }

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = writeTChan clientSendChan msg

data Server = Server {clients :: TVar (Map ClientName Client)}

newServer :: IO Server
newServer = do
  c <- newTVarIO Map.empty
  return Server {clients = c}

main :: IO ()
main = someFunc
