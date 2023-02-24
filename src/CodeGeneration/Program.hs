{-# LANGUAGE OverloadedStrings #-}

module CodeGeneration.Program (transProg) where

import CodeGeneration.IR 
import CodeGeneration.Statements (transStats)
import CodeGeneration.Utils (IRSectionGenerator, Aux(Aux, available, labelId))
import Control.Monad.State

import qualified AST

transProg :: AST.Program -> IRSectionGenerator (Program IRReg)
transProg (AST.Program fs ss) = do
  mainSection <- transMain ss
  otherSections <- mapM transFunc fs
  return $ otherSections ++ [mainSection]

transMain :: AST.Stats -> IRSectionGenerator (Section IRReg)
transMain ss = do 
  let unlimitedRegs = map TmpReg [0..]
  bodyInstrs <- evalStateT (transStats ss) (Aux {available = unlimitedRegs, labelId = 0}) 
  return $ Section [] [Function "main" True (wrapSectionBody bodyInstrs)]

transFunc :: AST.Func -> IRSectionGenerator (Section IRReg)
transFunc _ = return $ Section [] []

wrapSectionBody :: IRInstrs -> IRInstrs
wrapSectionBody ss = [Push (Regs [IRFP, IRLR]), Mov (Reg IRFP) (Reg IRSP)] ++ ss ++ [Pop (Regs [IRFP, IRPC])]