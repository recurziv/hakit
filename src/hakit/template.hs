{-# LANGUAGE OverloadedStrings #-}
module Template where

import qualified Data.Text as T
import qualified Data.List as L
import qualified Text.ParserCombinators.Parsec as P
import qualified Data.List.Split as Spl

-- This package contains some questionable temporary names now to avoid clash with prelude.

data Attr = Attr (T.Text, T.Text)

instance Show Attr where
    show (Attr (a, b)) = T.unpack a ++ "=" ++ show b

type Child = Tag

data Tag =
        Doctype T.Text
    |   Text    T.Text  
    --          Name        Attributes  Children
    |   Tag     T.Text      [Attr]      [Child]

getAttrs :: Tag ->      [Attr]
getAttrs (Doctype t)    = []
getAttrs (Text t)       = []
getAttrs (Tag _ a _)    = a

getAttr :: Tag -> T.Text -> Maybe T.Text
getAttr tag attrName = case L.find (\(Attr (a, b)) -> a == attrName) (getAttrs tag) of
    Just (Attr (a, b))  -> Just b
    Nothing             -> Nothing

getChildren :: Tag ->       [Child]
getChildren (Doctype t)     = []
getChildren (Text t)        = []
getChildren (Tag _ _ c)     = c

getName :: Tag ->      T.Text
getName (Doctype t)    = "doctype"
getName (Text t)       = "text"
getName (Tag n _ _)    = n

doctype a   = Doctype a
html a c    = Tag "html" a c
head' a c   = Tag "head" a c
body a c    = Tag "body" a c
text t      = Text t
div' a c    = Tag "div" a c
tag n a c   = Tag n a c

attr :: T.Text -> T.Text -> Attr
attr a b = Attr (a, b)

example :: Tag
example =
    html [] [
        head' [] [],
        body [attr "style" "background: #ccc;"] [
            text "Hello world."
        ]
    ]

-- Show attributes
sa :: [Attr] -> String
sa x = let attrs = L.intercalate " " $ map show x in
    if length attrs > 0
        then " " ++ attrs
        else ""

-- Show children.
sc :: [Child] -> String
sc x = L.intercalate "\n" $ map show x

instance Show Tag where
    show (Doctype a)    = "<!DOCTYPE " ++ T.unpack a ++ ">"
    show (Tag n a b)    = "<" ++ T.unpack n ++ sa a ++ ">" ++ sc b ++ "</" ++ T.unpack n ++ ">"
    show (Text a)       = T.unpack a

-- | Just for quick and ugly testing.
-- Tests if a (top level) tag satisfies a given selector
-- (which can contain multiple criteria, like "div.className").
-- Obviously selectors like "div a" or "div > a" won't work in this case.
matches :: T.Text -> Tag -> Bool
matches sel tag = all (flip satisfiesSingle $ tag) (parseSelector sel)

parseSelector :: T.Text -> [Selector]
parseSelector t = let sels = P.parse parseExpr "selector" $ T.unpack t in
    case sels of
        Left e      -> error $ show e
        Right ss    -> ss

satisfiesSingle :: Selector -> Tag -> Bool
satisfiesSingle s tag = case s of
    Type t  -> getName tag == t
    Id  id  -> case getAttr tag "id" of
        Just x  -> x == id
        Nothing -> False
    Class c -> case getAttr tag "class" of
        Just x  -> x == c
        Nothing  -> False
    Attribute reg attrName attrVal -> case getAttr tag attrName of
        Nothing -> False
        Just x  -> case reg of
            StartsWith  -> T.isPrefixOf attrVal x
            EndsWith    -> T.isSuffixOf attrVal x
            Contains    -> T.isInfixOf attrVal x
            Equals      -> x == attrVal
            Any         -> True
    Descendant      -> error $ "can't use descendant separator on: " ++ show tag
    DirectChild     -> error $ "can't use direct child separator on: " ++ show tag

satisfies :: [Tag] -> Tag -> [[Selector]] -> Bool
satisfies parents tag sels =
    let separator x = case x of
            Descendant  -> True
            DirectChild -> True
            otherwise   -> False
        nonseps = L.filter separator sels
        -- ps = Parents satisfy
        -- Called with a sels list ending in a separator, and
        -- with sels' having even length. Eg: [selector, sep, selector, sep]
        ps parents sels'
            | sels == []        = True
            | parents == []     = False     -- And sels /= []
            | otherwise         =
                let sep = last sels'
                    crit = last . last $ sels'
                in case last sels' of
                    Descendant      -> if satisfiesSingle $ last parents
                        then ps (init . init $ sels') $ init parents
                        else ps sels' $ init parents
                    DirectChild     -> if satisfiesSingle $ last parents
                        then ps (init . init $ sels') $ init parents
                        else False
    -- Obviously if there are fewer parents than parent criterias, or the given tag does not
    -- satisfy the given criteria, we can stop.
    in if not $ satisfiesSingle (last nonseps) tag || length parents < length nonseps - 1
        then False
        else if length sels == 1
            then True
            -- We only get here if sels has an odd length, length sels > 1 
            else ps parents $ init sels

-- Apply function on elements matching the selector.
alter :: T.Text -> Tag -> (Tag -> Tag) -> Tag
alter sel t f =
    let sels = parseSelector t
        selsGrouped = (Spl.split . Spl.oneOf) [Descendant, DirectChild] sels
        alterRec :: Tag -> [Tag] -> Tag
        alterRec tag parents = case tag of
            Doctype t       -> appif tag
            Text t          -> appif tag
            Tag n a c       -> appif $ Tag n a $ map (\x -> alterRec (parents ++ [tag]) x) c
            where
                appif t =
                    if satisfies parents tag selsGrouped
                        then f t
                        else t
    in alterRec t []

{--------------------------------------------------------------------
  Selectors.  
--------------------------------------------------------------------}

-- Selectors planned

-- Implemented      Example                     Description
--                  *                           - everything
-- Y                #X                          - id selector
-- Y                .X                          - class selector
--                  X Y                         - descendant selector
-- Y                X                           - type selector
--                  X > Y                       - direct child selector
-- Y                [attrName]                  - has attribute selector
-- Y                [attrName="val"]            - attribute name-value selector
-- Y                [attrName*="val"]           - regexp attribute selectors
-- Y                [attrName^="val"]  
-- Y                [attrName$="val"]  
--                  selector:not(selector)      - negation pseudoclass selector
--                  selector:nth-child(3)   
--                  selector:nth-last-child(3)  

data Regexy =
        StartsWith
    |   EndsWith
    |   Contains
    |   Equals
    |   Any
    deriving (Show)

data Selector =
        Type        T.Text
    |   Id          T.Text
    |   Class       T.Text
    |   Attribute   Regexy T.Text T.Text     -- Regex type, tag name, attrname, attrval
    -- These are more like relations between selectors and not selectors themselves, but hey.
    |   Descendant
    |   DirectChild
    deriving (Show)

{--------------------------------------------------------------------
  Parsering selectors.  
--------------------------------------------------------------------}

parseString :: P.Parser T.Text
parseString = do
    P.char '"'
    x <- P.many (P.noneOf "\"")
    P.char '"'
    return $ T.pack x

symbol :: P.Parser Char
symbol = P.oneOf "-"

parseNonquoted :: P.Parser T.Text
parseNonquoted = do
    first <- P.letter P.<|> symbol
    rest <- P.many (P.letter P.<|> P.digit P.<|> symbol)
    return $ T.pack $ first:rest

parseDescendant :: P.Parser Selector
parseDescendant = do
    P.space
    return Descendant

parseDirectChild :: P.Parser Selector
parseDirectChild = do
    P.many P.space
    P.char '>'
    P.many P.space
    return DirectChild

parseId :: P.Parser Selector
parseId = do
    P.char '#'
    id <- parseNonquoted
    return $ Id id

parseClass :: P.Parser Selector
parseClass = do
    P.char '.'
    clas <- parseNonquoted
    return $ Class clas

parseTyp :: P.Parser Selector
parseTyp = do
    typ <- parseNonquoted
    return $ Type typ

parseAttr :: P.Parser Selector
parseAttr = do
    P.char '['
    attrName <- parseNonquoted
    mode <- P.many $ P.string "*=" P.<|> P.string "^=" P.<|> P.string "$=" P.<|> P.string "="
    val <- P.many $ parseNonquoted P.<|> parseString
    P.char ']'
    return $ case mode of
        []          -> Attribute Any        attrName    ""
        ["*="]      -> Attribute Contains   attrName    (val!!0)
        ["^="]      -> Attribute StartsWith attrName    (val!!0)
        ["$="]      -> Attribute EndsWith   attrName    (val!!0)
        ["="]       -> Attribute Equals     attrName    (f val)
    where
        f :: [T.Text] -> T.Text
        f x = if length x == 0
            then ""
            else x!!0

parseExpr :: P.Parser [Selector]
parseExpr = P.many1 $ P.try parseId
    P.<|> P.try parseClass
    P.<|> P.try parseAttr
    P.<|> P.try parseTyp
    P.<|> P.try parseDirectChild
    P.<|> P.try parseDescendant

-- > P.parse parseExpr "selector" "#id"