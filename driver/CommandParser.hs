{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module CommandParser
  ( Parser
  , runParser
  , pChannel
  , pNick
  , pRemaining
  , pRemainingNoSp
  , pRemainingNoSpLimit
  , pToken
  , pValidToken
  , pTarget
  , pChar
  , pSatisfy
  , pHaskell
  , pAnyChar
  , pNumber
  , commandsParser
  , many'
  ) where

import Data.Char
import Data.List (find)
import Text.Read (readMaybe)
import Control.Monad
import Control.Lens
import Control.Applicative
import Graphics.Vty.Image hiding ((<|>))
import qualified Graphics.Vty.Image as Vty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import ClientState
import Irc.Model
import Irc.Format
import HaskellHighlighter
import ImageUtils


newtype Parser a = Parser (String -> (String, Image, Maybe a))
  deriving (Functor)

runParser :: Parser a -> String -> (Image, Maybe a)
runParser (Parser p) s
  | all isSpace rest = (img Vty.<|> stringWithControls defAttr rest, res)
  | otherwise = (img Vty.<|> stringWithControls (withForeColor defAttr red) rest, Nothing)
  where
  (rest,img,res) = p s

instance Applicative Parser where
  pure x = Parser (\s -> (s,emptyImage,Just x))
  Parser f <*> Parser x = Parser (\s -> case f s of
                                          (s1,i1,r1) ->
                                             case x s1 of
                                               (s2,i2,r2) ->
                                                 (s2,i1 Vty.<|> i2,r1<*>r2))

instance Alternative Parser where
  empty = Parser (\s -> (s,emptyImage,Nothing))
  Parser x <|> Parser y = Parser $ \s ->
    case (x s,y s) of
      (rx@(_,_,Just{}),_) -> rx
      (_,ry@(_,_,Just{})) -> ry
      (rx,_) -> rx

pAnyChar :: Parser Char
pAnyChar = pValidToken "character" $ \t ->
  case t of
    [x] -> Just x
    _   -> Nothing

pValidToken :: String -> (String -> Maybe a) -> Parser a
pValidToken name validate = Parser $ \s ->
  let (w,s1) = span (==' ') s
      (t,s2) = break (==' ') s1
      img c  = stringWithControls (withForeColor defAttr c) (w ++ t)
  in if null t
       then ("", char defAttr ' ' Vty.<|>
                 stringWithControls (withStyle defAttr reverseVideo) name Vty.<|>
                 stringWithControls defAttr (drop (length name + 1) w)
              , Nothing)
       else case validate t of
              Just x -> (s2, img green, Just x)
              Nothing -> (s2, img red, Nothing)

pToken :: String -> Parser String
pToken name = pValidToken name Just

pRemaining :: Parser String
pRemaining = Parser (\s -> ("", stringWithControls defAttr s, Just s))

pRemainingNoSp :: Parser String
pRemainingNoSp = fmap (dropWhile isSpace) pRemaining

pRemainingNoSpLimit :: Int -> Parser String
pRemainingNoSpLimit len =
  Parser (\s ->
    let (w,s') = span (==' ') s
        (a,b) = splitAt len (dropWhile isSpace s')
    in if null b then ("", stringWithControls defAttr (w++a), Just a)
                 else ("", stringWithControls defAttr (w++a) Vty.<|>
                           stringWithControls (withForeColor defAttr red) b, Nothing))

pChannel :: ClientState -> Parser Identifier
pChannel st = pValidToken "channel" $ \chan ->
  do let ident = asIdentifier chan
     guard (isChannelName ident (view (clientServer0 . ccConnection) st))
     return ident

pTarget :: Parser Identifier
pTarget = pValidToken "target" (Just . asIdentifier)

pNick :: ClientState -> Parser Identifier
pNick st = pValidToken "nick" $ \nick ->
  do let ident = asIdentifier nick
     guard (isNickName ident (view (clientServer0 . ccConnection) st))
     return ident

asIdentifier :: String -> Identifier
asIdentifier = mkId . Text.encodeUtf8 . Text.pack

pChar :: Char -> Parser Char
pChar c = pSatisfy [c] (== c)

pSatisfy :: String -> (Char -> Bool) -> Parser Char
pSatisfy name f = Parser (\s ->
          case s of
            c1:s1 | f c1 -> (s1, char defAttr c1, Just c1)
                  | otherwise -> (s1, emptyImage, Nothing)
            [] -> (s, string (withStyle defAttr reverseVideo) (' ':name), Nothing))

pHaskell :: Parser String
pHaskell = Parser (\s ->
            ("", cleanText (Text.pack (highlightHaskell s)),
                        Just (drop 1 (highlightHaskell s))))

commandsParser ::
  String ->
  [(String, [String], Parser a)] ->
  (Image, Maybe a)
commandsParser input cmds =
  case find matchCommand cmds of
    Just p -> over _1 (\img -> char defAttr '/' Vty.<|>
                               stringWithControls (withForeColor defAttr yellow) cmd Vty.<|>
                               img)
                      (runParser (view _3 p) rest)

    Nothing -> ( char defAttr '/' Vty.<|>
                 stringWithControls (withForeColor defAttr red) (drop 1 input)
               , Nothing)
  where
  (cmd,rest) = break (==' ') (drop 1 input)
  matchCommand (c,cs,_) = cmd `elem` c:cs

-- | Many parser that works in this infinite model
-- NOTE: MUST BE END OF PARSER!
many' :: Parser a -> Parser [a]
many' p = [] <$ pEnd
      <|> liftA2 (:) p (many' p)

pEnd :: Parser ()
pEnd = Parser (\s ->
          if all isSpace s then ("", string defAttr s, Just ())
                           else (s , emptyImage      , Nothing))

pNumber :: Parser Int
pNumber = pValidToken "number" readMaybe
