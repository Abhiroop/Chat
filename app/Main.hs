{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent (forkFinally, forkIO)
import Control.Concurrent.Async
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TChan
import Control.Exception
import Control.Monad (forever, when, join, void, zipWithM)
import Control.Monad.STM
import Control.Distributed.Process.Closure
import Control.Distributed.Process (ProcessId,
                                    Process,
                                    NodeId,
                                    expect,
                                    getSelfPid,
                                    liftIO,
                                    say,
                                    send,
                                    spawn,
                                    spawnLocal)

import Data.Typeable
import Data.Binary
import Data.Map as Map hiding (null, filter)

import GHC.Generics

import System.IO

import Text.Printf

import Network
import Lib
import DistribUtils

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
sendRemoteAll :: Server -> PMessage -> STM ()
sendRemoteAll server@Server{..} pmsg = do
  pids <- readTVar servers
  mapM_ (\pid -> sendRemote server pid pmsg) pids

broadcastLocal :: Server -> Message -> STM ()
broadcastLocal server@Server{..} msg = do
  clientmap <- readTVar clients
  mapM_ sendIfLocal (Map.elems clientmap)
 where sendIfLocal (ClientLocal c) = sendLocal c msg
       sendIfLocal (ClientRemote _) = return ()

broadcast :: Server -> Message -> STM ()
broadcast server@Server{..} msg = do
  sendRemoteAll server (MsgBroadcast msg)
  broadcastLocal server msg

tell :: Server -> LocalClient -> ClientName -> String -> IO ()
tell server@Server{..} LocalClient{..} who msg = do
  ok <- atomically $ sendToName server who (Tell localName msg)
  if ok
     then return ()
     else hPutStrLn clientHandle (who ++ " is not connected.")

kick :: Server -> ClientName -> ClientName -> STM ()
kick server@Server{..} who by = do
  clientmap <- readTVar clients
  case Map.lookup who clientmap of
    Nothing ->
      void $ sendToName server by (Notice $ who ++ " is not connected")
    Just (ClientLocal victim) -> do
      writeTVar (clientKicked victim) $ Just ("by " ++ by)
      void $ sendToName server by (Notice $ "you kicked " ++ who)
    Just (ClientRemote victim) -> do
      sendRemote server (clientHome victim) (MsgKick who by)

socketListener :: Server -> Int -> IO ()
socketListener server port = do
  sock <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  forever $ do
      (handle, host, port) <- accept sock
      printf "Accepted connection from %s: %s\n" host (show port)
      forkFinally (talk server handle) (\_ -> hClose handle)

chatServer :: Int -> Process ()
chatServer port = do
  server <- newServer []
  liftIO $ forkIO (socketListener server port)
  spawnLocal $ proxy server
  forever $ do m <- expect; handleRemoteMessage server m

handleRemoteMessage :: Server -> PMessage -> Process ()
handleRemoteMessage server@Server{..} m = liftIO $ atomically $
  case m of
    MsgServers pids -> writeTVar servers (filter (/= spid) pids)
    MsgSend name msg -> void $ sendToName server name msg
    MsgBroadcast msg -> broadcastLocal server msg
    MsgKick who by   -> kick server who by
    MsgNewClient name pid -> do
        ok <- checkAddClient server (ClientRemote (RemoteClient name pid))
        when (not ok) $
          sendRemote server pid (MsgKick name "SYSTEM")

    MsgClientDisconnected name pid -> do
         clientmap <- readTVar clients
         case Map.lookup name clientmap of
            Nothing -> return ()
            Just (ClientRemote (RemoteClient _ pid')) | pid == pid' ->
              deleteClient server name
            Just _ -> return ()

proxy :: Server -> Process ()
proxy Server{..} = forever $ join $ liftIO $ atomically $ readTChan proxychan

checkAddClient :: Server -> Client -> STM Bool
checkAddClient server@Server{..} client = do
    clientmap <- readTVar clients
    let name = clientName client
    if Map.member name clientmap
       then return False
       else do writeTVar clients (Map.insert name client clientmap)
               broadcastLocal server $ Notice $ name ++ " has connected"
               return True

removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} name = atomically $ do
  modifyTVar' clients $ Map.delete name
  broadcast server $ Notice (name ++ " has disconnected")

talk :: Server -> Handle -> IO ()
talk server@Server{..} handle = do
    hSetNewlineMode handle universalNewlineMode
        -- Swallow carriage returns sent by telnet clients
    hSetBuffering handle LineBuffering
    readName
  where
-- <<readName
    readName = do
      hPutStrLn handle "What is your name?"
      name <- hGetLine handle
      if null name
         then readName
         else mask $ \restore -> do
                client <- atomically $ newLocalClient name handle
                ok <- atomically $ checkAddClient server (ClientLocal client)
                if not ok
                  then restore $ do
                     hPrintf handle
                        "The name %s is in use, please choose another\n" name
                     readName
                  else do
                     atomically $ sendRemoteAll server (MsgNewClient name spid)
                     restore (runClient server client)
                       `finally` disconnectLocalClient server name

deleteClient :: Server -> ClientName -> STM ()
deleteClient server@Server{..} name = do
    modifyTVar' clients $ Map.delete name
    broadcastLocal server $ Notice $ name ++ " has disconnected"

disconnectLocalClient :: Server -> ClientName -> IO ()
disconnectLocalClient server@Server{..} name = atomically $ do
     deleteClient server name
     sendRemoteAll server (MsgClientDisconnected name spid)

runClient :: Server -> LocalClient -> IO ()
runClient serv@Server{..} client@LocalClient{..} = do
  race server receive
  return ()
 where
  receive = forever $ do
    msg <- hGetLine clientHandle
    atomically $ sendLocal client (Command msg)

  server = join $ atomically $ do
    k <- readTVar clientKicked
    case k of
      Just reason -> return $
        hPutStrLn clientHandle $ "You have been kicked: " ++ reason
      Nothing -> do
        msg <- readTChan clientSendChan
        return $ do
            continue <- handleMessage serv client msg
            when continue $ server

handleMessage :: Server -> LocalClient -> Message -> IO Bool
handleMessage server client@LocalClient{..} message =
  case message of
     Notice msg         -> output $ "*** " ++ msg
     Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
     Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
     Command msg ->
       case words msg of
           ["/kick", who] -> do
               atomically $ kick server who localName
               return True
           "/tell" : who : what -> do
               tell server client who (unwords what)
               return True
           ["/quit"] ->
               return False
           ('/':_):_ -> do
               hPutStrLn clientHandle $ "Unrecognised command: " ++ msg
               return True
           _ -> do
               atomically $ broadcast server $ Broadcast localName msg
               return True
 where
   output s = do hPutStrLn clientHandle s; return True

remotable ['chatServer]

port :: Int
port = 44444

master :: [NodeId] -> Process ()
master peers = do

  let run nid port = do
         say $ printf "spawning on %s" (show nid)
         spawn nid ($(mkClosure 'chatServer) port)

  pids <- zipWithM run peers [port+1..]
  mypid <- getSelfPid
  let all_pids = mypid : pids
  mapM_ (\pid -> send pid (MsgServers all_pids)) all_pids

  chatServer port

main = distribMain master Main.__remoteTable
