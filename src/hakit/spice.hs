{-# LANGUAGE OverloadedStrings #-}
module Hakit.Spice (
    -- * Tag creation
    tag,
    doctype,
    html,
    head',
    body,
    div',
    text,
    cat,
    -- * Nested tag functions
    alter,
    remove,
    select,
    -- * Single tag functions
    attrs,
    attr,
    children,
    name,
    -- * Manipulation
    addClass,
    removeClass,
    hasClass,
    toggleClass,
    -- * Types
    Attrs(), Tag(..), Child(..),
    -- * Exported for testing purposes only
    matches, parseSelector, example
) where

import qualified Data.Text as T
import qualified Data.List as L
import qualified Data.Map as M
import qualified Text.ParserCombinators.Parsec as P
import qualified Text.ParserCombinators.Parsec.Expr as E
import qualified Text.ParserCombinators.Parsec.Pos as Pos
import qualified Text.Parsec.Prim as Pr
import qualified Data.List.Split as Spl
import qualified Data.Functor.Identity as I

-- This package contains some questionable temporary names now to avoid clash with prelude.

{--------------------------------------------------------------------
  Types.  
--------------------------------------------------------------------}

-- For simplicity reasons, currently only attributes exist and no properties.
data Attrs = Attrs (M.Map T.Text T.Text) deriving (Eq)

toAttrs :: [(T.Text, T.Text)] -> Attrs
toAttrs l = Attrs $ M.fromList l

attrsToMap :: Attrs -> M.Map T.Text T.Text
attrsToMap (Attrs at) = at

type Child = Tag

data Tag =
        Doctype T.Text
    |   Text    T.Text  
    --          Name        Attributes  Children
    |   Tag     T.Text      Attrs       [Child]
    deriving (Eq)

-- | Create any tag.
tag n a c   = Tag n (toAttrs a) c

-- Some frequently used tags here
doctype a   = Doctype a
html a c    = tag "html" a c
head' a c   = tag "head" a c
body a c    = tag "body" a c
text t      = Text t
div' a c    = tag "div" a c

-- | Create attribute.
cat :: T.Text -> T.Text -> (T.Text, T.Text)
cat a b = (a, b)

example :: Tag
example =
    html [] [
        head' [] [],
        body [cat "style" "background: #ccc;"] [
            text "Hello world.",
            div' [cat "class" "just-a-div"] [],
            div' [] [
                text "Hello again."
            ]
        ]
    ]

{--------------------------------------------------------------------
  Rendering.  
--------------------------------------------------------------------}

