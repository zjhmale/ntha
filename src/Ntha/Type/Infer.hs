module Ntha.Type.Infer where

import           Ntha.Core.Ast
import           Ntha.State
import           Ntha.Type.Type
import           Ntha.Type.TypeScope

import           Prelude             hiding (lookup)
import           Control.Monad       (foldM, forM_, when, zipWithM_)
import           Control.Monad.Loops (anyM)
import           Data.IORef
import qualified Data.Map            as M
import qualified Data.Set            as S

type NonGeneric = (S.Set Type)

occursInType :: Type -> Type -> Infer Bool
occursInType v t = do
  tP <- prune t
  case tP of
    TOper _ ts -> occursIn v ts
    v' -> return $ v == v'

occursIn :: Type -> [Type] -> Infer Bool
occursIn t = anyM (occursInType t)

isGeneric :: Type -> NonGeneric -> Infer Bool
isGeneric t nonGeneric = not <$> (occursIn t $ S.toList nonGeneric)

fresh :: Type -> NonGeneric -> Infer Type
fresh t nonGeneric = do
  mappings <- newIORef M.empty -- A mapping of TypeVariables to TypeVariables
  let freshrec ty = (\tyP -> case tyP of
                      TVar _ _ _ -> do
                        isG <- isGeneric tyP nonGeneric
                        if isG
                        then do
                          m <- readIORef mappings
                          case M.lookup tyP m of
                            Just tVar -> return tVar
                            Nothing -> do
                              newVar <- makeVariable
                              modifyIORef mappings $ M.insert tyP newVar
                              return newVar
                        else return tyP
                      TOper name types -> do
                        newTypes <- mapM freshrec types
                        return $ TOper name newTypes
                      TCon name types dataType -> do
                        newTypes <- mapM freshrec types
                        newDataType <- freshrec dataType
                        return $ TCon name newTypes newDataType
                      TRecord valueTypes -> do
                        newValueTypes <- foldM (\acc (k, v) -> do
                                                fv <- freshrec v
                                                return $ M.insert k fv acc)
                                               M.empty $ M.toList valueTypes
                        return $ TRecord newValueTypes
                      _ -> return tyP)
                    =<< prune ty
  freshrec t

getType :: TName -> TypeScope -> NonGeneric -> Infer Type
getType name scope nonGeneric = case lookup name scope of
  Just var -> fresh var nonGeneric
  Nothing -> error $ "Undefined symbol " ++ name

adjustType :: Type -> Type
adjustType t = case t of
  TCon _ types dataType -> functionT types dataType
  _ -> t

