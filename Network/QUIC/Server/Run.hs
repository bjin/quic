{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.QUIC.Server.Run (
    run
  , stop
  ) where

import qualified Network.Socket as NS
import Network.UDP (UDPSocket(..), ListenSocket(..))
import qualified Network.UDP as UDP
import System.Log.FastLogger
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E

import Network.QUIC.Closer
import Network.QUIC.Common
import Network.QUIC.Config
import Network.QUIC.Connection
import Network.QUIC.Crypto
import Network.QUIC.Exception
import Network.QUIC.Handshake
import Network.QUIC.Imports
import Network.QUIC.Logger
import Network.QUIC.Packet
import Network.QUIC.Parameters
import Network.QUIC.QLogger
import Network.QUIC.Qlog
import Network.QUIC.Receiver
import Network.QUIC.Recovery
import Network.QUIC.Sender
import Network.QUIC.Server.Reader
import Network.QUIC.Types

----------------------------------------------------------------

-- | Running a QUIC server.
--   The action is executed with a new connection
--   in a new lightweight thread.
run :: ServerConfig -> (Connection -> IO ()) -> IO ()
run conf server = NS.withSocketsDo $ handleLogUnit debugLog $ do
    baseThreadId <- myThreadId
    E.bracket setup teardown $ \(dispatch,_) -> forever $ do
        acc <- accept dispatch
        void $ forkIO (runServer conf server dispatch baseThreadId acc)
  where
    doDebug = isJust $ scDebugLog conf
    debugLog msg | doDebug   = stdoutLogger ("run: " <> msg)
                 | otherwise = return ()
    setup = do
        dispatch <- newDispatch
        -- fixme: the case where sockets cannot be created.
        ssas <- mapM UDP.serverSocket $ scAddresses conf
        tids <- mapM (runDispatcher dispatch conf) ssas
        ttid <- forkIO timeouter -- fixme
        return (dispatch, ttid:tids)
    teardown (dispatch, tids) = do
        clearDispatch dispatch
        mapM_ killThread tids

-- Typically, ConnectionIsClosed breaks acceptStream.
-- And the exception should be ignored.
runServer :: ServerConfig -> (Connection -> IO ()) -> Dispatch -> ThreadId -> Accept -> IO ()
runServer conf server0 dispatch baseThreadId acc =
    E.bracket open clse $ \(ConnRes conn myAuthCIDs _reader) ->
        handleLogUnit (debugLog conn) $ do
#if !defined(mingw32_HOST_OS)
            forkIO _reader >>= addReader conn
#endif
            let conf' = conf {
                    scParameters = (scParameters conf) {
                          versionInformation = Just $ accVersionInfo acc
                        }
                  }
            handshaker <- handshakeServer conf' conn myAuthCIDs
            let server = do
                    wait1RTTReady conn
                    afterHandshakeServer conn
                    server0 conn
                ldcc = connLDCC conn
                supporters = foldr1 concurrently_ [handshaker
                                                  ,sender   conn
                                                  ,receiver conn
                                                  ,resender  ldcc
                                                  ,ldccTimer ldcc
                                                  ]
                runThreads = do
                    er <- race supporters server
                    case er of
                      Left () -> E.throwIO MustNotReached
                      Right r -> return r
            E.trySyncOrAsync runThreads >>= closure conn ldcc
  where
    open = createServerConnection conf dispatch acc baseThreadId
    clse connRes = do
        let conn = connResConnection connRes
        setDead conn
        freeResources conn
#if !defined(mingw32_HOST_OS)
        killReaders conn
#endif
        getSocket conn >>= UDP.close
    debugLog conn msg = do
        connDebugLog conn ("runServer: " <> msg)
        qlogDebug conn $ Debug $ toLogStr msg

createServerConnection :: ServerConfig -> Dispatch -> Accept -> ThreadId
                       -> IO ConnRes
createServerConnection conf@ServerConfig{..} dispatch Accept{..} baseThreadId = do
    us <- UDP.accept accMySocket accPeerSockAddr
    let ListenSocket _ mysa _ = accMySocket
    sref <- newIORef us
    let send buf siz = void $ do
            UDPSocket{..} <- readIORef sref
            NS.sendBuf udpSocket buf siz
        recv = recvServer accRecvQ
    let myCID = fromJust $ initSrcCID accMyAuthCIDs
        ocid  = fromJust $ origDstCID accMyAuthCIDs
    (qLog, qclean)     <- dirQLogger scQLog accTime ocid "server"
    (debugLog, dclean) <- dirDebugLogger scDebugLog ocid
    debugLog $ "Original CID: " <> bhow ocid
    conn <- serverConnection conf accVersionInfo accMyAuthCIDs accPeerAuthCIDs debugLog qLog scHooks sref accRecvQ send recv
    addResource conn qclean
    addResource conn dclean
    let cid = fromMaybe ocid $ retrySrcCID accMyAuthCIDs
        ver = chosenVersion accVersionInfo
    initializeCoder conn InitialLevel $ initialSecrets ver cid
    setupCryptoStreams conn -- fixme: cleanup
    let pktSiz = (defaultPacketSize mysa `max` accPacketSize) `min` maximumPacketSize mysa
    setMaxPacketSize conn pktSiz
    setInitialCongestionWindow (connLDCC conn) pktSiz
    debugLog $ "Packet size: " <> bhow pktSiz <> " (" <> bhow accPacketSize <> ")"
    when accAddressValidated $ setAddressValidated conn
    --
    let retried = isJust $ retrySrcCID accMyAuthCIDs
    when retried $ do
        qlogRecvInitial conn
        qlogSentRetry conn
    --
    let mgr = tokenMgr dispatch
    setTokenManager conn mgr
    --
    setBaseThreadId conn baseThreadId
    --
    setRegister conn accRegister accUnregister
    accRegister myCID conn
    addResource conn $ do
        myCIDs <- getMyCIDs conn
        mapM_ accUnregister myCIDs
    --
#if defined(mingw32_HOST_OS)
    return $ ConnRes conn accMyAuthCIDs undefined
#else
    let reader = readerServer us conn -- dies when us is closed.
    return $ ConnRes conn accMyAuthCIDs reader
#endif

afterHandshakeServer :: Connection -> IO ()
afterHandshakeServer conn = handleLogT logAction $ do
    --
    cidInfo <- getNewMyCID conn
    register <- getRegister conn
    register (cidInfoCID cidInfo) conn
    --
    cryptoToken <- generateToken =<< getVersion conn
    mgr <- getTokenManager conn
    token <- encryptToken mgr cryptoToken
    let ncid = NewConnectionID cidInfo 0
    sendFrames conn RTT1Level [NewToken token,ncid,HandshakeDone]
  where
    logAction msg = connDebugLog conn $ "afterHandshakeServer: " <> msg

-- | Stopping the base thread of the server.
stop :: Connection -> IO ()
stop conn = getBaseThreadId conn >>= killThread
