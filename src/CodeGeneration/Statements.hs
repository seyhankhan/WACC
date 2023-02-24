{-# LANGUAGE OverloadedStrings #-}
module CodeGeneration.Statements (transStats, Aux(Aux, available)) where

import Control.Monad.Reader
import Control.Monad.State
import Data.Char (ord)

import AST
import CodeGeneration.IR
import CodeGeneration.Utils ((<++>), (<++), (++>))
import Semantic.Rename.Scope (ScopeMap)
import Semantic.Type.SymbolTable (SymbolTable)

import qualified AST as AST (Ident)
import qualified Data.Text as T

data Aux = Aux { 
  available :: [IRReg],
  labelId :: Int }

nextFreeReg :: StateT Aux (Reader (SymbolTable, ScopeMap)) IRReg
nextFreeReg = do
  aux <- get
  regs <- gets available
  case regs of 
    [] -> error "no registers available!" -- we assume an infinite number of registers in our IR so should never reach this case
    (nxt:rst) -> put (aux {available = rst}) >> return nxt

nextLabel :: StateT Aux (Reader (SymbolTable, ScopeMap)) Label
nextLabel = nextLabelId >>= toLabel
  where
    nextLabelId :: StateT Aux (Reader (SymbolTable, ScopeMap)) Int
    nextLabelId = do
      aux <- get
      l <- gets labelId
      put (aux {labelId = l + 1}) >> return l

    toLabel :: Int -> StateT Aux (Reader (SymbolTable, ScopeMap)) Label
    toLabel x = return $ "_L" <> T.pack (show x)

transStats :: Stats -> StateT Aux (Reader (SymbolTable, ScopeMap)) IRInstrs
transStats ss = concat <$> mapM transStat ss 

-- Pattern match on nodes
transStat :: Stat -> StateT Aux (Reader (SymbolTable, ScopeMap)) IRInstrs
transStat Skip = return []
transStat (DecAssign t i r _) = return []
transStat (Assign l r _) = return []
transStat (Read l _) = return []
transStat (Free e _) = return []
transStat (Return e _) = do
  dst <- nextFreeReg 
  eis <- transExp e dst
  return $ eis ++ [Mov (Reg IRRet) (Reg dst)]
transStat (Exit e _) = do 
  dst <- nextFreeReg
  eis <- transExp e dst
  return $ eis ++ [Mov (Reg IRRet) (Reg dst)]
transStat (Print e) = return []
transStat (Println e) = return []
transStat (If e ss _ ss' _ _) = return [] 
transStat (While e ss _ _) = return []
transStat (Begin ss _) = transStats ss

transExp :: Expr -> IRReg -> StateT Aux (Reader (SymbolTable, ScopeMap)) IRInstrs
transExp (IntLiter x _) dst = return [Mov (Reg dst) (Imm (fromIntegral x))]
transExp (BoolLiter True _) dst = return [Mov (Reg dst) (Imm 1)]
transExp (BoolLiter False _) dst = return [Mov (Reg dst) (Imm 0)]
transExp (CharLiter c _) dst = return [Mov (Reg dst) (Imm (ord c))]
transExp (StrLiter t _) dst = return [Mov (Reg dst) (Abs "strLiter")]
transExp (PairLiter _) dst = return []
transExp (IdentExpr (AST.Ident i _) _) dst = return []
transExp (ArrayExpr (ArrayElem (AST.Ident i _) exprs _) _) dst = return []
transExp (Not e _) dst = do
  eReg <- nextFreeReg
  exprInstrs <- transExp e eReg
  trueLabel <- nextLabel
  endLabel <- nextLabel
  return $ exprInstrs ++ [Cmp (Reg dst) (Imm 1), Je trueLabel, Mov (Reg eReg) (Imm 1), Jmp endLabel, Define trueLabel, Mov (Reg eReg) (Imm 0), Define endLabel, Mov (Reg dst) (Reg eReg)]
transExp (Neg e _) dst = do
  exprInstrs <- transExp e dst 
  return $ exprInstrs ++ [Sub (Reg dst) (Reg dst) (Imm 0)]
transExp (Len e _) dst = return []
transExp (Ord e _) dst = transExp e dst
transExp (Chr e _) dst = return []
transExp ((:*:) e e' _) dst = transNumOp Mul e e' dst
transExp ((:/:) e e' _) dst = transNumOp Div e e' dst
transExp ((:%:) e e' _) dst = return []
transExp ((:+:) e e' _) dst = transNumOp Add e e' dst
transExp ((:-:) e e' _) dst = transNumOp Sub e e' dst
transExp ((:>:) e e' _) dst = transCmpOp Jg e e' dst
transExp ((:>=:) e e' _) dst = transCmpOp Jge e e' dst
transExp ((:<:) e e' _) dst = transCmpOp Jl e e' dst
transExp ((:<=:) e e' _) dst = transCmpOp Jle e e' dst
transExp ((:==:) e e' _) dst = transCmpOp Je e e' dst
transExp ((:!=:) e e' _) dst = transCmpOp Jne e e' dst
transExp ((:&&:) e e' _) dst = do
  cmpReg <- nextFreeReg 
  failLabel <- nextLabel
  endLabel <- nextLabel
  r <- nextFreeReg
  eInstrs <- transExp e r
  r' <- nextFreeReg
  eInstrs' <- transExp e' r'
  let successCase = [Cmp (Reg r) (Imm 1), Jne failLabel, Cmp (Reg r') (Imm 1), Jne failLabel, Mov (Reg cmpReg) (Imm 1), Jmp endLabel]
      failCase = [Define failLabel, Mov (Reg cmpReg) (Imm 0)] 
      end = [Define endLabel, Mov (Reg dst) (Reg cmpReg)]
  return $ eInstrs ++ eInstrs' ++ successCase ++ failCase ++ end
transExp ((:||:) e e' _) dst = do
  cmpReg <- nextFreeReg 
  successLabel <- nextLabel
  endLabel <- nextLabel
  r <- nextFreeReg
  eInstrs <- transExp e r
  r' <- nextFreeReg
  eInstrs' <- transExp e' r'
  let failCase = [Cmp (Reg r) (Imm 1), Jne successLabel, Cmp (Reg r') (Imm 1), Je successLabel, Mov (Reg cmpReg) (Imm 0), Jmp endLabel]
      successCase = [Define successLabel, Mov (Reg cmpReg) (Imm 1)] 
      end = [Define endLabel, Mov (Reg dst) (Reg cmpReg)]
  return $ eInstrs ++ eInstrs' ++ failCase ++ successCase ++ end

type NumInstrCons a = Operand a -> Operand a -> Operand a -> Instr a
type BranchInstrCons a = Label -> Instr a

transNumOp :: NumInstrCons IRReg -> Expr -> Expr -> IRReg -> StateT Aux (Reader (SymbolTable, ScopeMap)) IRInstrs
transNumOp cons e e' dst = do
  r <- nextFreeReg
  eInstrs <- transExp e r
  r' <- nextFreeReg
  eInstrs' <- transExp e' r'
  return $ eInstrs ++ eInstrs' ++ [cons (Reg dst) (Reg r) (Reg r')]

transCmpOp :: BranchInstrCons IRReg -> Expr -> Expr -> IRReg -> StateT Aux (Reader (SymbolTable, ScopeMap)) IRInstrs
transCmpOp cons e e' dst = do
  cmpReg <- nextFreeReg 
  greaterLabel <- nextLabel
  endLabel <- nextLabel
  let greaterCase = [Define greaterLabel, Mov (Reg cmpReg) (Imm 1)] 
      otherCase = [Mov (Reg cmpReg) (Imm 0), Jmp endLabel]
      end = [Define endLabel, Mov (Reg dst) (Reg cmpReg)]
  r <- nextFreeReg
  eInstrs <- transExp e r
  r' <- nextFreeReg
  eInstrs' <- transExp e' r'
  return $ eInstrs ++ eInstrs' ++ [Cmp (Reg r) (Reg r'), cons greaterLabel] ++ otherCase ++ greaterCase ++ end