unify :: Type -> Type -> Infer ()
unify t1 t2 = do
  t1P <- prune t1
  t2P <- prune t2
  let t1PA = adjustType t1P
  let t2PA = adjustType t2P
  case (t1PA, t2PA) of
    (a@(TVar _ inst _), b) -> when (a /= b) $ do
      isOccurs <- occursInType a b
      when isOccurs $ error "Recusive unification"
      writeIORef inst $ Just b
    (a@(TOper _ _), b@(TVar _ _ _)) -> unify b a
    (a@(TOper name1 types1), b@(TOper name2 types2)) ->
      if name1 /= name2 || (length types1) /= (length types2)
      then error $ "Type mismatch " ++ show a ++ " ≠ " ++ show b
      else zipWithM_ unify types1 types2
    (a@(TRecord types1), b@(TRecord types2)) -> mapM_ (\(k, t2') -> do
        case M.lookup k types1 of
          Just t1' -> unify t2' t1'
          Nothing -> error $ "Cannot unify, no field " ++ k ++ " " ++ show a ++ ", " ++ show b)
      $ M.toList types2
    _ -> error $ "Can not unify " ++ show t1 ++ ", " ++ show t2

visitPattern :: Pattern -> TypeScope -> NonGeneric -> Infer (TypeScope, NonGeneric, Type)
visitPattern pattern scope nonGeneric = case pattern of
  WildcardPattern -> do
    resT <- makeVariable
    return (scope, nonGeneric, resT)
  IdPattern name -> do
    resT <- makeVariable
    return (insert name resT scope, S.insert resT nonGeneric, resT)
  NumPattern _ -> return (scope, nonGeneric, intT)
  BoolPattern _ -> return (scope, nonGeneric, boolT)
  CharPattern _ -> return (scope, nonGeneric, charT)
  TuplePattern items -> do
    (itemTypes, newScope, newNonGeneric) <- foldM (\(types, env, nonGen) item -> do
                                                    (newEnv, newNonGen, itemT) <- visitPattern item env nonGen
                                                    return (types ++ [itemT], newEnv, newNonGen))
                                                 ([], scope, nonGeneric) items
    return (newScope, newNonGeneric, productT itemTypes)
  TConPattern name patterns -> do
    (patTypes, newScope, newNonGeneric) <- foldM (\(types, env, nonGen) pat -> do
                                                    (newEnv, newNonGen, patT) <- visitPattern pat env nonGen
                                                    return (types ++ [patT], newEnv, newNonGen))
                                                ([], scope, nonGeneric) patterns
    case lookup name newScope of
      Nothing -> error $ "Unknow type constructor " ++ name
      Just tconT -> case tconT of
        TCon _ _ _ -> do
          (TCon _ types dataType) <- fresh tconT newNonGeneric
          if (length patterns) /= (length types)
          then error $ "Bad arity: case "
                       ++ show pattern
                       ++ " provided "
                       ++ (show . length) patterns
                       ++ " arguments whereas "
                       ++ name
                       ++ " takes "
                       ++ (show . length) types
          else do
            zipWithM_ unify patTypes types
            return (newScope, newNonGeneric, dataType)
        _ -> error $ "Invalid type constructor " ++ name

definePattern :: Pattern -> Type -> TypeScope -> Infer TypeScope
definePattern pattern t scope = do
  tP <- prune t
  case pattern of
    IdPattern name -> return $ insert name tP scope
    TuplePattern items -> case tP of
      TOper _ types -> do
        newScope <- foldM (\env (pat, patT) -> do
                            newEnv <- definePattern pat patT env
                            return newEnv)
                         scope $ zip items types
        return newScope
      _ -> error $ "Invalid type " ++ show tP ++ " for pattern " ++ show pattern
    TConPattern _ patterns -> case tP of
      -- t is always functionT for now so a little non-sense for this case.
      TCon _ types _ -> do
        newScope <- foldM (\env (pat, patT) -> do
                            newEnv <- definePattern pat patT env
                            return newEnv)
                         scope $ zip patterns types
        return newScope
      TOper _ types -> do
        newScope <- foldM (\env (pat, patT) -> do
                            newEnv <- definePattern pat patT env
                            return newEnv)
                         scope $ zip patterns types
        return newScope
      _ -> error $ "Invalid type " ++ show tP ++ " for pattern " ++ show pattern
    _ -> return scope

analyze :: Expr -> TypeScope -> NonGeneric -> Infer (TypeScope, Type)
analyze expr scope nonGeneric = case expr of
  ENum _ -> return (scope, intT)
  EBool _ -> return (scope, boolT)
  EChar _ -> return (scope, charT)
  EStr _ -> return (scope, strT)
  EUnit -> return (scope, unitT)
  EList exprs -> do
    valueT <- makeVariable
    -- type checking procedure, since types of elems in a list should be the same.
    forM_ exprs (\e -> do
                  (_, eT) <- analyze e scope nonGeneric
                  unify valueT eT)
    return (scope, listT valueT)
  ETuple exprs -> do
    types <- foldM (\types expr' -> do
                      (_, ty) <- analyze expr' scope nonGeneric
                      return $ types ++ [ty])
                   [] exprs
    return (scope, productT types)
  ERecord pairs -> do
    valueTypes <- foldM (\vts (k, v) -> do
                          (_, t) <- analyze v scope nonGeneric
                          return $ M.insert k t vts)
                       M.empty $ M.toList pairs
    return (scope, TRecord valueTypes)
  EVar name -> (scope,) <$> getType name scope nonGeneric
  EApp fn arg -> do
    (_, fnT) <- analyze fn scope nonGeneric
    (_, argT) <- analyze arg scope nonGeneric
    rtnT <- makeVariable
    unify (functionT [argT] rtnT) fnT
    return (scope, rtnT)
  ELambda params annoT instructions -> do
    let newScope = child scope
    (paramTypes, newScope', newNonGeneric) <-
      foldM (\(types', env', nonGeneric') (Named name t) ->
             case t of
               Just t' -> return (types' ++ [t'], insert name t' env', S.insert t' nonGeneric')
               Nothing -> do
                 t' <- makeVariable
                 return (types' ++ [t'], insert name t' env', S.insert t' nonGeneric'))
            ([], newScope, nonGeneric) params
    rtnT <- foldM (\_ instr -> snd <$> analyze instr newScope' newNonGeneric) unitT instructions
    case annoT of
      Just annoT' -> unify rtnT annoT' -- type propagation from return type to param type
      Nothing -> return ()
    -- use fresh just to make sure sequence of lambda abstractions with same type var name could work well e.g.
    -- ((λ(x: α) : α → x) 3)
    -- ((λ(x: α) : α → x) true)
    (scope,) <$> fresh (functionT paramTypes rtnT) nonGeneric
  EAccessor obj field -> do
    (_, objT) <- analyze obj scope nonGeneric
    fieldT <- makeVariable
    let desiredT = TRecord $ M.fromList [(field, fieldT)]
    unify objT desiredT
    return (scope, fieldT)
  EIf cond thenInstructions elseInstructions -> do
    (_, condT) <- analyze cond scope nonGeneric
    unify condT boolT
    (newScope, thenT) <- foldM (\(env, _) instr -> analyze instr env nonGeneric)
                               (scope, unitT) thenInstructions
    (newScope', elseT) <- foldM (\(env, _) instr -> analyze instr env nonGeneric)
                               (newScope, unitT) elseInstructions
    unify thenT elseT
    return (newScope', thenT)
  ELetBinding main def body -> do
    (scope', _) <- analyze (EDestructLetBinding main [] [def]) scope nonGeneric
    foldM (\(env, _) instr -> analyze instr env nonGeneric) (scope', unitT) body
  EDestructLetBinding main args instructions -> do
    let name = case main of
                 IdPattern n -> n ++ "-sig"
                 _ -> ""
    let typeSig = lookup name scope
    let newScope = child scope
    (newScope', newNonGeneric, letTV) <- visitPattern main newScope nonGeneric
    let newNonGeneric' = S.insert letTV newNonGeneric
    (argTypes, newScope'', newNonGeneric'') <-
      foldM (\(types, env, nonGen) arg -> do
             (newEnv, newNonGen, argT) <- visitPattern arg env nonGen
             return (types ++ [argT], newEnv, newNonGen))
            ([], newScope', newNonGeneric') args
    rtnT <- foldM (\_ instr -> snd <$> analyze instr newScope'' newNonGeneric'') unitT instructions
    let letT = functionT argTypes rtnT
    newScope''' <- definePattern main letT newScope''
    case typeSig of
      Just (TSig ta) -> do
        let ta' = extractType ta
        unify ta' letT
      _ -> return ()
    return (newScope''', letT)
  EDataDecl _ t _ tconstructors -> do
    let newScope = foldl (\env (TypeConstructor conName conTypes) ->
                          insert conName (TCon conName conTypes t) env)
                         scope tconstructors
    return (newScope, t)
  EPatternMatching input cases -> do
    (_, inputT) <- analyze input scope nonGeneric
    resT <- makeVariable
    resT' <- foldM (\rt (Case pat outcomes) -> do
                     let newScope = child scope
                     (newScope', newNonGeneric, patT) <- visitPattern pat newScope nonGeneric
                     -- make sure pattern type of each case is the same with input type
                     unify patT inputT
                     (_, caseT) <- foldM (\(env, _) outcome -> analyze outcome env newNonGeneric)
                                         (newScope', unitT) outcomes
                     -- make sure return type of each case are the same
                     unify caseT rt
                     return rt)
                  resT cases
    return (scope, resT')
  ETypeSig name t -> return (insert (name ++ "-sig") (TSig t) scope, unitT)
  EProgram instructions -> foldM (\(env, _) instr -> analyze instr env nonGeneric) (scope, unitT) instructions
  _ -> error $ "not support infer expr: " ++ show expr
