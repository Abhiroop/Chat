{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent (forkFinally)
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TChan
import Control.Monad (forever)
import Control.Monad.STM

import Data.Map as Map

import System.IO

import Text.Printf

import Network
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

broadcast :: Server -> Message -> STM ()
broadcast Server {..} msg = do
  clientmap <- readTVar clients
  mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)

main :: IO ()
main = do
  server <- newServer
  sock <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  forever $ do
      (handle, host, port) <- accept sock
      printf "Accepted connection from %s: %s\n" host (show port)
      forkFinally (talk handle server) (\_ -> hClose handle)

port :: Int
port = 4444

checkAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server {..} name handle = atomically $ do
  clientmap <- readTVar clients
  if Map.member name clientmap
    then return Nothing
    else do client <- newClient name handle
            writeTVar clients $ Map.insert name client clientmap
            broadcast server $ Notice (name ++ "has connected")
            return (Just client)

talk :: Handle -> Server -> IO ()
talk = undefined
