{
module Parser where

import Ast
import Lexer
}

%name expr
%tokentype { Token }
%error { parseError }

%token
    data     { DATA }
    match    { MATCH }
    defun    { DEFUN }
    lambda   { LAMBDA }
    arrow    { ARROW }
    con      { CON $$ }
    '['      { LBRACKET }
    ']'      { RBRACKET }
    '('      { LPAREN }
    ')'      { RPAREN }
    '<'      { LANGLEBRACKET }
    '>'      { RANGLEBRACKET }
    '_'      { WILDCARD }
    '::'     { DOUBLECOLON }
    let      { LET }
    VAR      { VAR $$ }
    OPERATOR { OPERATOR $$ }
    number   { NUMBER $$ }
    boolean  { BOOLEAN $$ }
    string   { STRING $$ }
    char     { CHAR $$ }

%%

Program : Exprs                                    { EProgram $1 }

Exprs : Expr                                       { [$1] }
      | Expr Exprs                                 { $1 : $2 }

Expr : '(' defun VAR '[' Args ']' FormsPlus ')'    { EDestructLetBinding (IdPattern $3) $5 $7 }
     | '(' data con SimpleArgs VConstructors ')'   { mkDataDeclExpr (ETConstructor $3 $4 $5) }
     | '(' let VAR FormsPlus ')'                   { EDestructLetBinding (IdPattern $3) [] $4 }
     | Form                                        { $1 }

SimpleArgs : {- empty -}                           { [] }
           | VAR SimpleArgs                        { $1 : $2 }

VConArg : VAR                                      { EVCAVar $1 }
        | '(' con SimpleArgs ')'                   { EVCAOper $2 $3 }

VConArgs : VConArg                                 { [$1] }
         | VConArg VConArgs                        { $1 : $2 }

VConstructor : con                                 { EVConstructor $1 [] }
             | '(' con VConArgs ')'                { EVConstructor $2 $3 }

VConstructors : VConstructor                       { [$1] }
              | VConstructor VConstructors         { $1 : $2 }

Args : {- empty -}                                 { [] }
     | VAR Args                                    { (IdPattern $1) : $2 }

Nameds : {- empty -}                               { [] }
       | VAR Nameds                                { (Named $1 Nothing) : $2 }

binding : VAR Form                                 { ELetBinding (IdPattern $1) $2 [] }

bindings : binding                                 { [$1] }
         | binding bindings                        { $1 : $2 }

Form : '(' match VAR Cases ')'                     { EPatternMatching (EVar $3) $4 }
     | '(' lambda Nameds arrow FormsPlus ')'       { ELambda $3 Nothing $5 }
     | '(' let '[' bindings ']' FormsPlus ')'      { mkNestedLetBindings (ENestLetBinding $4 $6) }
     | '(' Form FormsPlus ')'                      { mkNestedApplication (ENestApplication $2 $3) }
     | '[' FormsStar ']'                           { EList $2 }
     | '<' FormsStar '>'                           { ETuple $2 }
     | Atom                                        { $1 }

FormsPlus : Form                                   { [$1] }
          | Form FormsPlus                         { $1 : $2 }

FormsStar : {- empty -}                            { [] }
          | Form FormsStar                         { $1 : $2 }

Pattern : '_'                                      { WildcardPattern }
        | VAR                                      { IdPattern $1 }
        | number                                   { NumPattern $1 }
        | boolean                                  { BoolPattern $1 }
        | char                                     { CharPattern $1 }
        | string                                   { StrPattern $1 }
        | con Args                                 { TConPattern $1 $2 }
        | '<' Patterns '>'                         { TuplePattern $2 }
        | '[' ']'                                  { TConPattern "Nil" [] }
        | '[' Patterns ']'                         { foldr (\p t -> TConPattern "Cons" [p, t]) (TConPattern "Nil" []) $2 }
        | ListPatterns                             { $1 }

Patterns : Pattern                                 { [$1] }
         | Pattern Patterns                        { $1 : $2 }

ListPatterns : VAR '::' VAR                        { TConPattern "Cons" [IdPattern $1, IdPattern $3] }
             | VAR '::' ListPatterns               { TConPattern "Cons" [IdPattern $1, $3] }

Case : '(' Pattern arrow FormsPlus ')'             { Case $2 $4 }

Cases : Case                                       { [$1] }
      | Case Cases                                 { $1 : $2 }

Atom : boolean                                     { EBool $1 }
     | number                                      { ENum $1 }
     | string                                      { EStr $1 }
     | char                                        { EChar $1 }
     | VAR                                         { EVar $1 }
     | OPERATOR                                    { EVar $1 }
     | con                                         { EVar $1 }

{
parseError :: [Token] -> a
parseError _ = error "Parse error"

parseExpr :: String -> Expr
parseExpr = expr . scanTokens
}