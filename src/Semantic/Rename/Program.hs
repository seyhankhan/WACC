module Semantic.Rename.Program (rename, renameProg) where

import Control.Monad.Reader
import Control.Monad.State

import Data.Bool

import AST
import Semantic.Errors
import Semantic.Rename.Utils
import Semantic.Rename.Function
import Semantic.Rename.Statement

rename :: Program -> Either [SemanticError] (ScopeMap, Program)
rename prog
  | null es   = Right (scopeMap finalAux, renamedProg)
  | otherwise = Left $ reverse es
  where
    es = errors finalAux
    (renamedProg, finalAux) = runState (runReaderT (renameProg prog) initScopeStack) initAux

renameProg :: Program -> Renamer Program
renameProg (Program funcs stats) =
  mapM addFuncName funcs >> Program <$> mapM renameFunc funcs <*> mapM renameStat stats

addFuncName :: Func -> Renamer ()
addFuncName f@(Func rt name ps _ _ _) = 
  funcExists f >>= bool (addFuncIdent f) (addSemanticError $ FunctionAlreadyDefined name rt ((map convertPairToErrorType . fst . unzip) ps))
  where
    convertPairToErrorType :: WType -> WType
    convertPairToErrorType (WPair _ _) = pairErrorType
    convertPairToErrorType t = t