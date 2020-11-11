{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.QUIC.Packet.Decrypt (
    decryptCrypt
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import Foreign.Ptr
import Network.ByteOrder

import Network.QUIC.Connection
import Network.QUIC.Exception
import Network.QUIC.Imports
import Network.QUIC.Packet.Frame
import Network.QUIC.Packet.Header
import Network.QUIC.Packet.Number
import Network.QUIC.TLS
import Network.QUIC.Types

----------------------------------------------------------------

decryptCrypt :: Connection -> Crypt -> EncryptionLevel -> IO (Maybe Plain)
decryptCrypt conn Crypt{..} lvl = handleLogR logAction $ do
    cipher <- getCipher conn lvl
    coder <- getCoder conn lvl
    let proFlags = Flags (cryptPacket `B.index` 0)
        sampleOffset = cryptPktNumOffset + 4
        sampleLen = sampleLength cipher
        sample = Sample $ B.take sampleLen $ B.drop sampleOffset cryptPacket
        makeMask = unprotect coder
        Mask mask = makeMask sample
        Just (mask1,mask2) = B.uncons mask
        rawFlags@(Flags flags) = unprotectFlags proFlags mask1
        epnLen = decodePktNumLength rawFlags
        epn = B.take epnLen $ B.drop cryptPktNumOffset cryptPacket
        bytePN = bsXOR mask2 epn
        headerSize = cryptPktNumOffset + epnLen
        (proHeader, ciphertext) = B.splitAt headerSize cryptPacket
    peerPN <- if lvl == RTT1Level then getPeerPacketNumber conn else return 0
    let pn = decodePacketNumber peerPN (toEncodedPacketNumber bytePN) epnLen
    header <- B.create headerSize $ \p -> do
        void $ copy p proHeader
        poke8 flags p 0
        void $ copy (p `plusPtr` cryptPktNumOffset) $ B.take epnLen bytePN
    let mpayload = decrypt coder ciphertext header pn
        rrMask | lvl == RTT1Level = 0x18
               | otherwise        = 0x0c
        marks | flags .&. rrMask == 0 = defaultPlainMarks
              | otherwise             = setIllegalReservedBits defaultPlainMarks
    case mpayload of
      Nothing      -> return Nothing
      Just payload -> do
          frames <- decodeFrames payload
          let marks' | null frames = setFrameBroken marks
                     | otherwise   = marks
          return $ Just $ Plain rawFlags pn frames marks'
  where
    logAction msg = do
        connDebugLog conn ("decryptCrypt: " <> msg)
        return Nothing

toEncodedPacketNumber :: ByteString -> EncodedPacketNumber
toEncodedPacketNumber bs = foldl' (\b a -> b * 256 + fromIntegral a) 0 $ B.unpack bs
