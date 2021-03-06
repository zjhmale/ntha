{
module Ntha.Parser.Parser where

import Ntha.State
import Ntha.Core.Ast
import Ntha.Type.Type
import Ntha.Type.Refined (convertProg')
import Ntha.Parser.Lexer
import Control.Monad
import Data.List
import Data.IORef
import Data.Maybe (fromMaybe, fromJust)
import qualified Data.Map as M
import System.IO.Unsafe (unsafePerformIO)
}

%name expr
%tokentype { Token }
%error { parseError }

%token
    data     { DATA }
    match    { MATCH }
    begin    { BEGIN }
    type     { TYPE }
    defun    { DEFUN }
    lambda   { LAMBDA }
    monad    { MONAD }
    do       { DO }
    return   { RETURN }
    if       { IF }
    cond     { COND }
    else     { ELSE }
    rarrow   { RARROW }
    larrow   { LARROW }
    con      { CON $$ }
    '['      { LBRACKET }
    ']'      { RBRACKET }
    '('      { LPAREN }
    ')'      { RPAREN }
    '{'      { LBRACE }
    '}'      { RBRACE }
    '_'      { WILDCARD }
    '.'      { DOT }
    ':'      { COLON }
    '::'     { DOUBLECOLON }
    '|'      { BAR }
    let      { LET }
    import   { IMPORT }
    TNumber  { NUMBERT }
    TBool    { BOOLT }
    TChar    { CHART }
    TString  { STRT }
    product  { PRODUCT }
    keyword  { KEYWORD $$ }
    VAR      { VAR $$ }
    TVAR     { TVAR $$ }
    OPERATOR { OPERATOR $$ }
    number   { NUMBER $$ }
    boolean  { BOOLEAN $$ }
    string   { STRING $$ }
    char     { CHAR $$ }

%%

Program : Exprs                                            { EProgram $1 }

Exprs : Expr                                               { [$1] }
      | Expr Exprs                                         { $1 : $2 }

Expr : '(' defun VAR '[' Args ']' FormsPlus ')'            { EDestructLetBinding (IdPattern $3) $5 $7 }
     | '(' data con SimpleArgs VConstructors ')'
     { unsafePerformIO $ do
         (env, vars) <-
            foldM (\(env, vars) arg -> do
                      var <- makeVariable
                      return (M.insert arg var env, vars ++ [var]))
                    (M.empty, []) $4
         let dataType = TOper $3 vars
         let readEnv scope n = fromMaybe unitT $ M.lookup n scope
         let getType arg = case arg of
               EVCAVar aname -> readEnv env aname
               EVCAOper aname operArgs ->
                 TOper aname $ map (readEnv env) operArgs
               EVCAList arg' -> listT (getType arg')
               EVCATuple args -> productT (map getType args)
         let constructors' = map (\(EVConstructor cname cargs) ->
                                    let cargs' = map getType
                                                     cargs
                                    in TypeConstructor cname cargs')
                                 $5
         return $ EDataDecl $3 dataType vars constructors' }

     | '(' let Pattern FormsPlus ')'                       { EDestructLetBinding $3 [] $4 }
     | '(' type con VConArg ')'                            { unsafePerformIO $ do
                                                              $4 `seq` modifyIORef aliasMap $ M.insert $3 $4
                                                              return EUnit }
     | '(' monad con Form ')'                              { unsafePerformIO $ do
                                                              $4 `seq` modifyIORef monadMap $ M.insert $3 $4
                                                              return $ EDestructLetBinding (IdPattern $3) [] [$4] }
     | '(' VAR ':' Type ')'                                { ETypeSig $2 $4 }
     | '(' import VAR ')'                                  { EImport (getPathStr $3) }
     | Form                                                { $1 }

-- TODO should support arg parameter such as (Maybe N      umber)
SimpleArgs : {- empty -}                                   { [] }
           | VAR SimpleArgs                                { $1 : $2 }

VConArg : VAR                                              { EVCAVar $1 }
        | con                                              { unsafePerformIO $ do
                                                              alias <- readIORef aliasMap
                                                              case M.lookup $1 alias of
                                                                Just vconarg -> return vconarg
                                                                Nothing -> if $1 == "String"
                                                                     -- special case for String pattern
                                                                     then return $ EVCAList (EVCAOper "Char" [])
                                                                     else return $ EVCAOper $1 [] }
        | '(' con SimpleArgs ')'                           { EVCAOper $2 $3 }
        -- TODO more specs here
        | '[' VConArg ']'                                  { EVCAList $2 }
        | '(' TupleVConArgs ')'                            { EVCATuple $2 }

TupleVConArgs : VConArg '.' VConArg                        { [$1, $3] }
              | TupleVConArgs '.' VConArg                  { $1 ++ [$3] }

VConArgs : VConArg                                         { [$1] }
         | VConArg VConArgs                                { $1 : $2 }

VConstructor : con                                         { EVConstructor $1 [] }
             | '(' con VConArgs ')'                        { EVConstructor $2 $3 }
             | '(' VConArg keyword VConArg ')'             { EVConstructor $3 [$2, $4] }

VConstructors : VConstructor                               { [$1] }
              | VConstructor VConstructors                 { $1 : $2 }

Args : {- empty -}                                         { [] }
     | Pattern Args                                        { $1 : $2 }

Nameds : {- empty -}                                       { [] }
       | VAR Nameds                                        { (Named $1 Nothing) : $2 }
       | '(' VAR ':' Type ')' Nameds                       { (Named $2 (Just $4)) : $6 }

binding : Pattern Form                                     { ELetBinding $1 $2 [] }

bindings : binding                                         { [$1] }
         | binding bindings                                { $1 : $2 }

bind : Form                                                { Single $1 }
     | '(' return Form ')'                                 { Return $3 }
     | '(' VAR larrow Form ')'                             { Bind $2 $4 }

binds : bind                                               { [$1] }
      | bind binds                                         { $1 : $2 }

Clause : '(' else rarrow Form ')'                          { Else $4 }
       | '(' Form rarrow Form ')'                          { Clause $2 $4 }

Clauses : Clause                                           { [$1] }
        | Clause Clauses                                   { $1 : $2 }

Form : '(' match Form Cases ')'                            { EPatternMatching $3 $4 }
     | '(' lambda Nameds rarrow FormsPlus ')'              { ELambda $3 Nothing $5 }
     | '(' lambda Nameds ':' AtomType rarrow FormsPlus ')' { ELambda $3 (Just $5) $7 }
     | '(' let '[' bindings ']' FormsPlus ')'              { head $ foldr (\(ELetBinding pat def _) body ->
                                                                            [ELetBinding pat def body]) $6 $4 }
     | '(' if Form Form Form ')'                           { EIf $3 [$4] [$5] }
     | '(' cond Clauses ')'                                { case last $3 of
                                                               Else alt -> foldr (\(Clause cond consequent) alternative ->
                                                                                   EIf cond [consequent] [alternative])
                                                                                 alt
                                                                                 (init $3)
                                                               _ -> error "last clause in cond should be an else" }
     -- do block desuger to nested >>= and return, inspired by http://www.haskellforall.com/2014/10/how-to-desugar-haskell-code.html
     | '(' do con binds ')'
     { unsafePerformIO $ do
         monads <- readIORef monadMap
         return $
           case M.lookup $3 monads of
             Just (ERecord pairs) ->
               case M.lookup "return" pairs of
                 Just rtn ->
                   case M.lookup ">>=" pairs of
                     Just bind ->
                       foldr (\b next ->
                                case next of
                                  EUnit ->
                                    case b of
                                      Bind n e -> error "illegal do expression"
                                      Return e -> EApp newRtn e
                                      Single e -> e
                                  _ ->
                                    case b of
                                      Bind n e -> EApp (EApp newBind e)
                                                       (ELambda [Named n Nothing] Nothing [next])
                                      Return e -> EApp newRtn e
                                      Single e -> e)
                             EUnit
                             $4
                       where newBind = aliasArgName bind
                             newRtn = aliasArgName rtn
                     Nothing -> error $ "bind function is not defined for " ++ $3 ++ " monad"
                 Nothing -> error $ "return function is not defined for " ++ $3 ++ " monad"
             _ -> error $ $3 ++ " monad is not defined" }

     | '(' ListForms ')'                                   { $2 }
     | '(' TupleFroms ')'                                  { ETuple $2 }
     | '(' Form FormsPlus ')'                              { foldl (\oper param -> (EApp oper param)) $2 $3 }
     | '(' Form keyword Form ')'                           { foldl (\oper param -> (EApp oper param))
                                                                   (EVar $3)
                                                                   [$2, $4] }
     | '(' OPERATOR FormsPlus ')'                          { case $3 of
                                                               a:[] -> EApp (EVar $2) a
                                                               a:b:[] -> EApp (EApp (EVar $2) a) b
                                                               a:b:xs -> foldl (\oper param ->
                                                                                 (EApp (EApp (EVar $2) oper) param))
                                                                               (EApp (EApp (EVar $2) a) b)
                                                                               xs }
     | '[' FormsStar ']'                                   { EList $2 }
     | '{' RecordForms '}'                                 { ERecord $2 }
     | '(' keyword Form ')'                                { EAccessor $3 $2 }
     | '(' begin Exprs ')'                                 { EProgram $3 }
     | Atom                                                { $1 }

RecordForms : keyword Form                                 { M.singleton $1 $2 }
            | RecordForms keyword Form                     { M.insert $2 $3 $1 }

ListForms : Form '::' Form                                 { EApp (EApp (EVar "Cons") $1) $3 }
          | Form '::' ListForms                            { EApp (EApp (EVar "Cons") $1) $3 }

TupleFroms : Form '.' Form                                 { [$1, $3] }
           | TupleFroms '.' Form                           { $1 ++ [$3] }

FormsPlus : Form                                           { [$1] }
          | Form FormsPlus                                 { $1 : $2 }

FormsStar : {- empty -}                                    { [] }
          | Form FormsStar                                 { $1 : $2 }

Pattern : '_'                                              { WildcardPattern }
        | VAR                                              { IdPattern $1 }
        | number                                           { NumPattern $1 }
        | boolean                                          { BoolPattern $1 }
        | char                                             { CharPattern $1 }
        | string                                           { foldr (\p t -> TConPattern "Cons" [p, t])
                                                                   (TConPattern "Nil" [])
                                                                   (map CharPattern $1) }
        | con                                              { TConPattern $1 [] }
        | '(' con Args ')'                                 { TConPattern $2 $3 }
        -- e.g. (t1 :~> t2)
        | '(' Pattern keyword Pattern ')'                  { TConPattern $3 [$2, $4] }
        | '(' TuplePatterns ')'                            { TuplePattern $2 }
        | '[' ']'                                          { TConPattern "Nil" [] }
        | '[' Patterns ']'                                 { foldr (\p t -> TConPattern "Cons" [p, t])
                                                                   (TConPattern "Nil" []) $2 }
        | ListPatterns                                     { $1 }
        | '(' ListDestructPats ')'                         { $2 }

Patterns : Pattern                                         { [$1] }
         | Pattern Patterns                                { $1 : $2 }

TuplePatterns : Pattern '.' Pattern                        { [$1, $3] }
              | TuplePatterns '.' Pattern                  { $1 ++ [$3] }

ListPatterns : Pattern '::' Pattern                        { TConPattern "Cons" [$1, $3] }
             | Pattern '::' ListPatterns                   { TConPattern "Cons" [$1, $3] }

ListDestructPats : Pattern '::' Pattern                    { TConPattern "Cons" [$1
                                                                              , TConPattern "Cons" [$3, TConPattern "Nil" []]] }
                 | Pattern '::' ListDestructPats           { TConPattern "Cons" [$1, $3] }

Case : '(' Pattern rarrow FormsPlus ')'                    { Case $2 $4 }

Cases : Case                                               { [$1] }
      | Case Cases                                         { $1 : $2 }

Atom : boolean                                             { EBool $1 }
     | number                                              { ENum $1 }
     | string                                              { EStr $1 }
     | char                                                { EChar $1 }
     | VAR                                                 { EVar $1 }
     | OPERATOR                                            { EVar $1 }
     | con                                                 { EVar $1 }

-- parsing type

Type : AtomType                                            { $1 }
     | AtomType rarrow Type                                { arrowT $1 $3 }

-- TODO support type alias in type signature
AtomType : TVAR                                            { fromJust $ M.lookup $1 tvarMap }
         | TNumber                                         { intT }
         | TBool                                           { boolT }
         | TChar                                           { charT }
         | TString                                         { strT }
         | con Types                                       { TOper $1 $2 }
         | '[' Type ']'                                    { listT $2 }
         | '(' TupleTypes ')'                              { productT $2 }
         | '(' Type ')'                                    { $2 }
         | RefinedType                                     { $1 }

RefinedType : '(' VAR ':' Type '|' Form ')'                { TRefined $2 $4 (convertProg' $6) }

Types : {- empty -}                                        { [] }
      | Type Types                                         { $1 : $2 }

TupleTypes : Type product Type                             { [$1, $3] }
           | TupleTypes product Type                       { $1 ++ [$3] }

{
aliasMap :: IORef (M.Map String EVConArg)
aliasMap = createState M.empty

monadMap :: IORef (M.Map String Expr)
monadMap = createState M.empty

aliasArgName :: Expr -> Expr
aliasArgName expr@(ELambda nameds t exprs) = substName subrule expr
  where
  subrule = M.fromList $ foldl (\rule (Named name _) -> rule ++ [(name, name ++ "__monadarg__")]) [] nameds

{-# NOINLINE tvarMap #-}
tvarMap :: M.Map Char Type
tvarMap = unsafePerformIO $ do
  foldM (\m greek -> do
          tvar <- makeVariable
          return $ M.insert greek tvar m)
        M.empty ['α'..'ω']

getPathStr :: EPath -> EPath
getPathStr s = (map f s) ++ ".ntha"
  where f '.' = '/'
        f c = c

parseError :: [Token] -> a
parseError _ = error "Parse error"

parseExpr :: String -> Expr
parseExpr = expr . scanTokens
}