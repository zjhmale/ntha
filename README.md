# Ntha Programming Language

[![Build Status](https://travis-ci.org/zjhmale/Ntha.svg?branch=master)](https://travis-ci.org/zjhmale/Ntha)
[![zjhmale](https://img.shields.io/badge/author-%40zjhmale-blue.svg)](https://github.com/zjhmale)
[![Haskell](https://img.shields.io/badge/language-haskell-red.svg)](https://en.wikipedia.org/wiki/Haskell_(programming_language))

a tiny statically typed functional programming language.

## Features

* Global type inference with optional type annotations.
* Lisp flavored syntax with Haskell like semantic inside.
* Support basic types: Integer, Character, String, Boolean, Tuple, List and Record.
* Support unicode keywords.
* Support destructuring.
* ADTs and pattern matching.
* Support pattern matching on function parameters.
* Lambdas and curried function by default.
* Global and Local let binding.
* Recursive functions.
* If-then-else control flow.
* Type alias.
* Do notation.

## Future Works

* Module system.
* error propagation (try / catch).
* JIT backend.
* Type-classes.
* Rank-N types.
* Dependent types.
* Fully type checked lisp like macros.
* TCO.

## Screenshots

![cleantha](./screenshots.gif)

## Example

```Clojure
(type Name String)
(type Env [(Name . Expr)])

(data Op Add Sub Mul Div Less Iff)

(data Expr
  (Num Number)
  (Bool Boolean)
  (Var Name)
  (If Expr Expr Expr)
  (Let [Char] Expr Expr)
  (Lambda Name Expr)
  (Closure Expr Env)
  (App Expr Expr)
  (Binop Op (Expr . Expr)))

(let op-map {:add +
             :sub -
             :mul *
             :div /
             :less <
             :iff =})

(ƒ arith-eval [fn (v1 . v2)]
  (Just (Num (fn v1 v2))))

(ƒ logic-eval [fn (v1 . v2)]
  (Just (Bool (fn v1 v2))))

(let eval-op
  (λ op v1 v2 ⇒
    (match (v1 . v2)
      (((Just (Num v1)) . (Just (Num v2))) ⇒
        (match op
          (Add ⇒ (arith-eval (:add op-map) (v1 . v2)))
          (Sub ⇒ (arith-eval (:sub op-map) (v1 . v2)))
          (Mul ⇒ (arith-eval (:mul op-map) (v1 . v2)))
          (Div ⇒ (arith-eval (:div op-map) (v1 . v2)))
          (Less ⇒ (logic-eval (:less op-map) (v1 . v2)))
          (Iff ⇒ (logic-eval (:iff op-map) (v1 . v2)))))
      (_ ⇒ Nothing))))

;; <fun> : [([Char] * Expr)] → (Expr → (Maybe Expr))
(ƒ eval [env expr]
  (match expr
    ((Num _) ⇒ (Just expr))
    ((Bool _) → (Just expr))
    ((Var x) ⇒ (do Maybe
                 (val ← (lookup x env))
                 (return val)))
    ((If cond then else) → (match (eval env cond)
                             ((Just (Bool true)) → (eval env then))
                             ((Just (Bool false)) → (eval env else))
                             (_ → (error "condition should be evaluate to a boolean value"))))
    ((Lambda _ _) → (Just (Closure expr env)))
    ((App fn arg) → (let [fnv (eval env fn)
                          argv (eval env arg)]
                      (match fnv
                        ((Just (Closure (Lambda x e) innerenv)) →
                            (do Maybe
                              (argv ← (eval env arg))
                              (eval ((x . argv) :: innerenv) e)))
                        (_ → (error "should apply arg to a function")))))
    ((Let x e1 in-e2) ⇒ (do Maybe
                          (v ← (eval env e1))
                          (eval ((x . v) :: env) in-e2)))
    ((Binop op (e1 . e2)) => (let [v1 (eval env e1)
                                   v2 (eval env e2)]
                               (eval-op op v1 v2)))))

(match (eval [] (Let "x" (Num 2) (Let "f" (Lambda "y" (Binop Mul ((Var "x") . (Var "y")))) (App (Var "f") (Num 3)))))
  ((Just (Num num)) ⇒ (print (int2str num)))
  (Nothing ⇒ (error "oops")))
```

## License

[![license BSD](https://img.shields.io/badge/license-BSD-orange.svg)](https://en.wikipedia.org/wiki/BSD_licenses)
