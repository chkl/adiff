-- MIT License
--
-- Copyright (c) 2018 Christian Klinger
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

module ADiff.ArithmeticExpressions where

import qualified Control.Applicative        as A
import           Control.Monad.Reader
import           Data.Text
import qualified Data.Text                  as T
import           Prelude
import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Expr

import qualified Data.Map                   as Map

type DollEnv = Map.Map Text Double

newtype ErrorMsg = ErrorMsg Text
  deriving (Show, Read, Eq, Ord)

instance ShowErrorComponent ErrorMsg  where
  showErrorComponent = show

type Parser a = ParsecT ErrorMsg Text (Reader DollEnv) a

sc :: Parser ()
sc = L.space space1 A.empty A.empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc


constant :: Parser Double
constant = lexeme $ try L.float <|> (fromIntegral <$> L.decimal)


parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

identifierString :: Parser String
identifierString = (:) <$> letterChar <*> many alphaNumChar

identifier :: Parser Text
identifier = T.pack <$> identifierString


evalExpr :: DollEnv -> Text -> Either String Double
evalExpr m inp = case runReader (runParserT expr "input" inp) m of
  Right n  -> Right n
  Left err -> Left (parseErrorPretty err)


expr :: Parser Double
expr = makeExprParser term table <?> "expression"

term = parens expr <|> try funCall <|> constant <|> variable <?> "term"

funCall = do
  n <- identifier
  space
  case n of
    "max" -> max <$> lexeme term <*> lexeme term
    "min" -> min <$> lexeme term <*> lexeme term
    _     -> fail "not a fun call"

table = [ [ prefix  "-"  negate , prefix  "+"  id ]
        , [ binary  "*"  ((*) :: Double -> Double -> Double) , binary  "/"  (/) ]
        , [ binary  "+"  (+) , binary  "-"  (-)  ]
        ]


variable :: Parser Double
variable = do
  name <- identifier
  asks (Map.lookup name) >>= \case
    Nothing -> fail $ "undefined variable: "  ++ show name ++ "'"
    Just val -> return val

binary  name f = InfixL  (f <$ symbol name)
prefix  name f = Prefix  (f <$ symbol name)
postfix name f = Postfix (f <$ symbol name)
