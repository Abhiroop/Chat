{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent (forkFinally)
import Control.Concurrent.Async
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TChan
import Control.Distributed.Process (ProcessId, Process, getSelfPid, liftIO, send)
import Control.Exception
import Control.Monad (forever, when, join, void)
import Control.Monad.STM

import Data.Typeable
import Data.Binary
import Data.Map as Map hiding (null)

import GHC.Generics

import System.IO

import Text.Printf

import Network
import Lib

type ClientName = String

data Client = ClientLocal LocalClient
            | ClientRemote RemoteClient

data RemoteClient = RemoteClient
  { remoteName :: ClientName
  , clientHome :: ProcessId}


data LocalClient = LocalClient
  { localName      :: ClientName
  , clientHandle   :: Handle
  , clientKicked   :: TVar (Maybe String)
  , clientSendChan :: TChan Message
  }

clientName :: Client -> ClientName
clientName (ClientLocal c) = localName c
clientName (ClientRemote c) = remoteName c


data Message = Notice String
             | Tell ClientName String
             | Broadcast ClientName String
             | Command String
   deriving (Typeable, Generic)

instance Binary Message

newLocalClient :: ClientName -> Handle -> STM LocalClient
newLocalClient name handle = do
  c <- newTChan
  k <- newTVar Nothing
  return LocalClient {localName     = name
                     ,clientHandle   = handle
                     ,clientKicked   = k
                     ,clientSendChan = c
                     }

data PMessage
  = MsgServers            [ProcessId]
  | MsgSend               ClientName Message
  | MsgBroadcast          Message
  | MsgKick               ClientName ClientName
  | MsgNewClient          ClientName ProcessId
  | MsgClientDisconnected ClientName ProcessId
  deriving (Typeable, Generic)

instance Binary PMessage

data Server = Server
  { clients   :: TVar (Map ClientName Client)
  , proxychan :: TChan (Process ())
  , servers   :: TVar [ProcessId]
  , spid      :: ProcessId --process id of the server for convenience
  }

newServer :: [ProcessId] -> Process Server
newServer pids = do
  pid <- getSelfPid
  liftIO $ do
    s <- newTVarIO pids
    c <- newTVarIO Map.empty
    o <- newTChanIO
    return Server { clients = c, servers = s, proxychan = o, spid = pid }

---------------SENDING MESSAGES--------------------------------

sendLocal :: LocalClient -> Message -> STM ()
sendLocal LocalClient{..} msg = writeTChan clientSendChan msg

sendRemote :: Server -> ProcessId -> PMessage -> STM ()
sendRemote Server{..} pid pmsg = writeTChan proxychan (send pid pmsg)

sendMessage :: Server -> Client -> Message -> STM ()
sendMessage server (ClientLocal client) msg = sendLocal client msg
sendMessage server (ClientRemote client) msg = sendRemote server (clientHome client) (MsgSend (remoteName client) msg)

sendToName :: Server -> ClientName -> Message -> STM Bool
sendToName server@Server{..} name msg = do
  clientmap <- readTVar clients
  case Map.lookup name clientmap of
    Nothing -> return False
    Just client -> sendMessage server client msg >> return True

----------------BROADCASTING-------------------------------
-- broadcast :: Server -> Message -> STM ()
-- broadcast Server {..} msg = do
--   clientmap <- readTVar clients
--   mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)

-- sendToName :: Server -> ClientName -> Message -> STM Bool
-- sendToName server@Server{..} name msg = do
--   clientmap <- readTVar clients
--   case Map.lookup name clientmap of
--     Nothing     -> return False
--     Just client -> sendMessage client msg >> return True

-- tell :: Server -> Client -> ClientName -> String -> IO ()
-- tell server@Server{..} Client{..} who msg = do
--   ok <- atomically $ sendToName server who (Tell clientName msg)
--   if ok
--      then return ()
--      else hPutStrLn clientHandle (who ++ " is not connected.")

-- kick :: Server -> ClientName -> ClientName -> STM ()
-- kick server@Server{..} who by = do
--   clientmap <- readTVar clients
--   case Map.lookup who clientmap of
--     Nothing ->
--       void $ sendToName server by (Notice $ who ++ " is not connected")
--     Just victim -> do
--       writeTVar (clientKicked victim) $ Just ("by " ++ by)
--       void $ sendToName server by (Notice $ "you kicked " ++ who)

main :: IO ()
main = undefined-- do
  -- server <- newServer
  -- sock <- listenOn (PortNumber (fromIntegral port))
  -- printf "Listening on port %d\n" port
  -- forever $ do
  --     (handle, host, port) <- accept sock
  --     printf "Accepted connection from %s: %s\n" host (show port)
  --     forkFinally (talk handle server) (\_ -> hClose handle)

port :: Int
port = 4444

-- checkAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
-- checkAddClient server@Server {..} name handle = atomically $ do
--   clientmap <- readTVar clients
--   if Map.member name clientmap
--     then return Nothing
--     else do client <- newClient name handle
--             writeTVar clients $ Map.insert name client clientmap
--             broadcast server $ Notice (name ++ "has connected")
--             return (Just client)

-- removeClient :: Server -> ClientName -> IO ()
-- removeClient server@Server{..} name = atomically $ do
--   modifyTVar' clients $ Map.delete name
--   broadcast server $ Notice (name ++ " has disconnected")

-- talk :: Handle -> Server -> IO ()
-- talk handle server@Server{..} = do
--   hSetNewlineMode handle universalNewlineMode
--   hSetBuffering handle LineBuffering
--   readName
--  where readName = do
--          hPutStrLn handle "What is your name?"
--          name <- hGetLine handle
--          if null name
--            then readName
--            else mask $ \restore -> do
--                   ok <- checkAddClient server name handle
--                   case ok of
--                     Nothing -> restore $ do
--                       hPrintf handle
--                         "The name %s is in use, please choose another\n" name
--                       readName
--                     Just client ->
--                       restore (runClient server client)
--                           `finally` removeClient server name

-- runClient :: Server -> Client -> IO ()
-- runClient serv@Server{..} client@Client{..} = do
--   race server receive
--   return ()
--  where
--   receive = forever $ do
--     msg <- hGetLine clientHandle
--     atomically $ sendMessage client (Command msg)

--   server = join $ atomically $ do
--     k <- readTVar clientKicked
--     case k of
--       Just reason -> return $
--         hPutStrLn clientHandle $ "You have been kicked: " ++ reason
--       Nothing -> do
--         msg <- readTChan clientSendChan
--         return $ do
--             continue <- handleMessage serv client msg
--             when continue $ server

-- handleMessage :: Server -> Client -> Message -> IO Bool
-- handleMessage server client@Client{..} message =
--   case message of
--      Notice msg         -> output $ "*** " ++ msg
--      Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
--      Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
--      Command msg ->
--        case words msg of
--            ["/kick", who] -> do
--                atomically $ kick server who clientName
--                return True
--            "/tell" : who : what -> do
--                tell server client who (unwords what)
--                return True
--            ["/quit"] ->
--                return False
--            ('/':_):_ -> do
--                hPutStrLn clientHandle $ "Unrecognised command: " ++ msg
--                return True
--            _ -> do
--                atomically $ broadcast server $ Broadcast clientName msg
--                return True
--  where
--    output s = do hPutStrLn clientHandle s; return True