voidElements :: M.Map T.Text ()
voidElements = M.fromList $ map (\x -> (x, ()))
    ["area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "menuitem", "meta", "param", "source", "track", "wbr"]

instance Show Attrs where
    show (Attrs at) = L.intercalate " " $ map (\(a, b) -> T.unpack a ++ "=" ++ show b) $ M.toList at

-- Show attributes
sa :: Attrs -> String
sa a@(Attrs at) = if M.size at > 0
        then " " ++ show a
        else ""

-- Show children.
sc :: [Child] -> String
sc x = L.intercalate "" $ map (\y -> tabLines $ show y) x
    where tabLines x = unlines $ map (\y -> "    " ++ y) $ lines x

instance Show Tag where
    show (Doctype a)    = "<!DOCTYPE " ++ T.unpack a ++ ">"
    show (Tag n a c)    = case M.lookup n voidElements of
        Just ()     -> "<" ++ T.unpack n ++ sa a ++ "/>"
        Nothing     -> if length c > 0
            then "<" ++ T.unpack n ++ sa a ++ ">\n" ++ sc c ++ "</" ++ T.unpack n ++ ">"
            else "<" ++ T.unpack n ++ sa a ++ "></" ++ T.unpack n ++ ">"
    show (Text a)       = T.unpack a

{--------------------------------------------------------------------
  Single tag functions.  
--------------------------------------------------------------------}

attrs :: Tag ->      Attrs
attrs (Doctype t)    = toAttrs []
attrs (Text t)       = toAttrs []
attrs (Tag _ a _)    = a

attr :: T.Text -> Tag -> Maybe T.Text
attr attrName tag = case M.lookup attrName $ attrsToMap $ attrs tag of
    Just v      -> Just v
    Nothing     -> Nothing

setAttr :: T.Text -> T.Text -> Tag -> Tag
setAttr key val tag = case tag of
    Doctype t           -> tag
    Text t              -> tag
    Tag n (Attrs a) c   -> Tag n (Attrs $ M.insert key val a) c

children :: Tag ->       [Child]
children (Doctype t)     = []
children (Text t)        = []
children (Tag _ _ c)     = c

name :: Tag ->      T.Text
name (Doctype t)    = "doctype"
name (Text t)       = "text"
name (Tag n _ _)    = n

{--------------------------------------------------------------------
  Manipulation.  
--------------------------------------------------------------------}

addClass :: T.Text -> Tag -> Tag
addClass clas tag = case attr "class" tag of
    Nothing     -> setAttr "class" clas tag
    Just c      -> let spl = T.splitOn " " c in if elem clas spl
        then tag
        else setAttr "class" (T.intercalate " " $ clas:spl) tag

hasClass :: T.Text -> Tag -> Bool
hasClass clas tag = case attr "class" tag of
    Nothing     -> False
    Just c      -> let spl = T.splitOn " " c in elem clas spl

removeClass :: T.Text -> Tag -> Tag
removeClass clas tag = case attr "class" tag of
    Nothing     -> tag
    Just c      -> let spl = T.splitOn " " c in if elem clas spl
        then setAttr "class" (T.intercalate " " $ filter (/= clas) spl) tag
        else tag

toggleClass :: T.Text -> Tag -> Tag
toggleClass clas tag = case attr "class" tag of
    Nothing     -> setAttr "class" clas tag
    Just c      -> let spl = T.splitOn " " c in if elem clas spl
        then setAttr "class" (T.intercalate " " $ filter (/= clas) spl) tag
        else setAttr "class" (T.intercalate " " $ clas:spl) tag


{--------------------------------------------------------------------
  Selector implementation.  
--------------------------------------------------------------------}

-- | Just for quick and ugly testing.
-- Tests if a (top level) tag satisfies a given selector
matches :: T.Text -> Tag -> Bool
matches sel tag = matches' [] (parseSelector sel) tag

-- Returns true of the tag or its descendants match the selector.
has :: Selector -> Tag -> Bool
has sel t = if matches' [] sel t
    then True
    else any (has sel) $ children t

calcRoot :: [Tag] -> Tag -> Tag
calcRoot parents tag = if length parents == 0
    then tag
    else parents!!0

filtIndex :: (Int -> Bool) -> [a] -> [a]
filtIndex pred xs =
    let indexes = [0 ..(length xs) - 1]
        iterable = zip indexes xs
    in map (\(_, b) -> b) $ filter (\(a, _) -> pred a) iterable

-- Returns following siblings of a tag
siblings :: Tag -> Tag -> [Tag]
siblings parent tag =
    let pch = children parent
    in if length pch == 0
        then []
        else let pos = L.findIndex (== tag) pch in case pos of
            Just p  -> snd $ L.splitAt (p + 1) pch
            Nothing -> []

-- Returns true if given tag matches the selector provided.
matches' :: [Tag] -> Selector -> Tag -> Bool
matches' parents s tag = case s of
    Type t  -> name tag == t
    Id  id  -> case attr "id" tag of
        Just x  -> x == id
        Nothing -> False
    Class c -> hasClass c tag
    Attribute reg attrName attrVal -> case attr attrName tag of
        Nothing -> False
        Just x  -> case reg of
            StartsWith  -> T.isPrefixOf attrVal x
            EndsWith    -> T.isSuffixOf attrVal x
            Contains    -> T.isInfixOf attrVal x
            Equals      -> x == attrVal
            Anything    -> True
    And selectors   -> all (\x -> matches' parents x tag) selectors
    Or selectors    -> any (\x -> matches' parents x tag) selectors
    Not selector    -> not $ matches' parents selector tag
    Has selector    -> any (has selector) $ children tag
    AncestorIs sel  -> if length parents == 0
        then False
        else let parinits = zip (L.inits parents) parents in
            any (\(pars, subj) -> matches' pars sel subj) parinits   
    ParentIs sel    -> if length parents == 0
        then False
        else matches' (init parents) sel $ last parents
    FirstChild      -> if length parents == 0
        then False
        else let ch = children $ last parents in if length ch == 0
            then False
            else head ch == tag
    LastChild       ->
        let pc = children $ last parents
        in if length parents == 0 || length pc == 1 -- A children can not be the first and last too at the same time.
            then False
            else last pc == tag
    Eq selector n   ->
        let root = calcRoot parents tag
            tm = take (n+1) $ select' selector root
        in if length tm <= n
            then False
            else (tm!!n) == tag
    -- Revisit this.
    LesserThan s n  ->
        let root = calcRoot parents tag
            tm = take n $ select' s root
        in any (== tag) tm
    GreaterThan s n ->
        let root = calcRoot parents tag
            tm = drop (n + 1) $ select' s root
        in any (== tag) tm
    First selector  ->
        let root = calcRoot parents tag
            tm = take 1 $ select' selector root
        in any (== tag) tm
    Last selector   ->
        let root = calcRoot parents tag
            tm = select' selector root
        in if length tm == 0
            then False
            else last tm == tag
    Even selector   ->
        let root = calcRoot parents tag
            tm = filtIndex (\x -> x `mod` 2 == 0) $ select' selector root
        in any (== tag) tm
    Odd selector    ->
        let root = calcRoot parents tag
            tm = filtIndex (\x -> x `mod` 2 == 1) $ select' selector root
        in any (== tag) tm
    NthChild n      ->
        let pc = children $ last parents
        in if length parents == 0 || length pc < n   -- Note that this selector is 1-indexed.
            then False
            else (pc!!(n - 1)) == tag
    NthLastChild n  ->
        let pc = children $ last parents
        in if length parents == 0 || length pc < n
            then False
            else (pc!!(length pc - n - 1)) == tag 
    Empty           -> length (children tag) == 0
    Parent          -> length (children tag) /= 0
    NextAdj s       -> if length parents == 0
        then False
        else let sibs = take 1 $ siblings (last parents) tag
            in if length sibs > 0
                then matches' parents s (sibs!!0)
                else False
    NextSibl s      -> if length parents == 0
        then False
        else let sibs = siblings (last parents) tag
            in if length sibs > 0
                then any (matches' parents s) sibs
                else False
    Any             -> True
    -- 
    Descendant      -> error "matches': bug: Descendant"
    DirectChild     -> error "matches': bug: DirectChild"
    Placeholder     -> error "matches': bug: Placeholder"
    Comma           -> error "matches': bug: Comma"
    otherwise       -> error $ "matches': bug: " ++ show s

{--------------------------------------------------------------------
  Nested tag functions.  
--------------------------------------------------------------------}

-- | Apply function on elements matching the selector.
alter :: T.Text -> Tag -> (Tag -> Tag) -> Tag
alter sel t f =
    let sels = parseSelector sel
        alterRec :: [Tag] -> Tag -> Tag
        alterRec parents tag = case tag of
            Doctype t       -> appif tag
            Text t          -> appif tag
            Tag n a c       -> appif $ Tag n a $ map (alterRec $ parents ++ [tag]) c
            where
                appif t =
                    if matches' parents sels tag
                        then f t
                        else t
    in alterRec [] t

-- | Remove tags matching the selector.
-- Does not remove the provided tag itself.
remove :: T.Text -> Tag -> Tag
remove sel t =
    let sels = parseSelector sel
        removeRec :: [Tag] -> Tag -> Tag
        removeRec parents tag = case tag of
            Tag n a c   -> Tag n a $ filter (matches' parents sels) $ map (removeRec $ parents ++ [tag]) c
            otherwise   -> tag
    in removeRec [] t

-- | Returns tags matching the selector.
-- Obiously not too useful if you want to alter the given elements, because
-- of Haskell's purity. See alter and remove instead.
select :: T.Text -> Tag -> [Tag]
select sel t = let sels = parseSelector sel in select' sels t

select' :: Selector -> Tag -> [Tag]
select' sel t = 
    let selectRec :: [Tag] -> Tag -> [Tag]
        selectRec parents tag = case tag of
            Doctype t   -> retif tag
            Text t      -> retif tag
            Tag n a c   -> retif tag ++ (concat $ map (selectRec $ parents ++ [tag]) c)
            where
                retif t =
                    if matches' parents sel tag
                        then [t]
                        else []
    in selectRec [] t

{--------------------------------------------------------------------
  Selectors.  
--------------------------------------------------------------------}

-- Selectors planned.

-- Implemented      Example                     Name
-- Y                *                           - All selector
-- Y                #id                         - Id selector
-- Y                .class                      - Class selector
-- Y                selector1 selector2         - Descendant selector
-- Y                type                        - Type selector
-- Y                selector1 > selector2       - Direct child selector
-- Y                [attrName]                  - Has attribute selector
-- Y                [attrName="val"]            - Attribute equals selector
-- Y                [attrName*="val"]           - Attribute contains selector
-- Y                [attrName^="val"]           - Attribute starts with selector
-- Y                [attrName$="val"]           - Attribute ends with selector
-- Y                [attrName~="val"]           - Attribute contains word selector
-- Y                [attrName!="val"]           - Attribute not equals selector
-- Y                selector1, selector2        - Multiple selectors selector
-- Y                :not(selector)              - :not() selector
-- Y                :has(selector)              - :has() selector
-- Y                :eq(3)                      - :eq() selector
-- Y                :lt(3)                      - :lt() selector
-- Y                :gt(3)                      - :gt() selector
-- Y                :even                       - :even selector
-- Y                :odd                        - :odd selector
-- Y                :first                      - :first selector
-- Y                :last                       - :last selector
-- Y                :first-child                - :first-child selector
-- Y                :last-child                 - :last-child selector
-- Y                :nth-child(3)               - :nth-child() selector
-- Y                :nth-last-child(3)          - :nth-last-child() selector
-- Y                :empty                      - :empty selector
-- Y                :parent                     - :parent selector

data Regexy =
        StartsWith
    |   EndsWith
    |   Contains
    |   Equals
    |   Anything
    |   ContainsWord
    |   NotEquals
    deriving (Eq, Show)

data Selector =
        Any
    |   Type        T.Text
    |   Id          T.Text
    |   Class       T.Text
    |   Eq Selector Int | Even Selector | Odd Selector
    |   LesserThan Selector Int | GreaterThan Selector Int
    |   First Selector | Last Selector
    |   Parent | Empty
    |   FirstChild | LastChild | NthChild Int | NthLastChild Int
    -- Currently you can only apply flat selectors in an and.
    -- (eg: no descendant or direct child)
    |   And         [Selector]
    |   Or          [Selector]
    |   Not         Selector
    |   Has         Selector
    |   ParentIs    Selector
    |   AncestorIs  Selector
    |   Attribute   Regexy T.Text T.Text     -- Regex type, tag name, attrname, attrval
    |   NextAdj     Selector
    |   NextSibl    Selector
    -- Operators
    |   Comma
    |   Descendant
    |   DirectChild
    |   IndSep
    |   AndSep
    |   Plus
    |   Tilde
    -- Placeholder
    |   Placeholder
    deriving (Eq, Show)

{--------------------------------------------------------------------
  Parsing selectors.  
--------------------------------------------------------------------}

l :: a -> [a]
l x = [x]

setCrit x v = case x of
    Eq s  i             -> Eq v i
    LesserThan s i      -> LesserThan v i
    GreaterThan s i     -> GreaterThan v i
    Even s              -> Even v
    Odd s               -> Odd v
    First s             -> First v
    Last s              -> Last v
    otherwise           -> error $ "bug: can't set crit of " ++ show x

isInd x = case x of
    Eq _  _             -> True
    Even _              -> True
    Odd _               -> True
    First _             -> True
    Last _              -> True
    LesserThan _ _      -> True
    GreaterThan _ _     -> True
    otherwise           -> False

isOp :: Selector -> Bool
isOp s = case s of
    Comma       -> True
    Descendant  -> True
    DirectChild -> True
    IndSep      -> True
    AndSep      -> True
    Plus        -> True
    Tilde       -> True
    otherwise   -> False

-- Inserts e between every two elements of a list if both satisfies the predicate.
lace :: (a -> a -> Bool) -> a -> [a] -> [a]
lace pred e l
    | length l < 2      = l
    | otherwise         = if pred (l!!0) (l!!1)
        then (l!!0):e:(lace pred e $ tail l)
        else (l!!0):(lace pred e $ tail l)

simple s = (not $ isInd s) && (not $ isOp s)

-- Returns if a separator will not itself create an And.
-- (see operatorTable for And construtors)
notAndy s = case s of
    DirectChild -> False
    Descendant  -> False
    Plus        -> False
    Tilde       -> False
    otherwise   -> True

-- This is ugly.
laceAnd :: [Selector] -> [Selector]
laceAnd ss = lace f AndSep ss 
    where
    f a b   | notAndy a && not (isOp a) && simple b     = True
            | otherwise                                 = False

operatorTable ::[[E.Operator Selector () Selector]]
operatorTable = [
        [
            binary (== AndSep) (\a b -> And [a, b]) E.AssocLeft,
            binary (== IndSep) (\a b -> setCrit b a) E.AssocLeft
        ],
        [
            binary (== Tilde) (\a b -> And [a, NextSibl b]) E.AssocLeft,
            binary (== Plus) (\a b -> And [a, NextAdj b]) E.AssocLeft,
            binary (== Descendant) (\a b -> And [b, AncestorIs a]) E.AssocLeft,
            binary (== DirectChild) (\a b -> And [b, ParentIs a]) E.AssocLeft
        ],
        [binary (== Comma) (\a b -> Or [a, b]) E.AssocRight]
    ]

nextPos pos x xs  = Pos.incSourceColumn pos 1

predM :: (a -> Bool) -> (a -> Maybe a)
predM x = \y -> if x y
    then Just y
    else Nothing

binary pred fun assoc = E.Infix (do
    P.try $ Pr.tokenPrim show nextPos $ predM pred
    return fun)
    assoc

parseSelector :: T.Text -> Selector
parseSelector t =
    let errMsg = "parseSelector: can't parse selector: " ++ show t
        sels = P.parse parseExpr errMsg $ T.unpack t
    in case sels of
        Left e      -> error $ show e
        Right ss    -> parseSelPrec $ concat ss

term :: Pr.ParsecT [Selector] () I.Identity Selector
term = do
    x <- P.anyToken
    return x

parseSelPrec :: [Selector] -> Selector
parseSelPrec ss =
    let errMsg = "parseSelector: can't parse expression: " ++ show ss
        prec = E.buildExpressionParser operatorTable term P.<?> "expression"
        laced = laceAnd ss
        sels = P.parse prec errMsg laced
    in case sels of
        Left e      -> error $ show e
        Right sel     -> sel

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

parseDescendant :: P.Parser [Selector]
parseDescendant = do
    P.space
    return $ l Descendant

parseId :: P.Parser [Selector]
parseId = do
    P.char '#'
    id <- parseNonquoted
    return $ l $ Id id

parseClass :: P.Parser [Selector]
parseClass = do
    P.char '.'
    clas <- parseNonquoted
    return $ l $ Class clas

parseTyp :: P.Parser [Selector]
parseTyp = do
    typ <- parseNonquoted
    return $ l $ Type typ

ts x = P.try $ P.string x

parseCons :: P.Parser [Selector]
parseCons = do
    c <- P.char '*' P.<|> P.char ':'
    case c of
        '*'     -> return $ l Any
        ':'     -> do
            cons <- ts "empty" P.<|> P.string "parent"
                P.<|> ts "first-child" P.<|> ts "last-child"
                P.<|> P.string "first" P.<|> P.string "last"
                P.<|> P.string "even" P.<|> P.string "odd"
            return $ case cons of
                "parent"        -> [Parent]
                "empty"         -> [Empty]
                "last"          -> [IndSep, Last Placeholder]
                "first"         -> [IndSep, First Placeholder]
                "first-child"   -> [FirstChild]
                "last-child"    -> [LastChild]
                "even"          -> [IndSep, Even Placeholder]
                "odd"           -> [IndSep, Odd Placeholder]

parseNthChildEq :: P.Parser [Selector]
parseNthChildEq = do
    a <- ts ":nth-child(" P.<|> ts ":nth-last-child(" P.<|> ts ":eq("
        P.<|> ts ":lt(" P.<|> ts ":gt("
    num <- P.many1 P.digit
    P.char ')'
    return $ let n = (read num)::Int in case a of
        ":nth-child("       -> [NthChild     n]
        ":nth-last-child("  -> [NthLastChild n]
        ":eq("              -> [IndSep, Eq Placeholder n]
        ":lt("              -> [IndSep, LesserThan   Placeholder n]
        ":gt("              -> [IndSep, GreaterThan  Placeholder n]

parseNotHas :: P.Parser [Selector]
parseNotHas = do
    a <- ts ":not(" P.<|> ts ":has("
    sels <- parseExpr
    P.string ")"
    return $ l $ case a of
        ":not("     -> Not $ parseSelPrec $ concat sels
        ":has("     -> Has $ parseSelPrec $ concat sels

parseCommaDCSiblings :: P.Parser [Selector]
parseCommaDCSiblings = do
    P.many P.space
    v <- P.char ',' P.<|> P.char '~' P.<|> P.char '+' P.<|> P.char '>'
    P.many P.space
    return $ l $ case v of
        ','     -> Comma
        '~'     -> Tilde
        '+'     -> Plus
        '>'     -> DirectChild

parseAttr :: P.Parser [Selector]
parseAttr = do
    P.char '['
    attrName <- parseNonquoted
    mode <- P.many $ P.string "*=" P.<|> P.string "^="
        P.<|> P.string "$=" P.<|> P.string "="
        P.<|> P.string "~=" P.<|> P.string "!="
    val <- P.many $ parseNonquoted P.<|> parseString
    P.char ']'
    return $ l $ case mode of
        []          -> Attribute Anything       attrName    ""
        ["*="]      -> Attribute Contains       attrName    (val!!0)
        ["^="]      -> Attribute StartsWith     attrName    (val!!0)
        ["$="]      -> Attribute EndsWith       attrName    (val!!0)
        ["~="]      -> Attribute ContainsWord   attrName    (val!!0)
        ["!="]      -> Attribute NotEquals      attrName    (val!!0)
        ["="]       -> Attribute Equals         attrName    (f val)
    where
        f :: [T.Text] -> T.Text
        f x = if length x == 0
            then ""
            else x!!0

-- While try is not required everywhere,
-- they are there for simplicity and easier extendability.
parseExpr :: P.Parser [[Selector]]
parseExpr = P.many1 $ P.try parseId
    P.<|> P.try parseClass
    P.<|> P.try parseAttr
    P.<|> P.try parseTyp
    P.<|> P.try parseCommaDCSiblings
    P.<|> P.try parseDescendant
    P.<|> P.try parseCons
    P.<|> P.try parseNthChildEq
    P.<|> P.try parseNotHas

-- > P.parse parseExpr "selector" "#id"