{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

#ifndef MIN_VERSION_base
#define MIN_VERSION_base(x,y,z) 1
#endif

#ifndef MIN_VERSION_time
#define MIN_VERSION_time(x,y,z) 1
#endif

module Views.Channel (channelImage) where

import           Control.Lens
import qualified Data.ByteString as BS
import           Data.Foldable (toList)
import           Data.List (intersperse)
import           Data.Maybe (isJust)
import qualified Data.Map as Map
import           Data.Monoid
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Time (TimeZone, UTCTime, formatTime, utcToZonedTime)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Graphics.Vty.Image
import           Text.Regex.TDFA
import           Text.Regex.TDFA.ByteString (compile, execute)

#if MIN_VERSION_time(1,5,0)
import Data.Time (defaultTimeLocale)
#else
import System.Locale (defaultTimeLocale)
#endif

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif

import Irc.Format
import Irc.Message
import Irc.Model
import Irc.Core

import ClientState
import ImageUtils

channelImage :: ClientState -> [Image]
channelImage st
  | view clientDetailView st = detailedImageForState st
  | otherwise                = compressedImageForState st

detailedImageForState :: ClientState -> [Image]
detailedImageForState !st
  = [ renderOne chan msg | (chan, msg, _img) <- activeMessages st]
  where
  zone = view clientTimeZone st
  renderOne chan x =
      timestamp <|>
      channel <|>
      string (withForeColor defAttr tyColor) (ty ++ " ") <|>
      statusMsgImage (view mesgStatus x) <|>
      renderFullUsermask (view mesgSender x) <|>
      string (withForeColor defAttr blue) (": ") <|>
      cleanText content
    where
    timestamp
      | view clientTimeView st = renderTimestamp zone (view mesgStamp x)
      | otherwise              = emptyImage

    -- show all channel names in detailed/full view
    channel
      | view clientFullView st = identImg (withForeColor defAttr brightBlack) chan
                              <|> string defAttr " "
      | otherwise              = emptyImage

    (tyColor, ty, content) = case view mesgType x of
       JoinMsgType              -> (green  , "Join", "")
       PartMsgType txt          -> (red    , "Part", txt)
       NickMsgType txt          -> (yellow , "Nick", asUtf8 (idBytes txt))
       QuitMsgType txt          -> (red    , "Quit", txt)
       PrivMsgType txt          -> (blue   , "Priv", txt)
       TopicMsgType txt         -> (yellow , "Topc", txt)
       ActionMsgType txt        -> (blue   , "Actn", txt)
       CtcpRspMsgType cmd txt   -> (yellow , "Ctcp", asUtf8 (cmd <> " " <> txt))
       CtcpReqMsgType cmd txt   -> (yellow , "Ctcp", asUtf8 (cmd <> " " <> txt))
       AwayMsgType txt          -> (yellow , "Away", txt)
       NoticeMsgType txt        -> (blue   , "Note", txt)
       KickMsgType who txt      -> (red    , "Kick", asUtf8 (idBytes who) <> " - " <> txt)
       ErrorMsgType txt         -> (red    , "ErrT", txt)
       ErrMsgType err           -> (red    , "ErrR", Text.pack (show err))
       InviteMsgType            -> (yellow , "Invt", "")
       KnockMsgType             -> (yellow , "Knoc", "")
       CallerIdDeliveredMsgType -> (yellow , "Delv", "")
       CallerIdMsgType          -> (yellow , "Call", "")
       ModeMsgType pol mode arg -> (yellow , "Mode", (if pol then "+" else "-")
                                        <> Text.pack [mode, ' ']
                                        <> asUtf8 arg)

renderTimestamp :: TimeZone -> UTCTime -> Image
renderTimestamp zone
  = string (withForeColor defAttr brightBlack)
  . formatTime defaultTimeLocale "%F %H:%M:%S "
  . utcToZonedTime zone

renderCompressedTimestamp :: TimeZone -> UTCTime -> Image
renderCompressedTimestamp zone
  = string (withForeColor defAttr brightBlack)
  . formatTime defaultTimeLocale "[%H:%M] "
  . utcToZonedTime zone

activeMessages :: ClientState -> [(Identifier,IrcMessage,Image)]
activeMessages st =
  case clientInputFilter st of
    FilterNicks nicks -> let nickset = Set.fromList (mkId . toUtf8 <$> nicks)
                         in filter (nicksFilter nickset . view _2) msgs
    FilterBody regex -> let r = compile defaultCompOpt defaultExecOpt regex
                        in filter (bodyFilter r . view _2) msgs
    NoFilter        -> msgs
  where
  focus = focusedName st

  msgs :: [(Identifier,IrcMessage,Image)]
  msgs | view clientFullView st = interleavedMessages st
       | otherwise =
           [ (focus, msg, img) | (msg,img) <- views (clientMessages . ix (focusedName st) . mlMessages) toList st ]

  nicksFilter nickset msg
    = views mesgSender userNick msg `Set.member` nickset

  bodyFilter :: Either a Regex -> IrcMessage -> Bool
  bodyFilter (Left _) _    = True -- regex compilation failed
  bodyFilter (Right r) msg =
    let isMatch = either (const True) isJust . execute r
    in isMatch (textOfMessage msg)

textOfMessage :: IrcMessage -> BS.ByteString
textOfMessage mesg =
    let f n = idBytes (views mesgSender userNick mesg) <> ": " <> Text.encodeUtf8 n
    in f (case mesg ^. mesgType of
             PrivMsgType   t -> t
             NoticeMsgType t -> t
             ActionMsgType t -> t
             KickMsgType _ t -> t
             PartMsgType   t -> t
             QuitMsgType   t -> t
             TopicMsgType  t -> t
             ErrorMsgType  t -> t
             _               -> "")

data InputFilter = FilterNicks [String] | FilterBody BS.ByteString | NoFilter

clientInputFilter :: ClientState -> InputFilter
clientInputFilter st = go (clientInput st)
 where
     go (splitAt 8 -> ("/filter ",nicks)) = FilterNicks (words nicks)
     go (splitAt 6 -> ("/grep ",   txt)) = FilterBody (toUtf8 txt)
     go  _                               = NoFilter

compressedImageForState :: ClientState -> [Image]
compressedImageForState !st = renderOne (activeMessages st)
  where
  zone = view clientTimeZone st
  width = view clientWidth st
  activeChan = focusedName st

  ncolors = views clientNickColors length st
  formatNick me nick = identImg (withForeColor defAttr color) nick
    where
    color | me = red
          | otherwise = view clientNickColors st
                     !! mod (nickHash (idDenote nick)) ncolors

  ignores = view clientIgnores st

  renderOne [] = []
  renderOne ((chan,msg,colored):msgs) =
    case mbImg of
      Just img -> (timestamp <|> channel <|> img) : renderOne msgs
      Nothing  -> renderMeta ((chan,msg,colored):msgs)

    where
    timestamp
      | view clientTimeView st = renderCompressedTimestamp zone (view mesgStamp msg)
      | otherwise              = emptyImage

    nick = views mesgSender userNick msg

    visible = not (view (contains nick) ignores)

    -- when in the full monitor view we only show the names of the channels
    -- next to messages for the unfocused channel
    channel
      | chan == activeChan     = emptyImage
      | otherwise              = identImg (withForeColor defAttr brightBlack) chan
                              <|> string defAttr " "

    mbImg =
       case view mesgType msg of
         PrivMsgType _ | visible -> Just $
           statusMsgImage (view mesgStatus msg) <|>
           views mesgModes modePrefix msg <|>
           formatNick (view mesgMe msg) nick <|>
           string (withForeColor defAttr blue) (": ") <|>
           colored

         NoticeMsgType _ | visible -> Just $
           statusMsgImage (view mesgStatus msg) <|>
           string (withForeColor defAttr red) "! " <|>
           views mesgModes modePrefix msg <|>
           identImg (withForeColor defAttr red) nick <|>
           string (withForeColor defAttr blue) (": ") <|>
           colored

         ActionMsgType _ | visible -> Just $
           statusMsgImage (view mesgStatus msg) <|>
           string (withForeColor defAttr blue) "* " <|>
           views mesgModes modePrefix msg <|>
           identImg (withForeColor defAttr blue) nick <|>
           char defAttr ' ' <|>
           colored

         CtcpRspMsgType cmd params | visible -> Just $
           string (withForeColor defAttr red) "C " <|>
           views mesgModes modePrefix msg <|>
           identImg (withForeColor defAttr blue) nick <|>
           char defAttr ' ' <|>
           cleanText (asUtf8 cmd) <|>
           char defAttr ' ' <|>
           cleanText (asUtf8 params)

         KickMsgType who reason -> Just $
           views mesgModes modePrefix msg <|>
           formatNick (view mesgMe msg) nick <|>
           string (withForeColor defAttr red) " kicked " <|>
           identImg (withForeColor defAttr yellow) who <|>
           string (withForeColor defAttr blue) (": ") <|>
           cleanText reason

         ErrorMsgType err -> Just $
           string (withForeColor defAttr red) "Error: " <|>
           cleanText err

         ErrMsgType err -> Just $
           string (withForeColor defAttr red) "Error: " <|>
           text' defAttr (errorMessage err)

         InviteMsgType -> Just $
           identImg (withForeColor defAttr green) nick <|>
           text' defAttr " has invited you to join"

         CallerIdDeliveredMsgType -> Just $
           identImg (withForeColor defAttr green) nick <|>
           text' defAttr " has been notified of your message"

         CallerIdMsgType -> Just $
           identImg (withForeColor defAttr green) nick <|>
           text' defAttr " has sent you a message, use /ACCEPT to accept"

         ModeMsgType pol m arg -> Just $
           views mesgModes modePrefix msg <|>
           formatNick (view mesgMe msg) nick <|>
           string (withForeColor defAttr red) " set mode " <|>
           string (withForeColor defAttr white) ((if pol then '+' else '-'):[m,' ']) <|>
           utf8Bytestring' (withForeColor defAttr yellow) arg

         TopicMsgType txt -> Just $
           views mesgModes modePrefix msg <|>
           formatNick (view mesgMe msg) nick <|>
           string (withForeColor defAttr red) " set topic " <|>
           cleanText txt

         AwayMsgType txt -> Just $
           string (withForeColor defAttr red) "A " <|>
           formatNick (view mesgMe msg) nick <|>
           string (withForeColor defAttr red) " is away: " <|>
           cleanText txt

         _ -> Nothing

  renderMeta msgs = img
                 ++ renderOne rest
    where
    (mds,rest) = splitWith processMeta msgs
    mds1 = mergeMetadatas mds
    gap = char defAttr ' '

    -- the mds1 can be null in the full view due to dropped metas
    img | not (null mds1), view clientMetaView st
                = return -- singleton list
                $ cropRight width
                $ horizCat
                $ intersperse gap
                $ map renderCompressed mds1
        | otherwise = []

  processMeta (chan,msg,_) =
    case view mesgType msg of
      CtcpReqMsgType{} -> keep $ SimpleMetadata (char (withForeColor defAttr brightBlue) 'C') who
      JoinMsgType      -> keep $ SimpleMetadata (char (withForeColor defAttr green) '+') who
      PartMsgType{}    -> keep $ SimpleMetadata (char (withForeColor defAttr red) '-') who
      QuitMsgType{}    -> keep $ SimpleMetadata (char (withForeColor defAttr red) 'x') who
      KnockMsgType     -> keep $ SimpleMetadata (char (withForeColor defAttr yellow) 'K') who
      NickMsgType who' -> keep $ NickChange who who'
      _ | not visible  -> keep $ SimpleMetadata (char (withForeColor defAttr yellow) 'I') who
        | otherwise    -> Done
    where
    keep | chan == activeChan = Keep
         | otherwise          = const Drop
    who = views mesgSender userNick msg
    visible = not (view (contains who) ignores)

  conn = view (clientServer0 . ccConnection) st

  prefixes = view (connChanModeTypes . modesPrefixModes) conn

  modePrefix modes =
    string (withForeColor defAttr blue)
    [ prefix | (mode,prefix) <- prefixes, mode `elem` modes]

data CompressedMetadata
  = SimpleMetadata Image Identifier
  | NickChange Identifier Identifier

renderCompressed :: CompressedMetadata -> Image
renderCompressed md =
  case md of
    SimpleMetadata img who -> img <|> identImg metaAttr who
    NickChange who who' ->
      identImg metaAttr who <|>
      char (withForeColor defAttr yellow) '-' <|>
      identImg metaAttr who'
  where
  metaAttr = withForeColor defAttr brightBlack

statusMsgImage :: String -> Image
statusMsgImage status
  | null status = emptyImage
  | otherwise =
           char defAttr '(' <|>
           string (withForeColor defAttr brightRed) status <|>
           string defAttr ") "


errorMessage :: IrcError -> Text
errorMessage e =
  case e of
    ErrCantKillServer         -> "Can't kill server"
    ErrYoureBannedCreep       -> "Banned from server"
    ErrNoOrigin               -> "No origin on PING or PONG"
    ErrErroneousNickname nick -> "Erroneous nickname: " <> asUtf8 nick
    ErrNoNicknameGiven        -> "No nickname given"
    ErrNicknameInUse nick     -> "Nickname in use: " <> asUtf8 (idBytes nick)
    ErrNotRegistered          -> "Not registered"
    ErrNoSuchServer server    -> "No such server: " <> asUtf8 server
    ErrUnknownMode mode       -> "Unknown mode: " <> Text.pack [mode]
    ErrNoPrivileges           -> "No privileges"
    ErrUnknownUmodeFlag mode  -> "Unknown UMODE: " <> Text.pack [mode]
    ErrUnknownCommand cmd     -> "Unknown command: " <> asUtf8 cmd
    ErrNoTextToSend           -> "No text to send"
    ErrNoMotd                 -> "No MOTD"
    ErrNoRecipient            -> "No recipient"
    ErrNoAdminInfo server     -> "No admin info for server: "<> asUtf8 server
    ErrAcceptFull             -> "ACCEPT list is full"
    ErrAcceptExist            -> "Already on ACCEPT list"
    ErrAcceptNot              -> "Not on ACCEPT list"
    ErrNeedMoreParams cmd     -> "Need more parameters: " <> asUtf8 cmd
    ErrAlreadyRegistered      -> "Already registered"
    ErrNoPermForHost          -> "No permission for host"
    ErrPasswordMismatch       -> "Password mismatch"
    ErrUsersDontMatch         -> "Can't change modes for other users"
    ErrHelpNotFound _         -> "Help topic not found"
    ErrBadChanName name       -> "Illegal channel name: " <> asUtf8 name
    ErrNoOperHost             -> "No OPER line for this host"

    ErrNoSuchNick             -> "No such nick"
    ErrWasNoSuchNick          -> "Was no such nick"
    ErrOwnMode                -> "Can't send while +g is set"
    ErrNoNonReg               -> "Messages blocked from unregistered users"
    ErrIsChanService nick     -> "Protected service: " <> asUtf8 (idBytes nick)
    ErrBanNickChange          -> "Can't change kick when banned"
    ErrNickTooFast            -> "Changed nickname too fast"
    ErrUnavailResource        -> "Resource unavailable"
    ErrThrottle               -> "Unable to join due to throttle"
    ErrTooManyChannels        -> "Too many channels joined"
    ErrServicesDown           -> "Services are unavailable"
    ErrUserNotInChannel nick  -> "Not in channel: " <> asUtf8 (idBytes nick)
    ErrNotOnChannel           -> "Must join channel"
    ErrChanOpPrivsNeeded      -> "Channel privileges needed"
    ErrBadChannelKey          -> "Bad channel key"
    ErrBannedFromChan         -> "Unable to join due to ban"
    ErrChannelFull            -> "Channel is full"
    ErrInviteOnlyChan         -> "Invite only channel"
    ErrNoSuchChannel          -> "No such channel"
    ErrCannotSendToChan       -> "Cannot send to channel"
    ErrTooManyTargets         -> "Too many targets"
    ErrBanListFull mode       -> "Ban list full: " <> Text.singleton mode
    ErrUserOnChannel nick     -> "User already on channel: " <> asUtf8 (idBytes nick)
    ErrLinkChannel chan       -> "Forwarded to: " <> asUtf8 (idBytes chan)
    ErrNeedReggedNick         -> "Registered nick required"
    ErrVoiceNeeded            -> "Voice or operator status required"

    ErrKnockOnChan            -> "Attempted to knock joined channel"
    ErrTooManyKnocks          -> "Too many knocks"
    ErrChanOpen               -> "Knock unnecessary"
    ErrTargUmodeG             -> "Message ignored by +g mode"
    ErrNoPrivs priv           -> "Oper privilege required: " <> asUtf8 priv
    ErrMlockRestricted m ms   -> "Mode '" <> Text.singleton m <> "' in locked set \""
                                 <> asUtf8 ms <> "\""

data SplitResult a
  = Drop   -- drop this element but keep processing
  | Done   -- stop processing
  | Keep a -- produce an output and keep processing

splitWith :: (a -> SplitResult b) -> [a] -> ([b],[a])
splitWith _ [] = ([],[])
splitWith f (x:xs) =
  case f x of
    Done -> ([],x:xs)
    Drop -> splitWith f xs
    Keep y  -> case splitWith f xs of
                 (ys,xs') -> (y:ys, xs')

mergeMetadatas :: [CompressedMetadata] -> [CompressedMetadata]
mergeMetadatas (SimpleMetadata img1 who1 : SimpleMetadata img2 who2 : xs)
  | who1 == who2      = mergeMetadatas (SimpleMetadata (img1 <|> img2) who1 : xs)
mergeMetadatas (x:xs) = x : mergeMetadatas xs
mergeMetadatas []     = []

interleavedMessages :: ClientState -> [(Identifier,IrcMessage,Image)]
interleavedMessages st = merge lists
  where
  lists :: [[(Identifier,IrcMessage,Image)]]
  lists = [ [ (chan, msg, img) | (msg,img) <- view mlMessages msgs ]
          | (chan,msgs) <- views clientMessages Map.toList st
          ]

  merge ::
    [[(Identifier,IrcMessage,Image)]] ->
    [(Identifier,IrcMessage,Image)]
  merge []  = []
  merge [x] = x
  merge xs  = merge (mergeN1 xs)

  -- merge every two lists into one
  mergeN1 ::
    [[(Identifier,IrcMessage,Image)]] ->
    [[(Identifier,IrcMessage,Image)]]
  mergeN1 [] = []
  mergeN1 [x] = [x]
  mergeN1 (x:y:z) = merge2 x y : mergeN1 z

  -- merge two sorted lists into one
  merge2 ::
    [(Identifier,IrcMessage,Image)] ->
    [(Identifier,IrcMessage,Image)] ->
    [(Identifier,IrcMessage,Image)]
  merge2 [] ys = ys
  merge2 xs [] = xs
  merge2 (x:xs) (y:ys)
    | view (_2.mesgStamp) x >= view (_2.mesgStamp) y = x : merge2 xs (y:ys)
    | otherwise                                      = y : merge2 (x:xs) ys

toUtf8 :: String -> BS.ByteString
toUtf8 = Text.encodeUtf8 . Text.pack
